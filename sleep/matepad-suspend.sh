#!/bin/sh
# /usr/local/sbin/matepad-suspend: systemd-suspend.service's ExecStart on the
# MatePad 11 (drop-in matepad.conf), in place of systemd-sleep. Only Plasma's
# Sleep button suspends (logind); the power key and the cover just turn the
# screens off. Like Android, it stays asleep until the power key or the cover:
#
#   - Background wakes are common, more so on a charging dock: USB-PD
#     ("msg-rx", armed by the pdphy driver), thermal thresholds ("thr-int-en"),
#     the Bluetooth UART (the keyboard ending its idle link), and wakes the
#     kernel names "misconfigured IRQ 408 qcom,qmp-aop". When logind's
#     suspend ends, KWin 5.27 turns every output on (PrepareForSleep false),
#     so the loop does not end on such a wake: it stays dark for 10 s and
#     suspends again. A wake counts as the user's when the power key's or the
#     cover's interrupt counter moved (the reason string cannot tell), or when
#     the screens came on meanwhile: KWin eats a key press while its outputs
#     are off and turns them on (power key, Bluetooth keyboard).
#   - Wi-Fi: WoWLAN on (magic packet). Without any WoWLAN trigger cfg80211
#     drops the association, and qcacld's vdev_stop wakelock is a "hard"
#     wakeup event that aborts the suspend. (NetworkManager itself takes the
#     connection down for the sleep and back up after it.)
#   - USB host mode (dock): dwc3-msm refuses to suspend ("USB is outside LPM")
#     unless every USB device has runtime-suspended, and a suspend aborted after
#     the USB devices were suspended left the dock's hub stuck (-113 for every
#     request) until re-enumeration. The root hubs are de-authorized for the
#     sleep and re-authorized after it (like a replug; ~2 s). matepad-mediapoll
#     pauses meanwhile.
#   - Display: KWin turns the outputs off first (DPMS through the KMS shim,
#     which also suspends touch) and the script waits until the panel is off:
#     suspended with the panel on, the kernel restores it at 120 Hz without
#     the panel's 120 Hz command (a garbled band).
#   - Bluetooth: matepad-btd drops its UART clock vote (msm_geni refuses to
#     suspend while one is held) on logind's PrepareForSleep, so it stays
#     released through the dark wakes.
#
#   MATEPAD_RESLEEP_S (10)    seconds awake after a background wake
#   MATEPAD_DARK_WAKES (360)  background wakes before it gives up and stays
#                             awake (screens off)
S=/run/matepad-sleep
# The user of the active seat0 session (the stock image creates it at first
# boot); MATEPAD_SESSION_USER overrides.
session_user() {
	sid=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
	[ -n "$sid" ] && loginctl show-session "$sid" -p Name --value 2>/dev/null
}
SESSION_USER=${MATEPAD_SESSION_USER:-$(session_user)}
SESSION_USER=${SESSION_USER:-ubuntu}
PANEL=
for p in /sys/class/drm/card*-DSI-1/dpms; do
	[ -e "$p" ] && { PANEL=$p; break; }
done
RESLEEP=${MATEPAD_RESLEEP_S:-10}
MAX_DARK=${MATEPAD_DARK_WAKES:-360}

log() { echo "matepad-suspend: $*"; }

session_up() {
	uid=$(id -u "$SESSION_USER" 2>/dev/null) && [ -S /run/user/$uid/wayland-0 ]
}

dpms() {
	session_up || return 1
	timeout 5 runuser -u "$SESSION_USER" -- env XDG_RUNTIME_DIR=/run/user/$uid \
		WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland kscreen-doctor --dpms "$1" >/dev/null 2>&1
	log "screens $1 ($?)"
}

panel_on() { [ -n "$PANEL" ] && grep -q '^On' "$PANEL" 2>/dev/null; }

# interrupt counts of the power key and of the cover's hall sensor
user_irqs() {
	awk 'NR == 1 { cpus = NF }
	     /pon_kpdpwr_status|pm8941_pwrkey|hall0_north/ { s = 0
		for (i = 2; i <= cpus + 1; i++) s += $i
		printf "%s=%d ", $NF, s }' /proc/interrupts
}

cover_closed() {
	v=$(cat /sys/devices/platform/huawei_hall_sensor/get_hall_status 2>/dev/null) || return 1
	[ $(( v & 1 )) = 1 ]
}

# -- before ------------------------------------------------------------------
rm -rf $S
mkdir -p $S
for p in /sys/class/ieee80211/*; do
	[ -e "$p" ] && iw phy "${p##*/}" wowlan enable magic-packet 2>/dev/null
done
if systemctl -q is-active matepad-mediapoll.service; then
	systemctl stop matepad-mediapoll.service
	touch $S/mediapoll
fi
if ls /sys/bus/usb/devices | grep -q '^[0-9]*-'; then
	sync
	for r in /sys/bus/usb/devices/usb*; do
		echo 0 > "$r/authorized" && echo "${r##*/}" >> $S/usb
	done
	for i in 1 2 3 4 5 6 7 8 9 10; do
		grep -q suspended /sys/devices/platform/soc/a600000.ssusb/power/runtime_status 2>/dev/null && break
		sleep 0.3
	done
	log "USB detached ($(cat /sys/devices/platform/soc/a600000.ssusb/power/runtime_status 2>/dev/null))"
fi
dpms off
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	panel_on || break
	sleep 0.2
done
log "panel $(cat "$PANEL" 2>/dev/null)"

# -- sleep until the user wakes it -------------------------------------------
dark=0
failed=0
rc=0
while :; do
	before=$(user_irqs)
	if ! echo mem > /sys/power/state 2>/dev/null; then
		failed=$((failed + 1))
		log "suspend failed ($failed): $(head -c 100 /sys/kernel/wakeup_reasons/last_resume_reason 2>/dev/null)"
		# an event during the suspend entry aborts it: try a few times
		if [ $failed -lt 3 ] && [ "$before" = "$(user_irqs)" ] && ! panel_on; then
			sleep 1
			continue
		fi
		rc=1
		break
	fi
	failed=0
	after=$(user_irqs)
	log "resume: $(head -c 100 /sys/kernel/wakeup_reasons/last_resume_reason 2>/dev/null) ($before-> $after)"
	if [ -z "$PANEL" ] || [ -z "$before" ] || [ -z "$after" ]; then
		log "wake detection unavailable: staying awake"
		break
	fi
	if [ "$before" != "$after" ] && ! cover_closed; then
		break           # power key, or the cover opened
	fi
	# no desktop to wake the screens: do not loop
	session_up || break
	dark=$((dark + 1))
	if [ $dark -gt "$MAX_DARK" ]; then
		log "$dark background wakes: staying awake"
		break
	fi
	t=$((RESLEEP * 5))
	while [ $t -gt 0 ] && ! panel_on; do
		sleep 0.2
		t=$((t - 1))
	done
	if panel_on; then
		log "screens came on: awake"
		break
	fi
	log "background wake $dark: suspending again"
done

# -- after -------------------------------------------------------------------
for r in $(cat $S/usb 2>/dev/null); do
	echo 1 > "/sys/bus/usb/devices/$r/authorized"
done
[ -e $S/usb ] && log "USB re-attached"
[ -e $S/mediapoll ] && systemctl start --no-block matepad-mediapoll.service
rm -rf $S
# KWin turns the outputs on when logind reports the resume; with the cover
# closed they should stay off
if cover_closed; then
	systemd-run --quiet --no-block --collect --on-active=3 /bin/sh -c \
		"runuser -u $SESSION_USER -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland kscreen-doctor --dpms off"
fi
exit $rc
