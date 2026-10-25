#!/usr/bin/python3
"""Recover an attached DP sink whose initial EDID read was lost.

The 7.0 MSM driver can keep a connected connector with no EDID until DP
Alt Mode is re-entered. Retry only that condition, at most three times,
with a 30-second cooldown. Never force a mode or substitute a saved EDID.
"""
import pathlib
import time

root = pathlib.Path("/sys/class")
misses = attempts = 0
cooldown = 0.0
while True:
    try:
        partners = list((root / "typec").glob("port*-partner/port*-partner.*/active"))
        dp = []
        for active in partners:
            if active.with_name("svid").read_text().strip().lower() in ("ff01", "0xff01"):
                dp.append(active)
        connected = [p for p in (root / "drm").glob("card*-DP-*")
                     if p.joinpath("status").read_text().strip() == "connected"]
        if not dp:
            misses = attempts = 0
        elif connected and any(not p.joinpath("edid").read_bytes() for p in connected):
            misses += 1
            if misses >= 5 and attempts < 3 and time.monotonic() >= cooldown:
                active = dp[0]
                if active.read_text().strip() in ("1", "yes"):
                    attempts += 1
                    cooldown = time.monotonic() + 30
                    print(f"Connected DP without EDID: re-entering Alt Mode ({attempts}/3)", flush=True)
                    active.write_text("0\n")
                    time.sleep(2)
                    if active.exists():
                        active.write_text("1\n")
                    misses = 0
        else:
            misses = 0
            # Retain the retry budget until physically detached.
    except OSError as exc:
        print(str(exc), flush=True)
    time.sleep(1)
