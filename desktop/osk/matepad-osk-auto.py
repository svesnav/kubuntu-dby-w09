#!/usr/bin/python3
"""On-screen keyboard only while no hardware keyboard is attached.

Plasma 5.27's KWin shows its virtual keyboard (Maliit) for every focused text
field, even while a Bluetooth or USB keyboard is connected. This runs in the
Plasma session (XDG autostart) and switches KWin's virtual keyboard
(org.kde.kwin.VirtualKeyboard "enabled", the System Settings -> Virtual
Keyboard switch) off while a keyboard is attached and on again when it is
gone. A keyboard is an input device with letter keys and a space bar
(the MatePad's own buttons, pen, touch screen and headset jack have none).

A connected keyboard is not always in use: the HUAWEI MatePad Keyboard folio
stays connected over Bluetooth while it is folded behind the tablet, a
wireless mouse's USB receiver presents a keyboard too, and a Bluetooth
keyboard may lie unused. So a keyboard counts as in use
  - the folio: while the tablet stands in its dock (the dock's hall sensor is
    the kernel's tablet-mode switch, KWin's org.kde.KWin.TabletModeManager);
  - any other keyboard: for IDLE seconds after it was typed on
    (matepad-typing-watch, a system service, notes the last key press in
    /run/matepad-typing; the session cannot read input devices).
"""
import subprocess
import sys
import time

LETTERS = (16, 30, 44, 57)      # KEY_Q, KEY_A, KEY_Z, KEY_SPACE
FOLIO = "HUAWEI MatePad Keyboard"
TYPING = "/run/matepad-typing"
IDLE = 300


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


def kwin(*args, path="/VirtualKeyboard"):
    r = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", path]
                       + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
    return r.stdout if r.returncode == 0 else None


def last_typing():
    """(time, device name) of the last key press on a keyboard, or (0, "")."""
    try:
        stamp, name = open(TYPING).read().strip().split(" ", 1)
        return int(stamp), name
    except (OSError, ValueError):
        return 0, ""


def tablet_mode():
    """KWin's tablet mode: on while the folio is not in its dock."""
    out = kwin("org.freedesktop.DBus.Properties.Get", "string:org.kde.KWin.TabletModeManager",
               "string:tabletMode", path="/org/kde/KWin")
    return out is not None and "boolean true" in out


def prop(name):
    out = kwin("org.freedesktop.DBus.Properties.Get", "string:org.kde.kwin.VirtualKeyboard", "string:" + name)
    return out is not None and "boolean true" in out


def set_prop(name, value):
    return kwin("org.freedesktop.DBus.Properties.Set", "string:org.kde.kwin.VirtualKeyboard",
                "string:" + name, "variant:boolean:" + ("true" if value else "false")) is not None


def set_osk(enabled):
    # Only the switch: forcing the keyboard up ("active") for a text field
    # that already had focus, while KWin was restarting Maliit, crashed
    # plasmashell (its Wayland connection broke). Tapping the field shows it.
    return set_prop("enabled", enabled)


def main():
    applied = None
    while True:
        kbd = keyboards()
        typed_at, typed_on = last_typing()
        if FOLIO in kbd and not tablet_mode():
            using = FOLIO + " (docked)"
        elif typed_on in kbd and typed_on != FOLIO and time.time() - typed_at < IDLE:
            using = typed_on + " (typed on)"
        else:
            using = ""
        want = not using
        if want != applied:
            if set_osk(want):
                print("on-screen keyboard %s%s" % ("on" if want else "off",
                      "" if want else " (keyboard: %s)" % using), flush=True)
                applied = want
            # else: KWin not ready yet, try again on the next round
        time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
