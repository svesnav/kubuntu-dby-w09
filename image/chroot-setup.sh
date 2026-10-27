#!/bin/bash
# Runs inside the arm64 target (called by build-image.sh): stock Kubuntu 24.04
# plus the MatePad 11 hardware support from this repo. No Huawei files: those
# come from the tablet at install time (device-files/, image/device-setup).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
S=/tmp/matepad-src
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
U=/etc/systemd/system
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
	maliit-keyboard ddcutil ddcui upower i2c-tools \
	python3-pyqt6 python3-numpy libyaml-0-2 libdw1t64 libevent-2.1-7t64 libepoxy0 libtiff6

# ---- the MatePad packages (packaging/) come from the MatePad apt repository;
#      updates too (apt, Discover, or the installer app's Update)
install -D -m 644 $S/packaging/apt/matepad.sources /etc/apt/sources.list.d/matepad.sources
install -D -m 644 $S/packaging/apt/matepad.pref /etc/apt/preferences.d/matepad
install -D -m 644 $S/packaging/apt/matepad-archive-keyring.asc /usr/share/keyrings/matepad-archive-keyring.asc
apt-get update

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

# ---- the hardware support: services, tools, settings (packaging/stage-matepad.sh),
#      with the rebuilt bluez and qtwayland, libcamera and hexagonrpcd
sh $S/packaging/migrate-manual-install.sh	# a resumed build tree from before the packages
$APT install matepad-dby-w09
systemctl enable bluetooth.service systemd-timesyncd.service upower.service

# ---- system identity, root file system, consoles, display manager
echo matepad > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tmatepad\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts
echo 'LABEL=LINUX70ROOT / ext4 defaults,noatime 0 1' > /etc/fstab

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
