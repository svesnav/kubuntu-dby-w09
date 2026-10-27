#!/bin/sh
# Package versions from the git history: each counts the commits of its own
# sources, so a package keeps its version (and is not rebuilt) until they change.
cd "$(dirname "$0")/.."
c() { git rev-list --count HEAD -- "$@"; }
cat <<END
MATEPAD_VERSION=1.$(git rev-list --count HEAD)
HEXAGONRPC_VERSION=0.1+matepad$(c sensors/hexagonrpcd-odm.py sensors/hexagonrpcd-sns-registry.py sensors/sns_registry.c)
LIBCAMERA_UPSTREAM=0.7.2
LIBCAMERA_VERSION=0.7.2+matepad$(c camera/libcamera-sensor-helpers.py)
BLUEZ_REV=$(c bluetooth/hog-ccc-read-error.patch)
QTWAYLAND_REV=$(c desktop/qt/qtwayland-shm-scale-change.patch)
END
