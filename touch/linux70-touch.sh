#!/bin/sh
# linux70-touch.service: Huawei's aptouch_daemon on Linux 7.0 (microSD
# profile).  Adapted from probe_android_touch_in_ubuntu.sh (4.19); the kernel
# side is touch/huawei-thp-lite.c, binderfs creates binder/hwbinder/vndbinder
# itself (CONFIG_ANDROID_BINDER_DEVICES).
set -eu
H=/usr/local/lib/linux70-touch
exec >> /var/log/linux70-aptouch.log 2>&1
echo "start $(date -u) kernel $(uname -r)"

for name in thp input_mt_wrapper; do
	[ -c "/dev/$name" ] || { echo "/dev/$name missing"; exit 1; }
	chown 1000:1000 "/dev/$name"
	chmod 660 "/dev/$name"
done
chmod 644 /sys/touchscreen/touch_chip_info
echo "chip: $(cat /sys/touchscreen/touch_chip_info)"

mkdir -p /dev/__properties__ /dev/binderfs
cp -a /android-properties/. /dev/__properties__/
# Optional local override of the vendor touch rules (the 4.19-era setup had one).
[ -f "$H/codex-thp-rules.xml" ] && cp "$H/codex-thp-rules.xml" /vendor/lib64/thp_project_id_match_rules.xml
# getprop through the device's own toybox (or an older local copy)
TB=$H/codex-toolbox
[ -x "$TB" ] || TB=/system/bin/toybox
ln -sf "$TB" /tmp/getprop
model=$(/system/bin/linker64 /tmp/getprop ro.product.model)
[ "$model" = DBY-W09 ] || { echo "Android property area not readable ($model)"; exit 1; }

grep -qs ' /dev/binderfs binder ' /proc/mounts || mount -t binder binder /dev/binderfs
for name in binder hwbinder vndbinder; do
	# A binderfs mount only brings "binder" here; add the others.
	[ -e "/dev/binderfs/$name" ] || "$H/binderfs-add" /dev/binderfs/binder-control "$name"
	ln -sf "/dev/binderfs/$name" "/dev/$name"
	chmod 666 "/dev/binderfs/$name"
done

export LD_LIBRARY_PATH=/vendor/lib64:/system/lib64:/apex/com.android.runtime/lib64/bionic
# UID 1000 is also the desktop user: RLIMIT_NPROC counts its tasks, so allow
# 192 on top of what it already runs (see README "Touch in long boots").
nproc=$(( $(ps -L -U 1000 --no-headers 2>/dev/null | wc -l) + 192 ))
exec bash -c "ulimit -u $nproc; exec setpriv --no-new-privs --reuid 1000 --regid 1000 --clear-groups /system/bin/linker64 /vendor/bin/aptouch_daemon"
