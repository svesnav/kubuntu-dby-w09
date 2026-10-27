#!/bin/sh
# From the MatePad support installed by hand (images before the packages)
# to the packages: the rebuilt bluez and Qt Wayland client were held, and the
# patched libQt5WaylandClient sat over a diverted original. Undo both so the
# packages take over. Harmless when there is nothing to undo.
#   migrate-manual-install.sh          before installing matepad-dby-w09
#   migrate-manual-install.sh --after  after: dpkg kept the hand-installed copies
#                                      of the package's settings; its versions win
if [ "$1" = --after ]; then
	dpkg-query -W -f='${Conffiles}\n' matepad-dby-w09 | while read -r f _; do
		if [ -f "$f.dpkg-dist" ]; then
			mv -f "$f" "$f.dpkg-old" && mv "$f.dpkg-dist" "$f"
		fi
	done
	exit 0
fi
apt-mark unhold bluez libqt5waylandclient5 >/dev/null 2>&1 || true
L=/usr/lib/aarch64-linux-gnu/libQt5WaylandClient.so.5.15.13
if dpkg-divert --list 2>/dev/null | grep -q qtwayland-original; then
	rm -f "$L"	# the patched copy: --rename will not overwrite it
	dpkg-divert --package matepad --rename --remove "$L"
fi
