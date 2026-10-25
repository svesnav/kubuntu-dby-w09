#!/usr/bin/env python3
"""M-Pencil support for matepad-btd (and the boot-time axis fix).

The pen's position, pressure and tilt come from the touch controller: Huawei's
aptouch_daemon reads the THP frames and reports them on the kernel input
device "huawei,ts_pen". The daemon only scans for the pen once the touch
driver says that a Bluetooth pen is connected, and the pen only drives its
tip at the frequencies the panel listens on after the tablet has sent it the
panel's parameters over BLE. HarmonyOS does this with its TP HAL and
HwBluetoothPencilManager; here matepad-btd does it:

  1. the pen's HID-over-GATT link comes up (hogp.py makes a uhid device; its
     /dev/hidrawN must be readable by the daemon, which runs as UID 1000: the
     daemon reads the pen's vendor reports 0x55/0x57/0x58 there)
  2. ioctl INPUT_MT_IOCTRL_CMD_SET_STYLUS3_CONNECT_STATUS(2) on
     /dev/input_mt_wrapper (0 when the pen goes away); the daemon logs
     "BluetoothPenThp::InitBluetoothPen connected, enable stylus."
  3. the daemon posts the panel parameters as a callback event (class 2,
     e.g. "4f1,5eb,258,0a,01fe,01fe,2,411a"); INPUT_MT_IOCTL_CMD_GET_CALLBACK_EVENTS
     returns it and it goes to the pen as HPP command 0x53 on characteristic
     fe41 of service fe40-cc7a-... (HppHelper.setTpParam in
     HwBluetoothPencilManager.apk). Class 1 (frequency hop) becomes command 0x40.
  4. at connect the pen is told that multi-screen is supported (0x2d 06 01 01 01,
     MbbHelper.sendSupportFeature) and every class 4 event ("MultiPanelState
     match code", 0/2/3) goes to it as 0x2d 01 01 01 <code>. Without this the
     pen reports hover only: no tip and no pressure. With it, the pen streams
     HID report 0x55 (tip pressure) over BLE and the daemon merges it into
     huawei,ts_pen (BTN_TOUCH, ABS_PRESSURE 0..16384).

The HPP service must be used through hogp's Peer: Bumble's Peer(connection)
installs a new GATT client and the HID report subscription would be lost.

`pen.py --abs` (matepad-pen.service, before the desktop) gives the axes of
"huawei,ts_pen" a resolution: the kernel reports none, and libinput ignores
a tablet without one ("missing tablet capabilities: resolution").
"""
import asyncio
import fcntl
import glob
import logging
import os
import struct
import sys
import threading
import time

log = logging.getLogger("matepad-btd.pen")

PEN_IDS = {(0x12D1, 0x10A5)}          # M-Pencil (2nd generation), HID PnP ID
WRAPPER = "/dev/input_mt_wrapper"
HPP_SERVICE = "0000fe40-cc7a-482a-984a-7f2ed5b3e512"
HPP_SEND = "0000fe41-cc7a-482a-984a-7f2ed5b3e512"
HPP_RECEIVE = "0000fe42-cc7a-482a-984a-7f2ed5b3e512"
DAEMON_UID = 1000                     # aptouch_daemon runs as UID/GID 1000
MBB = 0x2D                            # MbbHelper.MBB_PERIPHERAL_SERVICE_ID


def _ioc(d, t, nr, size):
    return (d << 30) | (size << 16) | (t << 8) | nr


# drivers/devkit/tpkit/hostprocessing/huawei_thp_mt_wrapper.h
SET_STYLUS3_CONNECT_STATUS = _ioc(3, 0xBB, 0x08, 4)
GET_CALLBACK_EVENTS = _ioc(3, 0xBA, 0x07, 40)     # struct tp_callback_event {int; int; char[32]}


def is_pen(vendor, product):
    return (vendor, product) in PEN_IDS


def _hex_bytes(s):
    if len(s) % 2:
        s = "0" + s
    return bytes.fromhex(s)


def tp_param_packet(tp_type, param):
    """HppHelper.setTpParam: 17-byte HPP command 0x53."""
    b = bytearray(17)
    b[0], b[1] = 0x53, 0x0F
    b[12], b[13] = 26, 65
    kind = {1: 0, 2: 1, 4: 2}.get(tp_type)
    if kind is None:
        raise ValueError("unknown tp type %d" % tp_type)
    b[15] = kind
    if len(param) > 2:
        f = param.split(",")
        if len(f) < 7:
            raise ValueError("tp param %r" % param)
        for i, pos in ((0, 6), (1, 8), (2, 10), (4, 2), (5, 4)):
            v = _hex_bytes(f[i])
            if len(v) != 2:
                raise ValueError("tp param %r" % param)
            b[pos], b[pos + 1] = v[1], v[0]          # little endian
        b[16] = _hex_bytes(f[6])[0]
        if len(f) > 7:
            v = _hex_bytes(f[7])
            if len(v) == 2:
                b[12], b[13] = v[1], v[0]
        b[14] = int(f[3], 16) & 0xFF
    elif len(param) == 2:
        b[16] = _hex_bytes(param)[0]
    return bytes(b)


def frequency_packet(code, param):
    """HppHelper.setFrequency: HPP command 0x40."""
    f = param.split(",")
    return bytes([0x40, 3, code & 0xFF, int(f[0]) & 0xFF, int(f[1]) & 0xFF])


class DoubleTapKey:
    """HID report filter for the pen's keyboard report (id 2: modifiers,
    reserved, 6 keys). A double-tap on the pen sends F20 (usage 0x6F) twice
    within ~30 ms; xkb turns F20 into XF86AudioMicMute, so every double-tap
    toggled the microphone. The key is dropped and on_tap() is called once
    per double-tap (matepad-btd: ShortcutToggle, eraser <-> pen)."""

    TAP, WINDOW = 0x6F, 0.15

    def __init__(self, on_tap):
        self.on_tap = on_tap
        self.last = 0.0

    def __call__(self, data):
        if len(data) < 4 or data[0] != 2:
            return data
        keys = data[3:]
        if self.TAP in keys:
            now = time.monotonic()
            if now - self.last >= self.WINDOW:     # not the second press of the pair
                self.on_tap()
            self.last = now
            rest = [k for k in keys if k != self.TAP]
            if not any(rest):
                return None
            return bytes(data[:3]) + bytes(rest + [0] * (len(keys) - len(rest)))
        if not any(keys) and time.monotonic() - self.last < 1.0:
            return None         # the release that belongs to a tap
        return data


EV_SYN, EV_KEY = 0x00, 0x01
KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_E, KEY_P = 29, 42, 18, 25


class ShortcutToggle:
    """Double-tap = pen/eraser toggle, as on HarmonyOS: sends Ctrl+Shift+E
    (Xournal++: eraser) and Ctrl+Shift+P (pen) in turn, from a uinput
    keyboard "M-Pencil shortcuts". A pen button rebind in Drawing Tablet
    settings cannot toggle (one button, one shortcut). If the tool was
    changed by hand, one double-tap may only re-select the current tool."""

    STEPS = ((KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_E), (KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_P))
    NAME = "M-Pencil shortcuts"

    def __init__(self):
        self.fd = None
        self.step = 0

    def _create(self):
        import subprocess
        if not os.path.exists("/dev/uinput"):
            major, minor = open("/sys/class/misc/uinput/dev").read().strip().split(":")
            os.mknod("/dev/uinput", 0o600 | 0o020000, os.makedev(int(major), int(minor)))
        before = set(glob.glob("/sys/class/input/event*"))
        fd = os.open("/dev/uinput", os.O_WRONLY | os.O_CLOEXEC)
        fcntl.ioctl(fd, _ioc(1, ord("U"), 100, 4), EV_KEY)              # UI_SET_EVBIT
        for k in (KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_E, KEY_P):
            fcntl.ioctl(fd, _ioc(1, ord("U"), 101, 4), k)                # UI_SET_KEYBIT
        setup = struct.pack("<HHHH80sI", 0x06, 0x12D1, 0x10A5, 1, self.NAME.encode(), 0)
        fcntl.ioctl(fd, _ioc(1, ord("U"), 3, len(setup)), setup)         # UI_DEV_SETUP
        fcntl.ioctl(fd, _ioc(0, ord("U"), 1, 0))                         # UI_DEV_CREATE
        # /dev is static in this boot: make the event node and tell udev (KWin)
        for _ in range(20):
            new = set(glob.glob("/sys/class/input/event*")) - before
            if new:
                break
            time.sleep(0.05)
        for d in new:
            node = "/dev/input/" + os.path.basename(d)
            if not os.path.exists(node):
                major, minor = open(d + "/dev").read().strip().split(":")
                os.mknod(node, 0o660 | 0o020000, os.makedev(int(major), int(minor)))
            subprocess.run(["udevadm", "trigger", "--action=add", d], check=False)
            log.info("%s: %s", self.NAME, node)
        self.fd = fd

    def prepare(self):
        """Create the device before the first double-tap: KWin needs a moment
        to add a new keyboard, and the first shortcut would be lost."""
        if self.fd is None:
            try:
                self._create()
            except OSError as e:
                log.warning("%s: %s", self.NAME, e)

    def __call__(self):
        try:
            if self.fd is None:
                self._create()
            keys = self.STEPS[self.step]
            self.step = (self.step + 1) % len(self.STEPS)

            def emit(code, value):
                os.write(self.fd, struct.pack("<qqHHi", 0, 0, EV_KEY, code, value)
                         + struct.pack("<qqHHi", 0, 0, EV_SYN, 0, 0))
            for k in keys:
                emit(k, 1)
            for k in reversed(keys):
                emit(k, 0)
            log.info("double-tap -> %s", "eraser (Ctrl+Shift+E)" if keys[-1] == KEY_E else "pen (Ctrl+Shift+P)")
        except OSError as e:
            log.warning("double-tap shortcut: %s", e)




class Pen:
    """The pen glue for matepad-btd: one pen at a time."""

    def __init__(self):
        self.loop = None
        self.thread = None
        self.dev = None          # Device1 of the connected pen
        self.send_char = None    # its HPP send characteristic
        self.tp = None           # last (type, param) from the touch daemon
        self.last_match = (None, None, 0.0)

    # --- touch driver ---------------------------------------------------
    def _set_connected(self, on):
        try:
            fd = os.open(WRAPPER, os.O_RDWR | os.O_CLOEXEC)
        except OSError as e:
            log.warning("%s: %s", WRAPPER, e)
            return
        try:
            fcntl.ioctl(fd, SET_STYLUS3_CONNECT_STATUS, struct.pack("<I", 2 if on else 0))
            log.info("touch driver: Bluetooth pen %s", "connected" if on else "disconnected")
        except OSError as e:
            log.warning("stylus3 connect status: %s", e)
        finally:
            os.close(fd)

    def _callback_thread(self):
        # Blocks in the driver until the touch daemon posts an event.
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
                threading.Event().wait(5)
                continue
            cls, code = struct.unpack_from("<ii", buf)
            info = bytes(buf[8:]).split(b"\0", 1)[0].decode("ascii", "replace")
            if cls == 0 and code == 0 and not info:
                continue        # interrupted wait
            self.loop.call_soon_threadsafe(self._on_tp_event, cls, code, info)

    def _on_tp_event(self, cls, code, info):
        if cls == 4:
            # BluetoothPenThp::MultiPanelState "match code": the pen must be
            # told which panel it is on (MbbHelper.sendMultiScreenEvent);
            # until it is, the daemon repeats the event every ~50 ms and the
            # pen reports hover only (no tip, no pressure).
            now = time.monotonic()
            if (code, self.dev) == self.last_match[:2] and now - self.last_match[2] < 0.3:
                return
            if code != self.last_match[0]:
                log.info("touch event: panel match code %d", code)
            self.last_match = (code, self.dev, now)
            self._send(bytes([MBB, 1, 1, 1, code & 0xFF]))
            return
        log.info("touch event class %d code %d %r", cls, code, info)
        try:
            if cls == 2:
                self.tp = (code, info)
                pkt = tp_param_packet(code, info)
            elif cls == 1:
                pkt = frequency_packet(code, info)
            else:
                return          # 3: screen brightness state (HwPencilController sends zeros)
        except (ValueError, IndexError) as e:
            log.warning("touch event not understood: %s", e)
            return
        self._send(pkt)

    # --- pen ------------------------------------------------------------
    def _send(self, pkt):
        if not self.send_char:
            return
        c = self.send_char

        async def write():
            from bumble.gatt import Characteristic
            # As Android: a characteristic that offers write-without-response
            # gets written that way (BluetoothGattCharacteristic's default
            # write type).
            plain = not (c.properties & Characteristic.Properties.WRITE_WITHOUT_RESPONSE)
            try:
                await c.write_value(pkt, with_response=plain)
                (log.debug if pkt[0] == MBB and pkt[1] == 1 else log.info)("pen <- %s", pkt.hex())
            except Exception as e:  # noqa: BLE001
                log.warning("pen write %s (properties %s): %r %s", pkt.hex(), c.properties, e, getattr(e, "error_name", ""))
        asyncio.ensure_future(write())

    def _on_notify(self, value):
        v = bytes(value)
        # 2d 02: usage statistics (HwPencilController uploads them as CHR)
        (log.debug if v[:2] == b"-" else log.info)("pen -> %s", v.hex())

    async def attach(self, dev, conn):
        from bumble.core import UUID
        from bumble.device import Peer

        self.loop = asyncio.get_running_loop()
        if self.thread is None:
            self.thread = threading.Thread(target=self._callback_thread, name="tp-events", daemon=True)
            self.thread.start()
        self.dev = dev
        self.send_char = None
        try:
            # hogp's Peer: Peer(conn) would replace the connection's GATT
            # client and drop the HID report subscription
            peer = getattr(dev.hid, "peer", None) or Peer(conn)
            svcs = await peer.discover_service(UUID(HPP_SERVICE))
            if svcs:
                await svcs[0].discover_characteristics()
                s = svcs[0].get_characteristics_by_uuid(UUID(HPP_SEND))
                r = svcs[0].get_characteristics_by_uuid(UUID(HPP_RECEIVE))
                if r:
                    try:
                        await r[0].subscribe(self._on_notify)
                    except Exception as e:  # noqa: BLE001
                        log.info("pen notifications: %r", e)
                self.send_char = s[0] if s else None
            if not self.send_char:
                log.warning("%s: no HPP service, the pen will not get the panel parameters", dev.addr)
        except Exception as e:  # noqa: BLE001
            log.warning("%s: HPP service: %r", dev.addr, e)
        if self.dev is not dev:
            return
        # onPencilConnected: tell the pen that this tablet supports the
        # multi-screen (panel match) protocol, as HarmonyOS does.
        self._send(bytes([MBB, 6, 1, 1, 1]))
        # The daemon acts on a change of the status bit: clear it first in
        # case it is still set (matepad-btd restarted with the pen connected).
        self._set_connected(False)
        await asyncio.sleep(0.5)
        if self.dev is not dev:
            return
        self._set_connected(True)
        if self.tp:
            self._send(tp_param_packet(*self.tp))

    def detach(self, dev):
        if self.dev is not dev:
            return
        self.dev = None
        self.send_char = None
        self._set_connected(False)


# --- axis resolution (pen.py --abs) ---------------------------------------
ABS_X, ABS_Y, ABS_TILT_X, ABS_TILT_Y = 0x00, 0x01, 0x1A, 0x1B
# X/Y: 12800 x 20480 over the 147.6 x 236.2 mm panel = 86.7 units/mm.
# Tilt: degrees; libinput wants units per radian.
RESOLUTION = {ABS_X: 87, ABS_Y: 87, ABS_TILT_X: 57, ABS_TILT_Y: 57}


def fix_abs(name="huawei,ts_pen"):
    for d in glob.glob("/sys/class/input/event*"):
        try:
            if open(d + "/device/name").read().strip() != name:
                continue
        except OSError:
            continue
        node = "/dev/input/" + os.path.basename(d)
        if not os.path.exists(node):
            major, minor = open(d + "/dev").read().strip().split(":")
            os.mknod(node, 0o660 | 0o020000, os.makedev(int(major), int(minor)))
        fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
        try:
            for code, res in RESOLUTION.items():
                buf = bytearray(24)
                fcntl.ioctl(fd, _ioc(2, ord("E"), 0x40 + code, 24), buf, True)   # EVIOCGABS
                v = list(struct.unpack("<6i", buf))
                v[5] = res
                fcntl.ioctl(fd, _ioc(1, ord("E"), 0xC0 + code, 24), struct.pack("<6i", *v))  # EVIOCSABS
            print("%s (%s): resolution set" % (node, name))
            return 0
        finally:
            os.close(fd)
    print("no input device named %r" % name, file=sys.stderr)
    return 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--abs"]:
        sys.exit(fix_abs())
    if len(sys.argv) == 3 and sys.argv[1] == "--packet":
        t, p = sys.argv[2].split(":", 1)
        print(tp_param_packet(int(t), p).hex())
        sys.exit(0)
    print("usage: pen.py --abs | --packet TYPE:PARAM", file=sys.stderr)
    sys.exit(2)
