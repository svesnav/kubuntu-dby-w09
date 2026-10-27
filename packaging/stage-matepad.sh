#!/bin/bash
# Stages the MatePad 11 hardware support (this repo) into D, the tree of the
# matepad-dby-w09 package: compiled tools, scripts, services, rules, settings.
# Runs in an arm64 Ubuntu 24.04 with gcc, libsystemd-dev and kwriteconfig5.
# Enabling the services is the package's postinst (debian/postinst).
# usage: stage-matepad.sh SRC D
set -euo pipefail
S=$(cd "$1" && pwd)
D=$2
U=$D/etc/systemd/system
I() { install -D -m "$1" "$2" "$D$3"; }
mkdir -p "$D"

# ---- compiled tools
install -d $D/usr/local/lib/linux70-touch $D/usr/local/sbin $D/usr/local/bin
gcc -O2 -Wall -o $D/usr/local/lib/linux70-touch/binderfs-add $S/touch/binderfs_add.c
gcc -O2 -Wall -DWITH_SDBUS -o $D/usr/local/sbin/matepad-sensord $S/sensors/matepad_sensord.c -lsystemd -lm
gcc -O2 -Wall -pthread -o $D/usr/local/sbin/matepad-volkeys $S/sound/volkeys/matepad_volkeys.c -lsystemd
gcc -O2 -Wall -o $D/usr/local/sbin/matepad-tfa9874 $S/sound/matepad_tfa9874.c

# ---- the MatePad apt repository: its source, signing key and pin
I 644 $S/packaging/apt/matepad.sources /etc/apt/sources.list.d/matepad.sources
I 644 $S/packaging/apt/matepad.pref /etc/apt/preferences.d/matepad
I 644 $S/packaging/apt/matepad-archive-keyring.asc /usr/share/keyrings/matepad-archive-keyring.asc

# ---- what the installer app reads: the lists of the tablet's own files
install -D -m 644 -t $D/usr/share/matepad/device-files $S/device-files/manifest.txt $S/device-files/firmware.txt
# the speaker link's codec stub (linux,spdif-dit) is a module, and nothing
# else loads it before the sound card gives up waiting
install -d $D/etc/modules-load.d
printf 'qcom_pd_mapper\nsnd_soc_spdif_tx\n' > $D/etc/modules-load.d/matepad.conf

# ---- browser: Kubuntu's defaults name the Firefox snap (firefox_firefox.desktop),
# which leaves the panel's preferred://browser launcher dead, and Firefox's own
# "make default" then writes a hidden, icon-less userapp-Firefox-*.desktop.
# /etc/xdg comes before kubuntu-default-settings in XDG_CONFIG_DIRS.
install -d $D/etc/xdg
printf '[General]\nBrowserApplication=firefox.desktop\n' > $D/etc/xdg/kdeglobals
cat > $D/etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
application/xhtml+xml=firefox.desktop
EOF

# touch: Huawei's aptouch_daemon from the device files
I 755 $S/touch/linux70-touch.sh /usr/local/lib/linux70-touch/linux70-touch.sh
I 644 $S/touch/linux70-touch.service /etc/systemd/system/linux70-touch.service
# sensors / auto-rotation
I 644 $S/sensors/hexagonrpcd-sdsp.service /etc/systemd/system/hexagonrpcd-sdsp.service
I 644 $S/sensors/matepad-sensord.service /etc/systemd/system/matepad-sensord.service
I 644 $S/sensors/net.hadess.SensorProxy.conf /etc/dbus-1/system.d/net.hadess.SensorProxy.conf
I 755 $S/sensors/matepad-autorotate.sh /usr/local/bin/matepad-autorotate
I 644 $S/sensors/matepad-autorotate.desktop /usr/share/applications/matepad-autorotate.desktop
# KScreen rotates only in tablet mode by default, and KWin leaves tablet mode
# while the M-Pencil is connected: rotate the panel always. KScreen keeps it
# per output in control/outputs/<md5 of the name> (DSI-1 has no EDID).
I 644 $S/sensors/kscreen-dsi1-autorotate.json \
	/etc/skel/.local/share/kscreen/control/outputs/b5350822fc24a835e633b5bf90f2b56d
# speakers, mics, volume keys
I 644 $S/sound/matepad-tfa9874.service /etc/systemd/system/matepad-tfa9874.service
sed -i 's|matepad-tfa9874 watch$|matepad-tfa9874 watch /proc/asound/HuaweiMatePad11/pcm0p/sub0/status|' \
	$U/matepad-tfa9874.service
I 644 $S/sound/ucm2/Huawei-MatePad-11-DBY-W09.conf /usr/share/alsa/ucm2/conf.d/sm8250/Huawei-MatePad-11-DBY-W09.conf
I 644 $S/sound/ucm2/Huawei-MatePad-11-DBY-W09-HiFi.conf /usr/share/alsa/ucm2/conf.d/sm8250/Huawei-MatePad-11-DBY-W09-HiFi.conf
P=$S/sound/pipewire
I 644 $P/26-matepad-realtime.conf /etc/security/limits.d/26-matepad-realtime.conf
I 644 $P/user-realtime.conf /etc/systemd/system/user@.service.d/matepad-realtime.conf
I 644 $P/user-manager-realtime.conf /etc/systemd/user.conf.d/matepad-realtime.conf
I 644 $P/51-matepad-speakers.lua /etc/wireplumber/main.lua.d/51-matepad-speakers.lua
I 644 $P/52-matepad-speakers-raw.lua /etc/wireplumber/main.lua.d/52-matepad-speakers-raw.lua
I 644 $P/60-matepad-speaker-eq.conf /etc/pipewire/filter-chain.conf.d/60-matepad-speaker-eq.conf
I 644 $P/62-matepad-clock.conf /etc/pipewire/pipewire.conf.d/62-matepad-clock.conf
I 644 $P/filter-chain-wait-sink.conf /etc/systemd/user/filter-chain.service.d/matepad-wait-sink.conf
I 644 $P/directions.wav /usr/local/share/matepad-sound/directions.wav
# the PipeWire files name the card of the Linux 7.0 sound driver
for f in $D/etc/wireplumber/main.lua.d/51-matepad-speakers.lua $D/etc/wireplumber/main.lua.d/52-matepad-speakers-raw.lua \
	 $D/etc/pipewire/filter-chain.conf.d/60-matepad-speaker-eq.conf $D/etc/systemd/user/filter-chain.service.d/matepad-wait-sink.conf; do
	sed -i -e "s/alsa_output\.platform-soc_qcom_msm-audio-apr_qcom_q6core-audio_sound\./alsa_output.platform-sound./" \
	       -e "s/konaqrdsndcard/HuaweiMatePad11/g" -e "s/alsa_input\.\*kona\*/alsa_input.*HuaweiMatePad11*/" "$f"
done
python3 - $D/etc/wireplumber/main.lua.d/51-matepad-speakers.lua <<'EOF'
import sys
f = sys.argv[1]
t = open(f).read()
for anchor in ('["api.alsa.headroom"] = 2048,\n', '["audio.position"] = "FL,RC,FC,FR",\n'):
    i = t.find(anchor)
    if i < 0:
        sys.exit(f"{f}: {anchor.strip()} not found")
    rest = t[i + len(anchor):]
    if not rest.lstrip().startswith('["audio.format"]'):
        t = t[:i + len(anchor)] + '    ["audio.format"] = "S16LE",\n' + rest
open(f, "w").write(t)
EOF
I 644 $S/sound/volkeys/matepad-volkeys.service /etc/systemd/system/matepad-volkeys.service
# the cover's hall sensor is a gpio-keys lid switch on Linux 7.0 (matepad-cover)
install -d $U/matepad-volkeys.service.d
printf '[Service]\nEnvironment=MATEPAD_VOLKEYS_INPUTS=gpio-keys,pm8941_resin,pm8941_pwrkey,matepad-cover\n' \
	> $U/matepad-volkeys.service.d/linux70.conf
# M-Pencil
I 644 $S/pen/pen.py /usr/local/lib/matepad-pen/pen.py
I 644 $S/pen/matepad-pen-bluez.py /usr/local/lib/matepad-pen/matepad-pen-bluez.py
I 644 $S/pen/61-matepad-pen-hidraw.rules /etc/udev/rules.d/61-matepad-pen-hidraw.rules
I 644 $S/pen/matepad-pen-bluez.service /etc/systemd/system/matepad-pen-bluez.service
# the pen does not advertise as discoverable, so Plasma never lists it: pair it
# once by the address the installer copied from HarmonyOS (/etc/matepad/pen-mac)
I 644 $S/pen/matepad-pen-pair.py /usr/local/lib/matepad-pen/matepad-pen-pair.py
I 644 $S/pen/matepad-pen-pair.service /etc/systemd/system/matepad-pen-pair.service
# cameras: the Camera app (viewfinder turned with the panel, rear autofocus,
# photos to ~/Pictures/Camera) and access to the camera devices for the user
I 755 $S/camera/matepad-camera /usr/local/bin/matepad-camera
I 644 $S/camera/matepad-camera.desktop /usr/share/applications/matepad-camera.desktop
I 644 $S/camera/70-matepad-camera.rules /etc/udev/rules.d/70-matepad-camera.rules
# flashlight: the rear flash LED in torch mode
I 755 $S/flashlight/matepad-flashlight /usr/local/bin/matepad-flashlight
I 644 $S/flashlight/matepad-flashlight.desktop /usr/share/applications/matepad-flashlight.desktop
I 644 $S/flashlight/61-matepad-flashlight.rules /etc/udev/rules.d/61-matepad-flashlight.rules
# USB-C: HDMI audio, DP EDID recovery, DDC/CI access, docked rotation
I 755 $S/usb/matepad-hdmi-audio.py /usr/local/bin/matepad-hdmi-audio-linux70
I 755 $S/usb/matepad-dp-recover.py /usr/local/sbin/matepad-dp-recover
I 755 $S/usb/fix_docked_rotation.py /usr/local/bin/matepad-fix-docked-rotation
I 644 $S/usb/60-matepad-ddc.rules /etc/udev/rules.d/60-matepad-ddc.rules
cat > $U/matepad-dp-recover.service <<'EOF'
[Unit]
Description=MatePad Linux 7.0 missing DisplayPort EDID recovery
After=systemd-udev-trigger.service
[Service]
ExecStart=/usr/local/sbin/matepad-dp-recover
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
install -d $D/etc/systemd/user $D/etc/xdg/autostart
cat > $D/etc/systemd/user/matepad-hdmi-audio.service <<'EOF'
[Unit]
Description=MatePad Linux 7.0 HDMI/DisplayPort audio hotplug
After=pipewire.service wireplumber.service
BindsTo=pipewire.service
ConditionUser=!@system
[Service]
ExecStart=/usr/local/bin/matepad-hdmi-audio-linux70
Restart=on-failure
[Install]
WantedBy=pipewire.service
EOF
cat > $D/etc/xdg/autostart/matepad-fix-docked-rotation.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=MatePad docked rotation fix
Exec=/usr/local/bin/matepad-fix-docked-rotation
OnlyShowIn=KDE;
X-KDE-autostart-phase=1
NoDisplay=true
EOF
# charging LED
I 755 $S/power/matepad-chargeled.py /usr/local/sbin/matepad-chargeled-linux70
I 644 $S/power/matepad-chargeled-linux70.service /etc/systemd/system/matepad-chargeled-linux70.service
# sleep: Sleep button suspends, power key and cover only turn the screen off
I 755 $S/sleep/matepad-suspend.sh /usr/local/sbin/matepad-suspend
I 644 $S/sleep/systemd-suspend-matepad.conf /etc/systemd/system/systemd-suspend.service.d/matepad.conf
I 644 $S/sleep/50-matepad-power-key.conf /etc/systemd/logind.conf.d/50-matepad-power-key.conf
I 644 $S/sleep/50-matepad-sleep.rules /etc/polkit-1/rules.d/50-matepad-sleep.rules
install -d $D/etc/skel/.config
bash $S/sleep/matepad-powerdevil-profile.sh $D/etc/skel/.config/powermanagementprofilesrc
# desktop
I 755 $S/desktop/matepad-tray-relayout /usr/local/bin/matepad-tray-relayout
I 644 $S/desktop/matepad-tray-relayout.service /etc/systemd/system/matepad-tray-relayout.service
I 755 $S/desktop/matepad-plasmashell-guard.sh /usr/local/bin/matepad-plasmashell-guard
I 644 $S/desktop/matepad-plasmashell-guard.desktop /etc/xdg/autostart/matepad-plasmashell-guard.desktop
I 755 $S/desktop/osk/matepad-osk-auto.py /usr/local/bin/matepad-osk-auto
I 644 $S/desktop/osk/matepad-osk-auto.desktop /etc/xdg/autostart/matepad-osk-auto.desktop
I 755 $S/desktop/osk/matepad-typing-watch /usr/local/sbin/matepad-typing-watch
I 644 $S/desktop/osk/matepad-typing-watch.service /etc/systemd/system/matepad-typing-watch.service
printf '[Plugins]\nblurEnabled=false\n' > $D/etc/xdg/kwinrc     # popups: no outline before the slide
# the on-screen keyboard: KWin shows a virtual keyboard only with one set here
# (System Settings > Virtual Keyboard); matepad-osk-auto switches it on and off.
# Maliit 2.3 draws Qt Quick Controls keys: started by KWin it has no style set
# and stays light, so the launcher sets Plasma's (org.kde.desktop), which
# follows the colour scheme (dark keys with Breeze Dark). Its languages: the
# installer, from the keyboard layouts.
I 644 $S/desktop/osk/matepad-maliit-keyboard.desktop /usr/share/applications/matepad-maliit-keyboard.desktop
printf '[Wayland]\nInputMethod=/usr/share/applications/matepad-maliit-keyboard.desktop\n' >> $D/etc/xdg/kwinrc
cat > $D/usr/local/bin/kwin_wayland <<'EOF'
#!/bin/sh
# KWin's OpenGL compositor on the Adreno 650 (freedreno).
export KWIN_COMPOSE=O2
exec /usr/bin/kwin_wayland "$@"
EOF
chmod 755 $D/usr/local/bin/kwin_wayland
# SDDM: Plasma (Wayland) as the default session; the greeter itself on KWin Wayland
install -d $D/etc/sddm.conf.d
cat > $D/etc/sddm.conf.d/matepad.conf <<'EOF'
# Plasma (Wayland) as the default session; the greeter itself on KWin Wayland.
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell
[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
[Autologin]
Session=plasmawayland
EOF
# Restart to HarmonyOS
I 755 $S/boot-switch/matepad-boot-harmonyos /usr/local/sbin/matepad-boot-harmonyos
I 755 $S/boot-switch/matepad-boot-harmonyos-gui /usr/local/bin/matepad-boot-harmonyos-gui
I 644 $S/boot-switch/boot-linux.sh /usr/local/share/matepad/boot-linux.sh
I 644 $S/boot-switch/org.matepad.boot-harmonyos.policy /usr/share/polkit-1/actions/org.matepad.boot-harmonyos.policy
I 644 $S/boot-switch/matepad-boot-harmonyos.desktop /usr/share/applications/matepad-boot-harmonyos.desktop
I 755 $S/boot-switch/matepad-boot-harmonyos.desktop /etc/skel/Desktop/matepad-boot-harmonyos.desktop
# first boot: derive the hardware data from the copied device files
I 755 $S/image/matepad-device-setup /usr/local/sbin/matepad-device-setup
I 644 $S/image/matepad-device-setup.service /etc/systemd/system/matepad-device-setup.service
