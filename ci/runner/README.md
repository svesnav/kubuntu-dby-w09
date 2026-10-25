# Self-hosted CI runners

Docker Compose setup that runs the kernel build (linux-dby-w09) and the image
build (kubuntu-dby-w09) on your own Linux machine instead of GitHub's 4-core
runners. The installer app keeps building on GitHub's runners, which carry
the Android SDK.

## Host requirements

- Linux with Docker Engine and the Compose plugin, x86-64 or arm64
- 4 GB RAM per parallel job (more cores = faster kernel builds)
- about 60 GB free disk: kernel tree and build ~15 GB, image tree,
  uncompressed image and package cache ~35 GB
- on x86-64 the image build runs arm64 code through qemu; the runner
  registers it in the host's `binfmt_misc` at start

## Setup

1. Create a fine-grained personal access token on GitHub: repositories
   `linux-dby-w09` and `kubuntu-dby-w09`, permission **Administration: Read
   and write** (used only to fetch runner registration tokens).
2. On the server:

   ```bash
   cd ci/runner
   cp .env.example .env    # put the token in GITHUB_PAT
   docker compose up -d --build
   ```

3. Check the runners in each repository: **Settings › Actions › Runners**
   should list `home-server-linux-dby-w09` and `home-server-kubuntu-dby-w09`
   as idle.
4. Point the workflows at them with a repository variable in both repositories:

   ```bash
   gh variable set RUNNER -b matepad-builder -R svesnav/linux-dby-w09
   gh variable set RUNNER -b matepad-builder -R svesnav/kubuntu-dby-w09
   ```

   Without the variable the workflows use GitHub's runners again.

## How it works

- `Dockerfile`: Ubuntu 24.04 with the Actions runner, the cross compiler,
  kernel build tools, debootstrap, qemu, xz and the `gh` CLI.
- `entrypoint.sh`: fetches a registration token, registers an **ephemeral**
  runner (one job, then it unregisters), runs it. Docker restarts the
  container, which registers a fresh runner with an empty work directory.
- `docker-compose.yml`: one service per repository (personal accounts have no
  shared runners). The containers are privileged because the image build
  mounts `proc`, `sys` and `dev` inside its chroot.
- Caches kept in volumes between builds: `kernel-cache` holds ccache (10 GB)
  and a local copy of the Linux git history, so a kernel build only compiles
  what changed and clones without the network; `image-build` keeps the
  downloaded Ubuntu packages.

## Security

The runners execute workflow code with root rights on the server. Keep them
on private repositories, or, once a repository is public, only for pushes,
tags and manual runs: the kernel workflow already sends pull requests to
GitHub's runners.

## Maintenance

```bash
docker compose logs -f image        # what the image runner is doing
docker compose down                 # stop both runners
docker compose build --pull && docker compose up -d   # update the base system
```

To move to a newer runner version, change `RUNNER_VERSION` in the Dockerfile
and the image tag in `docker-compose.yml`, then rebuild.
