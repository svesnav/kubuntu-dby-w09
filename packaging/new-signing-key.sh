#!/bin/bash
# Creates the apt repository's signing key (once). The private key goes
# straight into the repository secret APT_SIGNING_KEY (gh, logged in) and is
# not kept or shown; the public key is written to
# packaging/apt/matepad-archive-keyring.asc, to commit.
# usage (from the repository): bash packaging/new-signing-key.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --passphrase '' --quick-gen-key "MatePad DBY-W09 apt repository" ed25519 sign never
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
gpg --armor --export-secret-keys "$FPR" | gh secret set APT_SIGNING_KEY -R svesnav/kubuntu-dby-w09
mkdir -p packaging/apt
gpg --armor --export "$FPR" > packaging/apt/matepad-archive-keyring.asc
echo "signing key $FPR: secret APT_SIGNING_KEY set, public key in packaging/apt/matepad-archive-keyring.asc"
