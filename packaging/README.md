# MatePad packages and apt repository

The MatePad support is installed and updated as Debian packages from this
repository's apt repository, so Kubuntu on the card updates in place (Discover,
`apt`, or **Update** in the installer app) without touching files, settings or
installed apps.

| Package | Contents |
| --- | --- |
| `matepad-dby-w09` | the hardware support: services, tools, udev rules, settings (`stage-matepad.sh`) |
| `linux-image-dby-w09` | the kernel ([linux-dby-w09](https://github.com/svesnav/linux-dby-w09) releases) |
| `matepad-hexagonrpc` | hexagonrpcd with the Huawei sensor patches |
| `libcamera-matepad` | libcamera with the software ISP and the MatePad sensors' gain models |
| `bluez`, `qtwayland` | Ubuntu's, rebuilt with `bluetooth/` and `desktop/qt/` patches (`+matepadN` versions, pinned) |

The repository is a flat apt repository in the assets of the release `apt`:

```
Types: deb
URIs: https://github.com/svesnav/kubuntu-dby-w09/releases/download/apt/
Suites: ./
Signed-By: /usr/share/keyrings/matepad-archive-keyring.asc
```

`matepad-dby-w09` ships that source (`apt/`), its key and a pin that keeps the
patched bluez and qtwayland ahead of Ubuntu's.

## Building

GitHub Actions, **packages** workflow (started by hand): `build-chroot.sh` runs
`build-packages.sh` in an arm64 Ubuntu 24.04 root kept on the runner, then
`publish-repo.sh` signs and uploads the repository. A package's version counts
the commits of its own sources (`versions.sh`), so unchanged packages are not
rebuilt; bluez, qtwayland and libcamera take long under emulation.

The signing key is created once with `new-signing-key.sh`: the private key goes
into the repository secret `APT_SIGNING_KEY`, the public key into
`apt/matepad-archive-keyring.asc`.

## Installs from before the packages

The first update (installer app) adds the repository, releases the old holds
on bluez and the Qt Wayland client and removes the old library diversion
(`migrate-manual-install.sh` does the same for a resumed image build), then
installs `matepad-dby-w09` over the hand-installed files.
