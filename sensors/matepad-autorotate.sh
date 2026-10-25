#!/bin/sh
# Quick switch for automatic screen rotation (the same setting as Display
# Settings > Orientation > Automatic). Talks to the KScreen KDED module;
# turning it off keeps the current orientation.
# usage: matepad-autorotate [toggle|on|off|status]
set -u
call() { busctl --user call org.kde.kded5 /modules/kscreen org.kde.KScreen "$@"; }
state=$(call getAutoRotate 2>/dev/null) || { echo "KScreen daemon not running" >&2; exit 1; }
case "$state" in *true) cur=true ;; *) cur=false ;; esac
case "${1:-toggle}" in
    status) echo "$cur"; exit 0 ;;
    on) new=true ;;
    off) new=false ;;
    toggle) [ "$cur" = true ] && new=false || new=true ;;
    *) echo "usage: $0 [toggle|on|off|status]" >&2; exit 2 ;;
esac
call setAutoRotate b "$new" >/dev/null
if [ "$new" = true ]; then msg="Automatic rotation on"; icon=rotation-allowed
else msg="Automatic rotation off (orientation locked)"; icon=rotation-locked; fi
busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications \
    org.freedesktop.Notifications Notify susssasa{sv}i \
    "Screen rotation" 0 "$icon" "$msg" "" 0 1 x-kde-display-appname s "Screen rotation" 2500 \
    >/dev/null 2>&1 || :
echo "$new"
