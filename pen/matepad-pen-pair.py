#!/usr/bin/python3
"""matepad-pen-pair: pair the M-Pencil with BlueZ once.

The pen advertises as "M-Pencil" without the LE discoverable flag, so
Plasma's Add Device never lists it. Its address comes from HarmonyOS (the
installer writes it to /etc/matepad/pen-mac). This waits until the pen
advertises (it does when woken: taken off and put back on its magnet), pairs
it (Just Works; LE Secure Connections), trusts and connects it, and exits.
Already bonded: exits at once. matepad-pen-bluez takes over from there.

The pairing needs a pause after the scan: right after a scan the controller
answered "busy" to the encryption start and BlueZ cancelled the pairing.
"""
import os
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

MAC_FILE = "/etc/matepad/pen-mac"
AGENT = "/org/matepad/penpair"


def log(msg):
    print(f"matepad-pen-pair: {msg}", flush=True)


class Agent(dbus.service.Object):
    """Accepts the Just Works confirmation; the pen has no input or output."""

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self):
        pass


class Pairer:
    def __init__(self, bus, mac):
        self.bus = bus
        self.path = "/org/bluez/hci0/dev_" + mac.replace(":", "_")
        self.adapter = dbus.Interface(bus.get_object("org.bluez", "/org/bluez/hci0"), "org.bluez.Adapter1")
        self.loop = GLib.MainLoop()
        self.busy = False
        self.tries = 0
        bus.add_signal_receiver(self.added, dbus_interface="org.freedesktop.DBus.ObjectManager",
                                signal_name="InterfacesAdded")

    def device_props(self):
        props = dbus.Interface(self.bus.get_object("org.bluez", self.path), "org.freedesktop.DBus.Properties")
        return props.GetAll("org.bluez.Device1")

    def bonded(self):
        try:
            return bool(self.device_props().get("Bonded", False))
        except dbus.DBusException:
            return False

    def scan(self):
        self.busy = False
        try:
            self.adapter.SetDiscoveryFilter({"Transport": "le", "Discoverable": dbus.Boolean(False),
                                             "DuplicateData": dbus.Boolean(True)})
            self.adapter.StartDiscovery()
        except dbus.DBusException as e:
            log(f"cannot scan ({e.get_dbus_name()}); trying again in 30 s")
            GLib.timeout_add_seconds(30, self.scan)
            return False
        objects = dbus.Interface(self.bus.get_object("org.bluez", "/"),
                                 "org.freedesktop.DBus.ObjectManager").GetManagedObjects()
        if self.path in objects:
            GLib.idle_add(self.found)
        return False

    def stop_scan(self):
        try:
            self.adapter.StopDiscovery()
        except dbus.DBusException:
            pass

    def added(self, path, ifaces):
        if path == self.path:
            self.found()

    def found(self):
        if self.busy:
            return False
        self.busy = True
        log("pen seen; pairing")
        self.stop_scan()
        self.tries = 0
        GLib.timeout_add(1500, self.pair)
        return False

    def pair(self):
        self.tries += 1
        dev = dbus.Interface(self.bus.get_object("org.bluez", self.path), "org.bluez.Device1")
        dev.Pair(reply_handler=self.paired, error_handler=self.pair_failed, timeout=60)
        return False

    def pair_failed(self, e):
        if self.bonded():
            self.paired()
        elif self.tries < 4:
            log(f"try {self.tries}: {e.get_dbus_name()}; again")
            GLib.timeout_add(2000, self.pair)
        else:
            log(f"pairing failed ({e.get_dbus_name()}); waiting for the pen again")
            GLib.timeout_add_seconds(10, self.scan)

    def paired(self, *_):
        dev = self.bus.get_object("org.bluez", self.path)
        dbus.Interface(dev, "org.freedesktop.DBus.Properties").Set("org.bluez.Device1", "Trusted", True)
        log("paired and trusted; connecting")
        dbus.Interface(dev, "org.bluez.Device1").Connect(
            reply_handler=self.finish, error_handler=lambda e: self.finish(), timeout=40)

    def finish(self, *_):
        log("done: the pen reconnects by itself from now on")
        self.loop.quit()

    def run(self):
        if self.bonded():
            log("the pen is paired already")
            return
        log("waiting for the pen: take it off its magnet and put it back")
        GLib.idle_add(self.scan)
        self.loop.run()


def main():
    if not os.path.exists(MAC_FILE):
        log(f"no {MAC_FILE}: the installer did not find the pen's address")
        return
    mac = open(MAC_FILE).read().strip().upper()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    Agent(bus, AGENT)
    dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.AgentManager1").RegisterAgent(
        AGENT, "NoInputNoOutput")
    Pairer(bus, mac).run()


if __name__ == "__main__":
    sys.exit(main())
