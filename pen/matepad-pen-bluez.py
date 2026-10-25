#!/usr/bin/env python3
"""M-Pencil helper for Linux 7.0 (BlueZ), the BlueZ port of the 4.19
matepad-btd pen glue (pen.py, from the 4.19 Bumble daemon: its packet builders and
double-tap toggle it reuses).

The pen pairs as a normal BLE HID device (BlueZ HOG -> uhid -> hid-generic,
/dev/hidrawN). aptouch_daemon reads its pressure reports there and computes
position/tilt from the panel; the kernel driver (huawei-thp-lite) reports them
on "huawei,ts_pen". This helper does the rest, as HarmonyOS's TP HAL and
HwBluetoothPencilManager do:

  * pen connected (and its GATT services resolved): tell the pen that
    multi-screen is supported (2d 06 01 01 01) and set the touch driver's
    stylus3 status 0 -> 2 (INPUT_MT_IOCTRL_CMD_SET_STYLUS3_CONNECT_STATUS); 0
    when it disconnects;
  * forward the daemon's callback events (INPUT_MT_IOCTL_CMD_GET_CALLBACK_EVENTS)
    to the pen's HPP characteristic fe41: class 2 panel parameters (0x53),
    class 1 frequency (0x40), class 4 panel match code (2d 01 01 01 <code>;
    without it the pen reports hover only);
  * double-tap (F20 on the pen's keyboard device, which xkb maps to mic
    mute): grab that device and toggle Ctrl+Shift+E / Ctrl+Shift+P (eraser /
    pen in Xournal++), as on 4.19.
"""
import fcntl
import glob
import logging
import os
import struct
import sys
import threading
import time

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pen import (MBB, GET_CALLBACK_EVENTS, HPP_RECEIVE, HPP_SEND,  # noqa: E402
                 SET_STYLUS3_CONNECT_STATUS, WRAPPER, ShortcutToggle,
                 frequency_packet, tp_param_packet)

log = logging.getLogger("matepad-pen")

BLUEZ = "org.bluez"
DEV_IFACE = "org.bluez.Device1"
CHR_IFACE = "org.bluez.GattCharacteristic1"
PROPS = "org.freedesktop.DBus.Properties"
OM_IFACE = "org.freedesktop.DBus.ObjectManager"
PEN_MODALIAS = "bluetooth:v12D1p10A5"     # HID PnP ID of the M-Pencil (2nd gen)
PEN_VENDOR, PEN_PRODUCT = 0x12D1, 0x10A5

EV_KEY = 0x01
KEY_F20 = 190
EVIOCGRAB = (1 << 30) | (4 << 16) | (ord("E") << 8) | 0x90
INPUT_EVENT = struct.Struct("<qqHHi")


def is_pen(props):
    mod = str(props.get("Modalias", ""))
    return mod.upper().startswith(PEN_MODALIAS.upper()) or "M-Pencil" in str(props.get("Name", ""))


class DoubleTap:
    """Grabs the pen's keyboard input device (F20 = double-tap) and turns each
    double-tap (two F20 presses within ~30 ms) into one toggle."""

    WINDOW = 0.15

    def __init__(self, on_tap):
        self.on_tap = on_tap
        self.thread = None
        self.stop = threading.Event()

    @staticmethod
    def _find():
        for d in glob.glob("/sys/class/input/event*"):
            try:
                vid = int(open(d + "/device/id/vendor").read(), 16)
                pid = int(open(d + "/device/id/product").read(), 16)
                keys = open(d + "/device/capabilities/key").read().split()
            except OSError:
                continue
            if (vid, pid) != (PEN_VENDOR, PEN_PRODUCT) or not keys:
                continue
            # the key bitmap is printed as hex longs, highest first
            bits = int("".join(k.zfill(16) for k in keys), 16)
            if bits >> KEY_F20 & 1:
                return "/dev/input/" + os.path.basename(d)
        return None

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.stop.clear()
        self.thread = threading.Thread(target=self._run, name="double-tap", daemon=True)
        self.thread.start()

    def _run(self):
        node = None
        for _ in range(50):          # the uhid input device comes a bit later
            node = self._find()
            if node or self.stop.is_set():
                break
            time.sleep(0.2)
        if not node:
            log.info("pen keyboard device not found: double-tap stays F20")
            return
        try:
            fd = os.open(node, os.O_RDONLY | os.O_CLOEXEC)
            fcntl.ioctl(fd, EVIOCGRAB, 1)
        except OSError as e:
            log.warning("%s: %s", node, e)
            return
        log.info("double-tap: %s grabbed", node)
        last = 0.0
        try:
            while not self.stop.is_set():
                data = os.read(fd, INPUT_EVENT.size * 16)
                for off in range(0, len(data) - INPUT_EVENT.size + 1, INPUT_EVENT.size):
                    _, _, typ, code, value = INPUT_EVENT.unpack_from(data, off)
                    if typ == EV_KEY and code == KEY_F20 and value == 1:
                        now = time.monotonic()
                        if now - last >= self.WINDOW:
                            GLib.idle_add(self.on_tap)
                        last = now
        except OSError:
            pass                     # device gone (pen disconnected)
        finally:
            os.close(fd)


class PenHelper:
    def __init__(self, bus):
        self.bus = bus
        # follow_name_owner_changes: keep working across bluetoothd restarts
        self.om = dbus.Interface(bus.get_object(BLUEZ, "/", follow_name_owner_changes=True),
                                 OM_IFACE)
        self.pen_path = None
        self.send_path = None
        self.send_cmd = False        # write-without-response
        self.tp = None               # last (type, param) from the daemon
        self.last_match = (None, 0.0)
        self.shortcuts = ShortcutToggle()
        self.double_tap = DoubleTap(self.shortcuts)
        threading.Thread(target=self._callback_thread, name="tp-events", daemon=True).start()
        bus.add_signal_receiver(self._props_changed, dbus_interface=PROPS,
                                signal_name="PropertiesChanged", path_keyword="path")
        bus.add_signal_receiver(self._added, dbus_interface=OM_IFACE,
                                signal_name="InterfacesAdded")
        self._set_connected(False)
        for path, ifaces in self.om.GetManagedObjects().items():
            props = ifaces.get(DEV_IFACE)
            if props and is_pen(props) and props.get("Connected") and props.get("ServicesResolved"):
                GLib.idle_add(self._attach, str(path))

    # --- touch driver ---------------------------------------------------
    def _set_connected(self, on):
        try:
            fd = os.open(WRAPPER, os.O_RDWR | os.O_CLOEXEC)
        except OSError as e:
            log.warning("%s: %s", WRAPPER, e)
            return
        try:
            fcntl.ioctl(fd, SET_STYLUS3_CONNECT_STATUS, struct.pack("<I", 2 if on else 0))
            log.info("touch driver: pen %s", "connected" if on else "disconnected")
        except OSError as e:
            log.warning("stylus3 connect status: %s", e)
        finally:
            os.close(fd)

    def _callback_thread(self):
        fd = None
        while True:
            try:
                if fd is None:
                    fd = os.open(WRAPPER, os.O_RDWR | os.O_CLOEXEC)
                buf = bytearray(40)
                fcntl.ioctl(fd, GET_CALLBACK_EVENTS, buf, True)
            except OSError as e:
                log.warning("touch callback events: %s", e)
                if fd is not None:
                    os.close(fd)
                    fd = None
                time.sleep(5)
                continue
            cls, code = struct.unpack_from("<ii", buf)
            info = bytes(buf[8:]).split(b"\0", 1)[0].decode("ascii", "replace")
            if cls == 0 and code == 0 and not info:
                continue             # interrupted wait
            GLib.idle_add(self._on_tp_event, cls, code, info)

    def _on_tp_event(self, cls, code, info):
        if cls == 4:
            now = time.monotonic()
            if code == self.last_match[0] and now - self.last_match[1] < 0.3:
                return False         # the daemon repeats it every ~50 ms
            if code != self.last_match[0]:
                log.info("touch event: panel match code %d", code)
            self.last_match = (code, now)
            self._send(bytes([MBB, 1, 1, 1, code & 0xFF]))
            return False
        log.info("touch event class %d code %d %r", cls, code, info)
        try:
            if cls == 2:
                self.tp = (code, info)
                pkt = tp_param_packet(code, info)
            elif cls == 1:
                pkt = frequency_packet(code, info)
            else:
                return False         # 3: screen state (HarmonyOS sends zeros)
        except (ValueError, IndexError) as e:
            log.warning("touch event not understood: %s", e)
            return False
        self._send(pkt)
        return False

    # --- pen ------------------------------------------------------------
    def _send(self, pkt):
        if not self.send_path:
            return
        chr_ = dbus.Interface(self.bus.get_object(BLUEZ, self.send_path), CHR_IFACE)
        opts = {"type": "command" if self.send_cmd else "request"}
        chr_.WriteValue(dbus.Array(pkt, signature="y"), opts,
                        reply_handler=lambda: (log.debug if pkt[:2] == bytes([MBB, 1]) else log.info)("pen <- %s", pkt.hex()),
                        error_handler=lambda e: log.warning("pen write %s: %s", pkt.hex(), e))

    def _on_notify(self, iface, changed, invalidated, path=None):
        if "Value" in changed:
            v = bytes(changed["Value"])
            (log.debug if v[:1] == bytes([MBB]) else log.info)("pen -> %s", v.hex())

    def _attach(self, path):
        if self.pen_path == path:
            return False
        self.pen_path = path
        self.send_path = None
        for p, ifaces in self.om.GetManagedObjects().items():
            c = ifaces.get(CHR_IFACE)
            if not c or not str(p).startswith(path + "/"):
                continue
            uuid = str(c.get("UUID", "")).lower()
            if uuid == HPP_SEND:
                self.send_path = str(p)
                self.send_cmd = "write-without-response" in [str(f) for f in c.get("Flags", [])]
            elif uuid == HPP_RECEIVE:
                obj = self.bus.get_object(BLUEZ, p)
                self.bus.add_signal_receiver(self._on_notify, dbus_interface=PROPS,
                                             signal_name="PropertiesChanged", path=str(p))
                dbus.Interface(obj, CHR_IFACE).StartNotify(
                    reply_handler=lambda: None,
                    error_handler=lambda e: log.info("pen notifications: %s", e))
        if not self.send_path:
            log.warning("%s: no HPP service, the pen will not get the panel parameters", path)
        log.info("pen attached: %s", path)
        self._send(bytes([MBB, 6, 1, 1, 1]))   # multi-screen supported
        self.shortcuts.prepare()
        self.double_tap.start()
        # The daemon acts on a change of the status bit.
        self._set_connected(False)
        GLib.timeout_add(500, self._connected_later, path)
        return False

    def _connected_later(self, path):
        if self.pen_path == path:
            self._set_connected(True)
            if self.tp:
                self._send(tp_param_packet(*self.tp))
        return False

    def _detach(self, path):
        if self.pen_path != path:
            return
        log.info("pen detached: %s", path)
        self.pen_path = None
        self.send_path = None
        self.double_tap.stop.set()
        self._set_connected(False)

    # --- BlueZ signals --------------------------------------------------
    def _props_changed(self, iface, changed, invalidated, path=None):
        if iface != DEV_IFACE:
            return
        if "Connected" in changed and not changed["Connected"]:
            self._detach(str(path))
            return
        if changed.get("ServicesResolved") or changed.get("Connected"):
            props = dbus.Interface(self.bus.get_object(BLUEZ, path), PROPS).GetAll(DEV_IFACE)
            if is_pen(props) and props.get("Connected") and props.get("ServicesResolved"):
                self._attach(str(path))

    def _added(self, path, ifaces):
        props = ifaces.get(DEV_IFACE)
        if props and is_pen(props) and props.get("Connected") and props.get("ServicesResolved"):
            self._attach(str(path))


def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    PenHelper(dbus.SystemBus())
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
