#!/bin/bash
# Runs inside the arm64 target (called by build-image.sh): stock Kubuntu 24.04
# plus the MatePad 11 hardware support from this repo. No Huawei files: those
# come from the tablet at install time (device-files/, image/device-setup).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
S=/tmp/matepad-src
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
echo 'Acquire::Retries "10";' > /etc/apt/apt.conf.d/80-matepad-build-retries

# ---- apt: Ubuntu archive with sources, no snaps, Mozilla's Firefox .deb
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/ubuntu.sources <<'EOF'
Types: deb deb-src
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb deb-src
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
cat > /etc/apt/preferences.d/no-snap <<'EOF'
# The image has no snapd: Firefox comes from Mozilla's APT repository.
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
	> /etc/apt/sources.list.d/mozilla.list
cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get update
$APT dist-upgrade

# ---- the stock desktop and first-boot setup
locale-gen en_US.UTF-8
echo 'LANG=en_US.UTF-8' > /etc/default/locale
$APT install kubuntu-desktop firefox sddm oem-config oem-config-kde \
	language-pack-en language-pack-kde-en plasma-workspace-wayland xserver-xorg xserver-xorg-input-libinput \
	network-manager bluez linux-firmware systemd-timesyncd \
	xournalpp kdialog pkexec python3-dbus python3-gi \
	maliit-keyboard ddcutil ddcui upower i2c-tools 	python3-pyqt6 python3-numpy libyaml-0-2 libdw1t64 libevent-2.1-7t64 libepoxy0 libtiff6
# Kubuntu's defaults name the Firefox snap (firefox_firefox.desktop), which
# leaves the panel's preferred://browser launcher dead, and Firefox's own
# "make default" then writes a hidden, icon-less userapp-Firefox-*.desktop.
# /etc/xdg comes before kubuntu-default-settings in XDG_CONFIG_DIRS.
printf '[General]\nBrowserApplication=firefox.desktop\n' > /etc/xdg/kdeglobals
cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
application/xhtml+xml=firefox.desktop
EOF

# ---- build our tools, then remove the build dependencies again
BUILD_DEPS="build-essential pkg-config libsystemd-dev git meson ninja-build dpkg-dev fakeroot devscripts"
$APT install $BUILD_DEPS
B=/tmp/matepad-build
rm -rf $B && mkdir -p $B
install -d /usr/local/lib/linux70-touch /usr/local/sbin /usr/local/bin
gcc -O2 -Wall -o /usr/local/lib/linux70-touch/binderfs-add $S/touch/binderfs_add.c
gcc -O2 -Wall -DWITH_SDBUS -o /usr/local/sbin/matepad-sensord $S/sensors/matepad_sensord.c -lsystemd -lm
gcc -O2 -Wall -pthread -o /usr/local/sbin/matepad-volkeys $S/sound/volkeys/matepad_volkeys.c -lsystemd
gcc -O2 -Wall -o /usr/local/sbin/matepad-tfa9874 $S/sound/matepad_tfa9874.c

# hexagonrpcd with the Huawei patches (sensors/hexagonrpcd-*.py)
git clone -q https://github.com/linux-msm/hexagonrpc.git $B/hexagonrpc
(cd $B/hexagonrpc && git checkout -q da7a3742ab8d5273a281b70ee11f16fb2cb6a690 &&
	python3 $S/sensors/hexagonrpcd-odm.py hexagonrpcd &&
	python3 $S/sensors/hexagonrpcd-sns-registry.py hexagonrpcd $S/sensors/sns_registry.c &&
	meson setup build --prefix=/usr/local >/dev/null && ninja -C build >/dev/null &&
	ninja -C build install >/dev/null && ldconfig &&	# hexagonrpcd and its libhexagonrpc
	ldd /usr/local/bin/hexagonrpcd | grep -q 'libhexagonrpc.* => /')

# BlueZ with the HOG CCC-read fix (bluetooth/hog-ccc-read-error.patch); held
# once installed, so a resumed build (build-image.sh --resume) skips it
apt-mark showhold | grep -qx bluez ||
(cd $B && apt-get source -q bluez && $APT build-dep bluez &&
	cd bluez-[0-9]*/ && cp $S/bluetooth/hog-ccc-read-error.patch debian/patches/ &&
	echo hog-ccc-read-error.patch >> debian/patches/series &&
	DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -us -uc -b >/dev/null &&
	cd .. && $APT install --allow-downgrades ./bluez_*_arm64.deb && apt-mark hold bluez)

# libQt5WaylandClient with the buffer-scale fix (desktop/qt/), the packaged
# library diverted to /usr/lib/matepad/qtwayland-original (skipped once done)
dpkg-divert --list | grep -q qtwayland-original ||
(cd $B && apt-get source -q qtwayland-opensource-src && $APT build-dep qtwayland-opensource-src &&
	cd qtwayland-opensource-src-*/ && patch -p1 < $S/desktop/qt/qtwayland-shm-scale-change.patch &&
	mkdir build && cd build && /usr/lib/qt5/bin/qmake ../qtwayland.pro >/dev/null && make qmake_all >/dev/null &&
	make -j"$(nproc)" -C src sub-client >/dev/null &&
	L=/usr/lib/aarch64-linux-gnu/libQt5WaylandClient.so.5.15.13 &&
	install -d /usr/lib/matepad/qtwayland-original &&
	dpkg-divert --package matepad --rename --divert /usr/lib/matepad/qtwayland-original/libQt5WaylandClient.so.5.15.13 --add $L &&
	strip --strip-unneeded -o $L lib/libQt5WaylandClient.so.5.15.13 && apt-mark hold libqt5waylandclient5)

# libcamera 0.7.2 for the cameras (camera/): software ISP with GPU debayer,
# Python bindings for the Camera app, gain models for the OV13B10 and Hi-846
# (camera/libcamera-sensor-helpers.py). Ubuntu's 0.2 has no software ISP, so
# it goes to /usr/local; skipped once installed.
LIBCAMERA_DEPS="libyaml-dev python3-yaml python3-ply python3-jinja2 libgnutls28-dev libudev-dev
	libevent-dev libdw-dev libdrm-dev libjpeg-dev libtiff-dev libepoxy-dev libegl-dev libgles-dev
	pybind11-dev python3-dev"
[ -x /usr/local/bin/cam ] ||
($APT install $LIBCAMERA_DEPS &&
	git clone -q --depth 1 --branch v0.7.2 https://git.libcamera.org/libcamera/libcamera.git $B/libcamera &&
	cd $B/libcamera && python3 $S/camera/libcamera-sensor-helpers.py src/ipa/libipa/camera_sensor_helper.cpp &&
	meson setup build --prefix=/usr/local --buildtype=release -Dpipelines=simple -Dipas=simple 		-Dcam=enabled -Dqcam=disabled -Dgstreamer=disabled -Dv4l2=false -Ddocumentation=disabled 		-Dtest=false -Dlc-compliance=disabled -Dpycamera=enabled >/dev/null &&
	ninja -C build >/dev/null && ninja -C build install >/dev/null && ldconfig &&
	apt-mark auto $LIBCAMERA_DEPS >/dev/null)
[ -x /usr/local/bin/cam ]
python3 -c "import sys; sys.path.insert(0, '/usr/local/lib/python3/dist-packages'); import libcamera"

apt-mark auto $BUILD_DEPS >/dev/null
$APT autoremove --purge
rm -rf $B

# ---- the kernel (linux-dby-w09): its Debian package when the bundle has one,
#      so later kernels update with apt; it puts the modules in /usr/lib/modules
#      and the boot files the installer app reads in /usr/lib/matepad/linux-boot
#      (in a chroot its postinst leaves the boot partitions alone)
deb=$(ls /tmp/linux-boot/linux-image-dby-w09_*_arm64.deb 2>/dev/null | head -n 1 || true)
if [ -n "$deb" ]; then
	$APT install "$deb"
else	# older bundles: modules tarball and loose boot files
	install -d /usr/lib/modules
	tar -xzf /tmp/linux-modules.tar.gz -C /usr/lib/modules
	for k in /usr/lib/modules/*-dby-w09*; do depmod "$(basename "$k")"; done
	install -d /usr/lib/matepad/linux-boot
	(cd /tmp/linux-boot && grep -E ' (Image\.gz|sm8250-huawei-dby-w09\.dtb|dtbo\.img|ramdisk-payload\.img|cmdline\.txt|release\.txt)$' SHA256SUMS \
			> /usr/lib/matepad/linux-boot/SHA256SUMS &&
		cp Image.gz sm8250-huawei-dby-w09.dtb dtbo.img ramdisk-payload.img cmdline.txt release.txt /usr/lib/matepad/linux-boot/)
fi
(cd /usr/lib/matepad/linux-boot && sha256sum -c SHA256SUMS)
# the speaker link's codec stub (linux,spdif-dit) is a module, and nothing
# else loads it before the sound card gives up waiting
printf 'qcom_pd_mapper\nsnd_soc_spdif_tx\n' > /etc/modules-load.d/matepad.conf

# ---- what the installer app reads from the image: the lists of the tablet's own files
install -D -m 644 -t /usr/share/matepad/device-files $S/device-files/manifest.txt $S/device-files/firmware.txt

# ---- MatePad components (each folder's install script does the same on a
#      running system)
I() { install -D -m "$1" "$2" "$3"; }
U=/etc/systemd/system

# touch: Huawei's aptouch_daemon from the device files
I 755 $S/touch/linux70-touch.sh /usr/local/lib/linux70-touch/linux70-touch.sh
I 644 $S/touch/linux70-touch.service $U/linux70-touch.service
# sensors / auto-rotation
I 644 $S/sensors/hexagonrpcd-sdsp.service $U/hexagonrpcd-sdsp.service
I 644 $S/sensors/matepad-sensord.service $U/matepad-sensord.service
I 644 $S/sensors/net.hadess.SensorProxy.conf /etc/dbus-1/system.d/net.hadess.SensorProxy.conf
I 755 $S/sensors/matepad-autorotate.sh /usr/local/bin/matepad-autorotate
I 644 $S/sensors/matepad-autorotate.desktop /usr/share/applications/matepad-autorotate.desktop
# KScreen rotates only in tablet mode by default, and KWin leaves tablet mode
# while the M-Pencil is connected: rotate the panel always. KScreen keeps it
# per output in control/outputs/<md5 of the name> (DSI-1 has no EDID).
I 644 $S/sensors/kscreen-dsi1-autorotate.json 	/etc/skel/.local/share/kscreen/control/outputs/b5350822fc24a835e633b5bf90f2b56d
# speakers, mics, volume keys
I 644 $S/sound/matepad-tfa9874.service $U/matepad-tfa9874.service
sed -i 's|matepad-tfa9874 watch$|matepad-tfa9874 watch /proc/asound/HuaweiMatePad11/pcm0p/sub0/status|' $U/matepad-tfa9874.service
I 644 $S/sound/ucm2/Huawei-MatePad-11-DBY-W09.conf /usr/share/alsa/ucm2/conf.d/sm8250/Huawei-MatePad-11-DBY-W09.conf
I 644 $S/sound/ucm2/Huawei-MatePad-11-DBY-W09-HiFi.conf /usr/share/alsa/ucm2/conf.d/sm8250/Huawei-MatePad-11-DBY-W09-HiFi.conf
P=$S/sound/pipewire
I 644 $P/26-matepad-realtime.conf /etc/security/limits.d/26-matepad-realtime.conf
I 644 $P/user-realtime.conf $U/user@.service.d/matepad-realtime.conf
I 644 $P/user-manager-realtime.conf /etc/systemd/user.conf.d/matepad-realtime.conf
I 644 $P/51-matepad-speakers.lua /etc/wireplumber/main.lua.d/51-matepad-speakers.lua
I 644 $P/52-matepad-speakers-raw.lua /etc/wireplumber/main.lua.d/52-matepad-speakers-raw.lua
I 644 $P/60-matepad-speaker-eq.conf /etc/pipewire/filter-chain.conf.d/60-matepad-speaker-eq.conf
I 644 $P/62-matepad-clock.conf /etc/pipewire/pipewire.conf.d/62-matepad-clock.conf
I 644 $P/filter-chain-wait-sink.conf /etc/systemd/user/filter-chain.service.d/matepad-wait-sink.conf
I 644 $P/directions.wav /usr/local/share/matepad-sound/directions.wav
# the PipeWire files name the card of the Linux 7.0 sound driver
for f in /etc/wireplumber/main.lua.d/51-matepad-speakers.lua /etc/wireplumber/main.lua.d/52-matepad-speakers-raw.lua \
	 /etc/pipewire/filter-chain.conf.d/60-matepad-speaker-eq.conf /etc/systemd/user/filter-chain.service.d/matepad-wait-sink.conf; do
	sed -i -e "s/alsa_output\.platform-soc_qcom_msm-audio-apr_qcom_q6core-audio_sound\./alsa_output.platform-sound./" \
	       -e "s/konaqrdsndcard/HuaweiMatePad11/g" -e "s/alsa_input\.\*kona\*/alsa_input.*HuaweiMatePad11*/" "$f"
done
python3 - /etc/wireplumber/main.lua.d/51-matepad-speakers.lua <<'EOF'
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
I 644 $S/sound/volkeys/matepad-volkeys.service $U/matepad-volkeys.service
mkdir -p $U/matepad-volkeys.service.d
# the cover's hall sensor is a gpio-keys lid switch on Linux 7.0 (matepad-cover)
printf '[Service]\nEnvironment=MATEPAD_VOLKEYS_INPUTS=gpio-keys,pm8941_resin,pm8941_pwrkey,matepad-cover\n' \
	> $U/matepad-volkeys.service.d/linux70.conf
# M-Pencil
I 644 $S/pen/pen.py /usr/local/lib/matepad-pen/pen.py
I 644 $S/pen/matepad-pen-bluez.py /usr/local/lib/matepad-pen/matepad-pen-bluez.py
I 644 $S/pen/61-matepad-pen-hidraw.rules /etc/udev/rules.d/61-matepad-pen-hidraw.rules
I 644 $S/pen/matepad-pen-bluez.service $U/matepad-pen-bluez.service
# the pen does not advertise as discoverable, so Plasma never lists it: pair it
# once by the address the installer copied from HarmonyOS (/etc/matepad/pen-mac)
I 644 $S/pen/matepad-pen-pair.py /usr/local/lib/matepad-pen/matepad-pen-pair.py
I 644 $S/pen/matepad-pen-pair.service $U/matepad-pen-pair.service
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
cat > /etc/systemd/user/matepad-hdmi-audio.service <<'EOF'
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
cat > /etc/xdg/autostart/matepad-fix-docked-rotation.desktop <<'EOF'
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
I 644 $S/power/matepad-chargeled-linux70.service $U/matepad-chargeled-linux70.service
# sleep: Sleep button suspends, power key and cover only turn the screen off
I 755 $S/sleep/matepad-suspend.sh /usr/local/sbin/matepad-suspend
I 644 $S/sleep/systemd-suspend-matepad.conf $U/systemd-suspend.service.d/matepad.conf
I 644 $S/sleep/50-matepad-power-key.conf /etc/systemd/logind.conf.d/50-matepad-power-key.conf
I 644 $S/sleep/50-matepad-sleep.rules /etc/polkit-1/rules.d/50-matepad-sleep.rules
install -d /etc/skel/.config
bash $S/sleep/matepad-powerdevil-profile.sh /etc/skel/.config/powermanagementprofilesrc
# desktop
I 755 $S/desktop/matepad-tray-relayout /usr/local/bin/matepad-tray-relayout
I 644 $S/desktop/matepad-tray-relayout.service $U/matepad-tray-relayout.service
I 755 $S/desktop/matepad-plasmashell-guard.sh /usr/local/bin/matepad-plasmashell-guard
I 644 $S/desktop/matepad-plasmashell-guard.desktop /etc/xdg/autostart/matepad-plasmashell-guard.desktop
I 755 $S/desktop/osk/matepad-osk-auto.py /usr/local/bin/matepad-osk-auto
I 644 $S/desktop/osk/matepad-osk-auto.desktop /etc/xdg/autostart/matepad-osk-auto.desktop
I 755 $S/desktop/osk/matepad-typing-watch /usr/local/sbin/matepad-typing-watch
I 644 $S/desktop/osk/matepad-typing-watch.service $U/matepad-typing-watch.service
printf '[Plugins]\nblurEnabled=false\n' > /etc/xdg/kwinrc     # popups: no outline before the slide
# the on-screen keyboard: KWin shows a virtual keyboard only with one set here
# (System Settings > Virtual Keyboard); matepad-osk-auto switches it on and off.
# Maliit 2.3 draws Qt Quick Controls keys: started by KWin it has no style set
# and stays light, so the launcher sets Plasma's (org.kde.desktop), which
# follows the colour scheme (dark keys with Breeze Dark). Its languages: the
# installer, from the keyboard layouts.
I 644 $S/desktop/osk/matepad-maliit-keyboard.desktop /usr/share/applications/matepad-maliit-keyboard.desktop
printf '[Wayland]
InputMethod=/usr/share/applications/matepad-maliit-keyboard.desktop
' >> /etc/xdg/kwinrc
cat > /usr/local/bin/kwin_wayland <<'EOF'
#!/bin/sh
# KWin's OpenGL compositor on the Adreno 650 (freedreno).
export KWIN_COMPOSE=O2
exec /usr/bin/kwin_wayland "$@"
EOF
chmod 755 /usr/local/bin/kwin_wayland
# Restart to HarmonyOS
I 755 $S/boot-switch/matepad-boot-harmonyos /usr/local/sbin/matepad-boot-harmonyos
I 755 $S/boot-switch/matepad-boot-harmonyos-gui /usr/local/bin/matepad-boot-harmonyos-gui
I 644 $S/boot-switch/boot-linux.sh /usr/local/share/matepad/boot-linux.sh
I 644 $S/boot-switch/org.matepad.boot-harmonyos.policy /usr/share/polkit-1/actions/org.matepad.boot-harmonyos.policy
I 644 $S/boot-switch/matepad-boot-harmonyos.desktop /usr/share/applications/matepad-boot-harmonyos.desktop
I 755 $S/boot-switch/matepad-boot-harmonyos.desktop /etc/skel/Desktop/matepad-boot-harmonyos.desktop
# first boot: derive the hardware data from the copied device files
I 755 $S/image/matepad-device-setup /usr/local/sbin/matepad-device-setup
I 644 $S/image/matepad-device-setup.service $U/matepad-device-setup.service

systemctl enable linux70-touch.service hexagonrpcd-sdsp.service matepad-sensord.service \
	matepad-tfa9874.service matepad-volkeys.service matepad-pen-bluez.service matepad-pen-pair.service \
	matepad-dp-recover.service matepad-chargeled-linux70.service matepad-tray-relayout.service \
	matepad-device-setup.service matepad-typing-watch.service bluetooth.service systemd-timesyncd.service \n	upower.service
systemctl --global enable filter-chain.service matepad-hdmi-audio.service

# ---- system identity, root file system, consoles, display manager
echo matepad > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tmatepad\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts
echo 'LABEL=LINUX70ROOT / ext4 defaults,noatime 0 1' > /etc/fstab
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/matepad.conf <<'EOF'
# Plasma (Wayland) as the default session; the greeter itself on KWin Wayland.
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell
[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
[Autologin]
Session=plasmawayland
EOF
# USB serial console (the PC's /dev/ttyACMx): a login prompt
mkdir -p $U/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service $U/getty.target.wants/serial-getty@ttyGS0.service

if [ -f /tmp/dev-key.pub ]; then	# development build only
	$APT install openssh-server
	install -d -m 700 /root/.ssh
	install -m 600 /tmp/dev-key.pub /root/.ssh/authorized_keys
	mkdir -p $U/serial-getty@ttyGS0.service.d
	printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %%I $TERM\n' \
		> $U/serial-getty@ttyGS0.service.d/autologin.conf
	echo "development build: SSH (key) and root on the USB serial console" > /etc/matepad-dev-build
fi

# ---- Kubuntu's first-boot setup (language, keyboard, time zone, user)
oem-config-prepare --quiet
# It boots into oem-config.target, which stops at basic.target: start the
# hardware services there too (touch for the setup itself, sensors, sound).
for s in linux70-touch hexagonrpcd-sdsp matepad-sensord matepad-tfa9874 matepad-volkeys \
	matepad-chargeled-linux70 matepad-dp-recover; do
	systemctl add-wants oem-config.target $s.service
done
# The setup runs on X (Plasma and SDDM use Wayland): landscape like KScreen
# sets for Plasma, the touchscreen turned with it, and readable at 2x.
install -d /etc/X11/xorg.conf.d $U/oem-config.service.d
cat > /etc/X11/xorg.conf.d/90-matepad.conf <<'EOF'
# The panel is portrait; the tablet is used in landscape.
Section "Monitor"
	Identifier "DSI-1"
	Option "Rotate" "right"
EndSection
Section "InputClass"
	Identifier "MatePad touchscreen"
	MatchIsTouchscreen "on"
	Option "CalibrationMatrix" "0 1 0 -1 0 1 0 0 1"
EndSection
EOF
printf '[Service]\nEnvironment=QT_SCALE_FACTOR=2 QT_AUTO_SCREEN_SCALE_FACTOR=0\n' > $U/oem-config.service.d/matepad.conf

# ---- clean up
rm -f /usr/sbin/policy-rc.d /etc/apt/apt.conf.d/80-matepad-build-retries
mountpoint -q /var/cache/apt/archives || apt-get clean	# build-image.sh's cache stays
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /tmp/* /var/tmp/* /root/.cache
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
