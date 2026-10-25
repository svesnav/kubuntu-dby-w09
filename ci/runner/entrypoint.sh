#!/bin/bash
# Registers an ephemeral runner for $REPO, runs one job, exits; Docker's
# restart policy brings up a fresh one. The registration token comes from
# GITHUB_PAT (fine-grained: Administration read/write on the repositories).
set -euo pipefail
: "${GITHUB_PAT:?set GITHUB_PAT in .env}" "${REPO:?}"
LABELS=${RUNNER_LABELS:-matepad-builder}
NAME=${RUNNER_NAME:-$(hostname)}-${REPO#*/}

# arm64 chroots on an x86-64 host: qemu through binfmt_misc (host-wide).
if [ "$(uname -m)" = x86_64 ]; then
	mountpoint -q /proc/sys/fs/binfmt_misc || sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
	# qemu-user-static's systemd entry (flags OPF: F keeps it usable in chroots)
	[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ||
		sudo sh -c 'grep -v "^#" /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register'
fi

token=$(curl -fsS -X POST \
	-H "Authorization: Bearer $GITHUB_PAT" -H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/$REPO/actions/runners/registration-token" | jq -r .token) ||
	{ echo "GitHub refused GITHUB_PAT for $REPO (needs Administration: Read and write)" >&2; sleep 60; exit 1; }

cd /home/runner
rm -f .runner .credentials .credentials_rsaparams
mkdir -p _work && sudo find _work -mindepth 1 -maxdepth 1 -exec rm -rf {} +	# a clean job each time
./config.sh --unattended --ephemeral --replace \
	--url "https://github.com/$REPO" --token "$token" \
	--name "$NAME" --labels "$LABELS" --work _work
exec ./run.sh
