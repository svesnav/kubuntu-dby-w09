#!/usr/bin/python3
"""Allow the internal panel to auto-rotate with an external keyboard/dock."""
import json
import pathlib
import shutil

root = pathlib.Path.home() / ".local/share/kscreen/control"
for folder in ("outputs", "configs"):
    for path in (root / folder).glob("*"):
        if not path.is_file() or path.name.endswith(".pre-docked-rotation"):
            continue
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        entries = data.get("outputs", []) if folder == "configs" else [data]
        changed = False
        for entry in entries:
            if entry.get("metadata", {}).get("name") == "DSI-1":
                if entry.get("autorotate-tablet-only") is not False:
                    entry["autorotate-tablet-only"] = False
                    changed = True
        if changed:
            backup = path.with_name(path.name + ".pre-docked-rotation")
            if not backup.exists():
                shutil.copy2(path, backup)
            path.write_text(json.dumps(data) + "\n")
            print(path)
