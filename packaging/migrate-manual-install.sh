#!/bin/sh
# From the MatePad support installed by hand (images before the packages)
# to the packages: the rebuilt bluez and Qt Wayland client were held, and the
# patched libQt5WaylandClient sat over a diverted original. Undo both so the
# packages take over. Harmless when there is nothing to undo.
apt-mark unhold bluez libqt5waylandclient5 >/dev/null 2>&1 || true
L=/usr/lib/aarch64-linux-gnu/libQt5WaylandClient.so.5.15.13
if dpkg-divert --list 2>/dev/null | grep -q qtwayland-original; then
	dpkg-divert --package matepad --rename --remove "$L"
fi
