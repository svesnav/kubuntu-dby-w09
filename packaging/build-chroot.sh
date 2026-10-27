#!/bin/bash
# Runs packaging/build-packages.sh in an arm64 Ubuntu 24.04 root kept in
# WORK (debootstrap on the first run), so later runs reuse its build
# dependencies. qemu-user-static on x86-64.
# usage: sudo WORK=... build-chroot.sh OUT [PUBLISHED]
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "$1")
PUB=${2:-}
WORK=${WORK:-/var/tmp/matepad-packages}
ROOT=$WORK/root
MIRROR=http://ports.ubuntu.com/ubuntu-ports

unmount_all() {
	for m in tmp/out tmp/src var/cache/apt/archives dev/pts dev sys proc; do
		mountpoint -q "$ROOT/$m" && umount -l "$ROOT/$m" || true
	done
}
trap unmount_all EXIT
unmount_all

if [ ! -f "$ROOT/etc/os-release" ] || [ -d "$ROOT/debootstrap" ]; then
	rm -rf "$ROOT"
	debootstrap --arch=arm64 --foreign --variant=minbase --components=main,universe noble "$ROOT" $MIRROR
	chroot "$ROOT" /debootstrap/debootstrap --second-stage
	rm -f "$ROOT/etc/apt/sources.list"
	cat > "$ROOT/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb deb-src
URIs: $MIRROR
Suites: noble noble-updates noble-security
Components: main restricted universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
	echo 'Acquire::Retries "10";' > "$ROOT/etc/apt/apt.conf.d/80-retries"
fi
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mkdir -p "$WORK/apt-archives/partial" "$OUT" "$ROOT/tmp/src" "$ROOT/tmp/out"
mount --bind "$WORK/apt-archives" "$ROOT/var/cache/apt/archives"
mount --bind "$S" "$ROOT/tmp/src"
mount --bind "$OUT" "$ROOT/tmp/out"
rm -f "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
if [ -n "$PUB" ] && [ -f "$PUB" ]; then cp "$PUB" "$ROOT/tmp/published"; else : > "$ROOT/tmp/published"; fi
chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
	/bin/bash /tmp/src/packaging/build-packages.sh /tmp/src /tmp/out /tmp/published
