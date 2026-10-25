#!/bin/bash
# Build the stock Kubuntu 24.04 (arm64) image for the MatePad 11 on Linux 7.0.
#
#   sudo image/build-image.sh --kernel linux-boot-<release>.tar [--out DIR]
#        [--size 16G] [--dev-key ~/.ssh/id_ed25519.pub] [--resume]
#
# Runs on Ubuntu x86-64 (needs debootstrap, qemu-user-static with binfmt) or
# arm64. The image carries no Huawei files: the installer copies those from
# the tablet (device-files/). Output in DIR (default ./out):
#   kubuntu-dby-w09-<date>.img.xz   ext4 root, label LINUX70ROOT, xz  
#   kubuntu-dby-w09-<date>.img.xz.sha256, .packages (dpkg list)
# --kernel is the boot bundle of a linux-dby-w09 release: its modules go to
# /usr/lib/modules, the rest to /usr/lib/matepad/linux-boot for the installer.
# --dev-key adds an SSH server with that key for root and a root console on
# the USB serial port: for development builds only, never for releases.
# --resume keeps the base system of an earlier (failed) build in WORK and
# runs the setup inside it again.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
KERNEL= OUT=$PWD/out SIZE=16G DEVKEY= RESUME=
SUITE=noble MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
while [ $# -gt 0 ]; do
	case $1 in
	--kernel) KERNEL=$(realpath "$2"); shift 2 ;;
	--resume) RESUME=1; shift ;;
	--out) OUT=$2; shift 2 ;;
	--size) SIZE=$2; shift 2 ;;
	--dev-key) DEVKEY=$(realpath "$2"); shift 2 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "--kernel linux-boot-<release>.tar is required" >&2; exit 1; }

WORK=${WORK:-/var/tmp/matepad-image}
ROOT=$WORK/root
APT_CACHE=${APT_CACHE:-$WORK/apt-archives}
STAMP=$(date -u +%Y%m%d)
NAME=kubuntu-dby-w09-$STAMP
mkdir -p "$WORK" "$OUT"

unmount_all() {
	for m in var/cache/apt/archives run dev/pts dev sys proc; do
		mountpoint -q "$ROOT/$m" && umount -l "$ROOT/$m" || true
	done
}
trap unmount_all EXIT

# The kernel bundle, checked.
B=$WORK/linux-boot
rm -rf "$B" && mkdir -p "$B"
tar -C "$B" --strip-components=1 -xf "$KERNEL"
(cd "$B" && sha256sum -c --quiet SHA256SUMS)

# 1. Base system (two stages, so it also works on x86-64 through qemu).
unmount_all
if [ -n "$RESUME" ] && [ -f "$ROOT/etc/os-release" ] && [ ! -d "$ROOT/debootstrap" ]; then
	echo "resuming in the base system at $ROOT"
else
	rm -rf "$ROOT"
	debootstrap --arch=arm64 --foreign --variant=minbase \
		--components=main,restricted,universe,multiverse \
		--include=ca-certificates,locales,gnupg,curl \
		"$SUITE" "$ROOT" "$MIRROR"
	chroot "$ROOT" /debootstrap/debootstrap --second-stage
fi

# 2. Everything else inside the target.
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount -t tmpfs tmpfs "$ROOT/run"
# Name resolution for the setup: a plain file (systemd-resolved turns it into
# a link to /run, which is empty here; put back at the end).
rm -f "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
# Downloaded .debs survive between builds (and failed downloads mid-build).
mkdir -p "$APT_CACHE/partial"
mount --bind "$APT_CACHE" "$ROOT/var/cache/apt/archives"
S=$ROOT/tmp/matepad-src
rm -rf "$S" && mkdir -p "$S"
tar -C "$REPO" --exclude=.git --exclude=build --exclude=out --exclude=__pycache__ -cf - . | tar -C "$S" -xf -
cp "$B/linux-modules.tar.gz" "$ROOT/tmp/linux-modules.tar.gz"
rm -rf "$ROOT/tmp/linux-boot" && cp -r "$B" "$ROOT/tmp/linux-boot"
[ -n "$DEVKEY" ] && cp "$DEVKEY" "$ROOT/tmp/dev-key.pub"
chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
	/bin/bash /tmp/matepad-src/image/chroot-setup.sh
chroot "$ROOT" dpkg-query -W -f '${Package}\t${Version}\n' > "$OUT/$NAME.img.xz.packages"
rm -rf "$S" "$ROOT/tmp/linux-modules.tar.gz" "$ROOT/tmp/linux-boot" "$ROOT/tmp/dev-key.pub"
rm -f "$ROOT/etc/resolv.conf"
if [ -e "$ROOT/usr/lib/systemd/systemd-resolved" ]; then
	ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
else
	: > "$ROOT/etc/resolv.conf"
fi
unmount_all

# 3. ext4 image of the tree, shrunk to its contents plus 2 GiB (the
#    installer copies the device files in; Linux grows it to the card).
IMG=$WORK/$NAME.img
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
# Without the e2fsprogs 1.47 defaults that HarmonyOS's 4.19 kernel cannot
# mount: the installer copies the device files in from there.
mkfs.ext4 -q -F -L LINUX70ROOT -O ^orphan_file,^metadata_csum_seed -E root_owner=0:0 -d "$ROOT" "$IMG"
e2fsck -fy "$IMG" >/dev/null
resize2fs -M "$IMG" >/dev/null
blocks=$(dumpe2fs -h "$IMG" 2>/dev/null | sed -n 's/^Block count: *//p')
truncate -s $(( blocks * 4096 + 2048 * 1024 * 1024 )) "$IMG"
resize2fs "$IMG" >/dev/null
e2fsck -fy "$IMG" >/dev/null
xz -9 -T0 --memlimit-compress=40% -c "$IMG" > "$OUT/$NAME.img.xz"
(cd "$OUT" && sha256sum "$NAME.img.xz" > "$NAME.img.xz.sha256")
stat -c %s "$IMG" > "$OUT/$NAME.img.size"	# for the installer's progress
rm -f "$IMG"
ls -l "$OUT/$NAME".img.xz*
