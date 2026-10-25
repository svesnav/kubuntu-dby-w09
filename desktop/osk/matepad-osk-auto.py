#!/usr/bin/python3
"""On-screen keyboard only while no hardware keyboard is attached.

Plasma 5.27's KWin shows its virtual keyboard (Maliit) for every focused text
field, even while a Bluetooth or USB keyboard is connected. This runs in the
Plasma session (XDG autostart) and switches KWin's virtual keyboard
(org.kde.kwin.VirtualKeyboard "enabled", the System Settings -> Virtual
Keyboard switch) off while a keyboard is attached and on again when it is
gone. A keyboard is an input device with letter keys and a space bar
(the MatePad's own buttons, pen, touch screen and headset jack have none).
"""
import subprocess
import sys
import time

LETTERS = (16, 30, 44, 57)      # KEY_Q, KEY_A, KEY_Z, KEY_SPACE


def keyboards():
    found, name = [], ""
    try:
        f = open("/proc/bus/input/devices")
    except OSError:
        return found
    with f:
        for line in f:
            if line.startswith("N: Name="):
                name = line[8:].strip().strip('"')
            elif line.startswith("B: KEY="):
                bits = 0
                for word in line[7:].split():   # most significant long first
                    bits = (bits << 64) | int(word, 16)
                if all(bits >> k & 1 for k in LETTERS):
                    found.append(name)
    return found


def kwin(*args):
    r = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", "/VirtualKeyboard"]
                       + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
    return r.stdout if r.returncode == 0 else None


def prop(name):
    out = kwin("org.freedesktop.DBus.Properties.Get", "string:org.kde.kwin.VirtualKeyboard", "string:" + name)
    return out is not None and "boolean true" in out


def set_prop(name, value):
    return kwin("org.freedesktop.DBus.Properties.Set", "string:org.kde.kwin.VirtualKeyboard",
                "string:" + name, "variant:boolean:" + ("true" if value else "false")) is not None


def set_osk(enabled):
    if not set_prop("enabled", enabled):
        return False
    if enabled:
        # A text field that already has focus does not ask again: show the
        # keyboard for it now (KWin may need a moment to restart Maliit).
        for _ in range(12):
            time.sleep(0.25)
            if not prop("activeClientSupportsTextInput") or prop("visible"):
                break
            set_prop("active", True)
    return True


def main():
    applied = None
    while True:
        kbd = keyboards()
        want = not kbd
        if want != applied:
            if set_osk(want):
                print("on-screen keyboard %s%s" % ("on" if want else "off",
                      "" if want else " (keyboard: %s)" % ", ".join(kbd)), flush=True)
                applied = want
            # else: KWin not ready yet, try again on the next round
        time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
