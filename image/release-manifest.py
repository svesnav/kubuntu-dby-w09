#!/usr/bin/env python3
"""Release files for one image build, as the installer app reads them.

    release-manifest.py OUT NAME LINUX_BOOT_TAR

GitHub release assets stop at 2 GiB, so NAME.img.xz larger than PART_SIZE is
split into NAME.img.xz.part00, part01, ... (concatenated, they are the xz
file again). NAME.json lists them:

    {"name": ..., "image": "NAME.img.xz", "image_sha256": <of the whole .xz>,
     "image_compressed_size": ..., "image_size": <uncompressed ext4 bytes>,
     "parts": [...], "linux_boot": "linux-boot-<release>.tar",
     "linux_boot_sha256": ..., "kernel": "<release>"}
"""
import hashlib
import json
import os
import struct
import sys
import tarfile
from pathlib import Path

PART_SIZE = 1900 * 1024 * 1024


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    out, name, boot = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    image = out / f"{name}.img.xz"
    size_file = out / f"{name}.img.size"
    image_size = int(size_file.read_text()) if size_file.exists() else None
    with tarfile.open(boot) as t:
        member = next(m for m in t.getmembers() if m.name.endswith("/release.txt"))
        kernel = t.extractfile(member).read().decode().strip()
    manifest = {
        "name": name,
        "image": image.name,
        "image_sha256": sha256(image),
        "image_compressed_size": image.stat().st_size,
        "image_size": image_size,
        "linux_boot": boot.name,
        "linux_boot_sha256": sha256(boot),
        "kernel": kernel,
    }
    if image.stat().st_size > PART_SIZE:
        parts = []
        with image.open("rb") as f:
            for i in range(1000):
                data = f.read(PART_SIZE)
                if not data:
                    break
                part = out / f"{image.name}.part{i:02d}"
                part.write_bytes(data)
                parts.append(part.name)
        image.unlink()
        manifest["parts"] = parts
    else:
        manifest["parts"] = [image.name]
    (out / f"{name}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
