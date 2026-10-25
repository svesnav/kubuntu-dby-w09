#!/bin/sh
# Restart plasmashell if it dies in the middle of the session. Plasma 5.27
# started without systemd (dbus-run-session) never restarts it, so a crash
# leaves only KWin and a black screen. Seen once (2026-10-19): KWin dropped
# plasmashell for a malformed org_kde_kwin_shadow.attach_bottom_right while
# the volume OSD was shown during a screen rotation.
# Started from /etc/xdg/autostart in the Plasma session; quits with it.
gone=0
while sleep 2; do
    pgrep -u "$(id -u)" -x ksmserver >/dev/null || exit 0      # session ending
    if pgrep -u "$(id -u)" -x plasmashell >/dev/null; then
        gone=0
        continue
    fi
    gone=$((gone + 1))
    [ "$gone" -ge 2 ] || continue
    echo "plasmashell is gone; restarting it"
    # Its output goes to the journal (tag plasmashell): a Wayland protocol
    # error that makes KWin drop it is only printed there.
    setsid systemd-cat -t plasmashell plasmashell < /dev/null &
    gone=-5          # give it time to start before checking again
done
