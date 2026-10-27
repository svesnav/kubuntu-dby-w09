#!/bin/bash
# Publishes the MatePad apt repository: a flat repository (Packages, signed
# Release/InRelease and the .debs side by side) as the assets of this
# repository's release "apt":
#   deb https://github.com/svesnav/kubuntu-dby-w09/releases/download/apt/ ./
# It keeps the newest version of each package: those already published, the
# new ones in NEW, and the latest kernel package of KERNEL_REPO.
# env: GH_TOKEN, GH_REPO (this repository), KERNEL_REPO, APT_SIGNING_KEY
# (ASCII-armoured private key, packaging/new-signing-key.sh)
# usage: publish-repo.sh NEW
set -euo pipefail
NEW=$(realpath "$1")
: "${APT_SIGNING_KEY:?no signing key (repository secret APT_SIGNING_KEY)}"
R=$(mktemp -d)
cd "$R"
if gh release view apt >/dev/null 2>&1; then
	gh release download apt -p '*.deb'
else
	gh release create apt --prerelease --title "apt repository" \
		--notes "The MatePad apt repository (packaging/). Kubuntu on the tablet uses it as
\`deb https://github.com/$GH_REPO/releases/download/apt/ ./\`; not an image release."
fi
cp "$NEW"/*.deb . 2>/dev/null || true
gh release download -R "$KERNEL_REPO" -p 'linux-image-dby-w09_*_arm64.deb' --clobber

# the newest version of each package
python3 - <<'EOF'
import glob, os, subprocess
newest = {}
for f in glob.glob("*.deb"):
    pkg, ver = subprocess.run(["dpkg-deb", "-f", f, "Package", "Version"], capture_output=True,
                              text=True, check=True).stdout.split("\n")[:2]
    pkg, ver = pkg.split(": ", 1)[1], ver.split(": ", 1)[1]
    old = newest.get(pkg)
    if old is None or subprocess.run(["dpkg", "--compare-versions", ver, "gt", old[0]]).returncode == 0:
        if old:
            os.remove(old[1])
        newest[pkg] = (ver, f)
    else:
        os.remove(f)
for pkg, (ver, f) in sorted(newest.items()):
    print(f"{pkg} {ver}")
EOF

apt-ftparchive packages . > Packages
gzip -9kf Packages
apt-ftparchive -o APT::FTPArchive::Release::Origin="MatePad DBY-W09" \
	-o APT::FTPArchive::Release::Label="MatePad DBY-W09" -o APT::FTPArchive::Release::Suite=stable \
	-o APT::FTPArchive::Release::Codename=noble -o APT::FTPArchive::Release::Architectures=arm64 \
	-o APT::FTPArchive::Release::Description="Huawei MatePad 11 (DBY-W09) support for Kubuntu 24.04" \
	release . > Release
export GNUPGHOME=$(mktemp -d)
printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --quiet --import
gpg --batch --yes --clearsign -o InRelease Release
gpg --batch --yes -abs -o Release.gpg Release
rm -rf "$GNUPGHOME"

gh release upload apt --clobber ./*.deb Packages Packages.gz Release InRelease Release.gpg
gh release view apt --json assets -q '.assets[].name' | while read -r a; do
	[ -e "$a" ] || gh release delete-asset apt "$a" -y
done
echo "published: $(grep -c '^Package:' Packages) packages"
