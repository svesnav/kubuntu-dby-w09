#!/usr/bin/env python3
"""Add the sns_registry reverse-RPC interface (sns_registry.c) to hexagonrpcd.

Without it the Huawei SLPI sensors PD logs "Could not find local interface
sns_registry" and aborts with SNS_REG_INIT ... sns_registry_sensor.c:94.
Usage: hexagonrpcd-sns-registry.py hexagonrpc/hexagonrpcd sns_registry.c
"""
import shutil
import sys
from pathlib import Path

d = Path(sys.argv[1])
shutil.copyfile(sys.argv[2], d / "sns_registry.c")


def patch(name, pairs):
    f = d / name
    t = f.read_text()
    if "sns_registry" in t:
        print("already patched", f)
        return
    for old, new in pairs:
        if old not in t:
            sys.exit(f"{name}: anchor not found: {old[:60]!r}")
        t = t.replace(old, new, 1)
    f.write_bytes(t.encode())
    print("patched", f)


patch("meson.build", [("  'rpcd_builder.c',\n",
                       "  'rpcd_builder.c',\n  'sns_registry.c',\n")])
patch("rpcd.c", [
    ('#include "rpcd_builder.h"\n',
     '#include "rpcd_builder.h"\n\n'
     "struct fastrpc_interface *fastrpc_sns_registry_init(void);\n"),
    ("\tsize_t n_ifaces = 3;\n", "\tsize_t n_ifaces = 4;\n"),
    ("\tifaces[2] = fastrpc_apps_mem_init(fd);\n",
     "\tifaces[2] = fastrpc_apps_mem_init(fd);\n"
     "\tifaces[3] = fastrpc_sns_registry_init();\n"),
])
