#!/usr/bin/env python3
"""Add /odm/etc/sensors/config to hexagonrpcd's served tree (Huawei SLPI).

Huawei's sensors PD reads its sensor JSON from /odm/etc/sensors/config (on
4.19 the SLPI aborted with SNS_REG_INIT ... sns_registry_sensor.c:94 without
it); stock hexagonrpcd only serves /vendor/etc/sensors/config.  Served from
<root>/odm/sensors/config.  Usage: hexagonrpcd-odm.py hexagonrpc/hexagonrpcd
"""
import sys
from pathlib import Path

src = Path(sys.argv[1]) / "rpcd_builder.c"
t = src.read_text()
if "ODM_SENSORS_CONFIG" in t:
    sys.exit("already patched")


def rep(old, new):
    global t
    if old not in t:
        sys.exit(f"anchor not found: {old[:60]!r}")
    t = t.replace(old, new, 1)


rep('#define SYSFS_SOCINFO\t\t"/socinfo/"\n',
    '#define SYSFS_SOCINFO\t\t"/socinfo/"\n#define ODM_SENSORS_CONFIG\t"/odm/sensors/config/"\n')
rep("char *acdbdata, *dsp_libs, *sns_cfg, *sns_reg, *sns_reg_config, *socinfo;",
    "char *acdbdata, *dsp_libs, *sns_cfg, *sns_reg, *sns_reg_config, *socinfo, *odm_cfg;")
rep("\tsocinfo = malloc(n_prefix + strlen(SYSFS_SOCINFO) + 1);\n",
    "\tsocinfo = malloc(n_prefix + strlen(SYSFS_SOCINFO) + 1);\n"
    "\todm_cfg = malloc(n_prefix + strlen(ODM_SENSORS_CONFIG) + 1);\n"
    "\tif (odm_cfg != NULL) {\n\t\tstrcpy(odm_cfg, prefix);\n\t\tstrcat(odm_cfg, ODM_SENSORS_CONFIG);\n\t}\n")
rep('\treturn hfs_mkdir("/", 6,\n',
    '\treturn hfs_mkdir("/", 7,\n'
    '\t\t\thfs_mkdir("odm", 1,\n'
    '\t\t\t\thfs_mkdir("etc", 1,\n'
    '\t\t\t\t\thfs_mkdir("sensors", 1,\n'
    '\t\t\t\t\t\thfs_map_or_empty("config", odm_cfg)\n'
    '\t\t\t\t\t)\n'
    '\t\t\t\t)\n'
    '\t\t\t),\n')
src.write_text(t)
print("patched", src)
