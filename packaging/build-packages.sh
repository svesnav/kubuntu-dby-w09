#!/bin/bash
# Builds the MatePad apt repository's packages in an arm64 Ubuntu 24.04 root
# (packaging/build-chroot.sh runs it there):
#   matepad-dby-w09     the hardware support (packaging/stage-matepad.sh)
#   matepad-hexagonrpc  hexagonrpcd with the Huawei sensor patches
#   libcamera-matepad   libcamera with the MatePad sensors' gain models
#   bluez               Ubuntu's, with the HOG CCC-read fix
#   qtwayland           Ubuntu's, with the buffer-scale fix
# A package whose version is already in PUBLISHED (the repository's Packages
# index) is skipped: the versions follow their own sources (VERSIONS env file,
# from packaging/versions.sh), so bluez, qtwayland and libcamera, slow under
# emulation, only rebuild when they change.
# usage: build-packages.sh SRC OUT [PUBLISHED]
set -euo pipefail
S=$(cd "$1" && pwd)
OUT=$2
PUB=${3:-/dev/null}
. "$S/packaging/versions.env"
export DEBIAN_FRONTEND=noninteractive DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
APT="apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
mkdir -p "$OUT"
W=/tmp/matepad-packages
rm -rf $W && mkdir -p $W

published() {   # published PACKAGE VERSION
	awk -v p="$1" -v v="$2" '/^Package: /{pk=$2} /^Version: /{if (pk == p && $2 == v) f=1} END{exit !f}' "$PUB"
}

shlibs() {      # shlibs ROOT FILE...: the Depends of these binaries
	local root=$1; shift
	mkdir -p $W/shl/debian
	printf 'Source: x\n\nPackage: x\nArchitecture: any\n' > $W/shl/debian/control
	(cd $W/shl && dpkg-shlibdeps -O -l"$root/usr/local/lib" -l"$root/usr/local/lib/aarch64-linux-gnu" \
		--ignore-missing-info "$@" 2>/dev/null) | sed -n 's/^shlibs:Depends=//p'
}

debian_pkg() {  # debian_pkg ROOT NAME VERSION: DEBIAN/control from the given fields file
	local root=$1 name=$2 version=$3
	sed -e "s/@VERSION@/$version/" -e "s/@SIZE@/$(du -sk --exclude=DEBIAN "$root" | cut -f1)/" \
		-e "s/@SHLIBS@/${SHL:-libc6}/" > "$root/DEBIAN/control"
	dpkg-deb --root-owner-group -Zxz --build "$root" "$OUT/${name}_${version}_arm64.deb" >/dev/null
	echo "built $name $version"
}

$APT update
$APT install build-essential devscripts fakeroot dpkg-dev equivs libsystemd-dev meson ninja-build git \
	libkf5config-bin python3 python3-yaml python3-ply python3-jinja2 pkg-config

# ---- matepad-dby-w09
if ! published matepad-dby-w09 "$MATEPAD_VERSION"; then
	R=$W/matepad/root
	bash "$S/packaging/stage-matepad.sh" "$S" $R
	echo "$MATEPAD_VERSION" > $R/usr/share/matepad/version
	install -d $R/DEBIAN
	install -m 755 "$S"/packaging/matepad-dby-w09/{preinst,postinst,prerm,postrm} $R/DEBIAN/
	(cd $R && find etc -type f | sort | sed 's|^|/|') > $R/DEBIAN/conffiles
	SHL=$(shlibs $R $R/usr/local/sbin/matepad-sensord $R/usr/local/sbin/matepad-volkeys \
		$R/usr/local/sbin/matepad-tfa9874 $R/usr/local/lib/linux70-touch/binderfs-add)
	debian_pkg $R matepad-dby-w09 "$MATEPAD_VERSION" < "$S/packaging/matepad-dby-w09/control"
fi

# ---- matepad-hexagonrpc: hexagonrpcd with the Huawei patches (sensors/hexagonrpcd-*.py)
if ! published matepad-hexagonrpc "$HEXAGONRPC_VERSION"; then
	git clone -q https://github.com/linux-msm/hexagonrpc.git $W/hexagonrpc
	R=$W/hexagonrpc-root
	(cd $W/hexagonrpc && git checkout -q da7a3742ab8d5273a281b70ee11f16fb2cb6a690 &&
		python3 "$S/sensors/hexagonrpcd-odm.py" hexagonrpcd &&
		python3 "$S/sensors/hexagonrpcd-sns-registry.py" hexagonrpcd "$S/sensors/sns_registry.c" &&
		meson setup build --prefix=/usr/local >/dev/null && ninja -C build >/dev/null &&
		DESTDIR=$R ninja -C build install >/dev/null)
	install -d $R/DEBIAN
	echo "activate-noawait ldconfig" > $R/DEBIAN/triggers
	SHL=$(shlibs $R $(find $R/usr/local/bin $R/usr/local/sbin -type f 2>/dev/null))
	debian_pkg $R matepad-hexagonrpc "$HEXAGONRPC_VERSION" <<'EOF'
Package: matepad-hexagonrpc
Version: @VERSION@
Architecture: arm64
Maintainer: kubuntu-dby-w09 <https://github.com/svesnav/kubuntu-dby-w09>
Installed-Size: @SIZE@
Depends: @SHLIBS@
Section: misc
Priority: optional
Description: hexagonrpcd for the MatePad 11 sensors (SLPI)
 linux-msm's hexagonrpc with the Huawei sensor configuration paths and a
 stand-in sns_registry interface, serving the MatePad 11's sensor DSP.
EOF
fi

# ---- libcamera-matepad: libcamera with the software ISP, Python bindings and
#      the gain models for the OV13B10 and Hi-846 (camera/libcamera-sensor-helpers.py)
if ! published libcamera-matepad "$LIBCAMERA_VERSION"; then
	$APT install libyaml-dev libgnutls28-dev libudev-dev libevent-dev libdw-dev libdrm-dev libjpeg-dev \
		libtiff-dev libepoxy-dev libegl-dev libgles-dev pybind11-dev python3-dev openssl
	git clone -q --depth 1 --branch "v$LIBCAMERA_UPSTREAM" https://git.libcamera.org/libcamera/libcamera.git $W/libcamera
	R=$W/libcamera-root
	(cd $W/libcamera && python3 "$S/camera/libcamera-sensor-helpers.py" src/ipa/libipa/camera_sensor_helper.cpp &&
		meson setup build --prefix=/usr/local --buildtype=release -Dpipelines=simple -Dipas=simple \
			-Dcam=enabled -Dqcam=disabled -Dgstreamer=disabled -Dv4l2=false -Ddocumentation=disabled \
			-Dtest=false -Dlc-compliance=disabled -Dpycamera=enabled >/dev/null &&
		ninja -C build >/dev/null && DESTDIR=$R ninja -C build install >/dev/null)
	install -d $R/DEBIAN
	echo "activate-noawait ldconfig" > $R/DEBIAN/triggers
	SHL=$(shlibs $R $R/usr/local/bin/cam $(find $R/usr/local/lib -name '*.so*' -type f))
	debian_pkg $R libcamera-matepad "$LIBCAMERA_VERSION" <<'EOF'
Package: libcamera-matepad
Version: @VERSION@
Architecture: arm64
Maintainer: kubuntu-dby-w09 <https://github.com/svesnav/kubuntu-dby-w09>
Installed-Size: @SIZE@
Depends: @SHLIBS@, python3
Section: libs
Priority: optional
Description: libcamera for the MatePad 11 cameras (in /usr/local)
 libcamera with the software ISP (GPU debayer), the cam tool, Python
 bindings and gain models for the OV13B10 and Hi-846. Ubuntu 24.04's
 libcamera has no software ISP.
EOF
fi

# ---- Ubuntu packages rebuilt with a patch: source package, patch, version suffix
rebuild() {     # rebuild SOURCE PATCH REV
	local src=$1 patch=$2 rev=$3 ubv
	ubv=$(apt-cache showsrc "$src" | sed -n 's/^Version: //p' | sort -V | tail -1)
	local v="${ubv}+matepad$rev"
	local probe=$4
	if published "$probe" "$v"; then
		return 0
	fi
	(cd $W && apt-get source -q "$src" >/dev/null && $APT build-dep "$src" >/dev/null &&
		cd "$(ls -d "$src"-[0-9]*/ | head -1)" && mkdir -p debian/patches &&
		cp "$patch" debian/patches/matepad.patch && echo matepad.patch >> debian/patches/series &&
		DEBFULLNAME=kubuntu-dby-w09 DEBEMAIL=nobody@invalid dch -v "$v" -D noble "MatePad 11: $(basename "$patch")" &&
		dpkg-buildpackage -us -uc -b >/dev/null)
	find $W -maxdepth 1 -name '*.deb' ! -name '*-dbgsym_*' -exec mv {} "$OUT/" \;
	echo "built $src $v"
}
rebuild bluez "$S/bluetooth/hog-ccc-read-error.patch" "$BLUEZ_REV" bluez
rebuild qtwayland-opensource-src "$S/desktop/qt/qtwayland-shm-scale-change.patch" "$QTWAYLAND_REV" libqt5waylandclient5
ls -la "$OUT"
