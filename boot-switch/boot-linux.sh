#!/system/bin/sh
# /cache/linux70/boot-linux.sh: run in HarmonyOS as root to restart into the
# microSD Linux:   su -c sh /cache/linux70/boot-linux.sh
# Writes the Linux boot/ramdisk/dtbo images that matepad-boot-harmonyos saved
# next to this script (checked against SHA256SUMS before and after), then
# reboots. The HarmonyOS installer app does the same with a button.
set -e
D=$(cd "$(dirname "$0")" && pwd)
cd "$D"

part() {
	for base in /dev/block/by-name /dev/block/bootdevice/by-name \
	            /dev/block/platform/soc/1d84000.ufshc/by-name; do
		[ -e "$base/$1" ] && { echo "$base/$1"; return 0; }
	done
	echo "no partition $1" >&2
	return 1
}

sha256sum -c SHA256SUMS
for p in boot ramdisk dtbo; do
	dev=$(part $p)
	size=$(wc -c < $p.img)
	want=$(sha256sum $p.img | cut -d' ' -f1)
	dd if=$p.img of="$dev" bs=1048576 conv=fsync 2>/dev/null
	got=$(head -c "$size" "$dev" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$want" ] || { echo "$p: readback mismatch" >&2; exit 1; }
	echo "$p: Linux image written and verified"
done
sync
reboot
