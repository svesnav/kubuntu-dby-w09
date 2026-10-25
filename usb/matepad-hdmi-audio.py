#!/usr/bin/python3
"""Linux 7.0 DP audio: independent PCM, visible only for an audio monitor."""
import glob
import json
import pathlib
import re
import signal
import subprocess
import time

NAME = "matepad_hdmi"


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=5)


def has_audio(edid):
    # CTA basic audio guarantees stereo LPCM 16-bit, 32/44.1/48 kHz.
    if (len(edid) < 128 or edid[:8] != bytes.fromhex("00ffffffffffff00")
            or sum(edid[:128]) % 256):
        return False
    for n in range(1, min(edid[126] + 1, len(edid) // 128)):
        block = edid[n * 128:(n + 1) * 128]
        if sum(block) % 256 or block[0] != 2:
            continue
        if block[3] & 0x40:
            return True
        end = block[2]
        if not 4 <= end <= 127:
            continue
        pos = 4
        while pos < end:
            tag, length = block[pos] >> 5, block[pos] & 31
            pos += 1
            if pos + length > end:
                break
            if tag == 1:
                for i in range(pos, pos + length - 2, 3):
                    if (block[i] >> 3 == 1 and block[i] & 7 >= 1
                            and block[i + 1] & 4 and block[i + 2] & 1):
                        return True
            pos += length
    return False


def monitor_ready():
    for name in glob.glob("/sys/class/drm/card*-DP-*"):
        path = pathlib.Path(name)
        try:
            if (path.joinpath("status").read_text().strip() == "connected"
                    and has_audio(path.joinpath("edid").read_bytes())):
                return True
        except OSError:
            pass
    return False


def pcm():
    # Do not assume card or PCM enumeration; MultiMedia2 belongs to mics.
    for line in pathlib.Path("/proc/asound/pcm").read_text().splitlines():
        match = re.match(r"(\d+)-(\d+): MultiMedia3(?:\s|:)", line)
        if match and "playback 1" in line:
            card, device = map(int, match.groups())
            card_id = pathlib.Path(f"/proc/asound/card{card}/id").read_text().strip()
            if card_id == "HuaweiMatePad11":
                return card_id, device
    return None


def nodes():
    result = run("pw-dump")
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return [obj["id"] for obj in json.loads(result.stdout)
            if obj.get("info", {}).get("props", {}).get("node.name") == NAME]


def reconcile():
    existing = nodes()
    target = pcm() if monitor_ready() else None
    if target and not existing:
        card, device = target
        route = run("amixer", "-q", "-c", card, "cset",
                    "name=DISPLAY_PORT_RX Audio Mixer MultiMedia3", "1")
        if route.returncode:
            raise RuntimeError(route.stderr.strip())
        props = {
            "factory.name": "api.alsa.pcm.sink", "node.name": NAME,
            "node.description": "HDMI / DisplayPort (USB-C)",
            "media.class": "Audio/Sink", "api.alsa.path": f"hw:{card},{device}",
            "audio.channels": 2, "audio.position": ["FL", "FR"],
            "audio.format": "S16LE", "audio.rate": 48000,
            "priority.session": 50, "priority.driver": 50,
            "device.icon-name": "video-display", "api.alsa.headroom": 2048,
            "node.pause-on-idle": False, "object.linger": True,
        }
        result = run("pw-cli", "create-node", "adapter", json.dumps(props))
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        # pw-cli may exit successfully even when SPA rejects the PCM.
        time.sleep(0.1)
        if not nodes():
            raise RuntimeError("HDMI node did not appear; check PipeWire/ALSA journal")
        print("Audio monitor connected: HDMI sink created", flush=True)
    elif not target and existing:
        for node in existing:
            run("pw-cli", "destroy", str(node))
        print("Audio monitor disconnected: HDMI sink removed", flush=True)


def main():
    def stop(*_):
        raise SystemExit()
    signal.signal(signal.SIGTERM, stop)
    last_error = None
    try:
        while True:
            try:
                reconcile()
                last_error = None
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
                if str(exc) != last_error:
                    print(str(exc), flush=True)
                    last_error = str(exc)
            time.sleep(2)
    finally:
        try:
            for node in nodes():
                run("pw-cli", "destroy", str(node))
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
            pass


if __name__ == "__main__":
    main()
