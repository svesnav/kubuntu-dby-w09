#!/usr/bin/python3
"""Drive the stock RGB indicator from the real Linux 7.0 battery status."""
from pathlib import Path
import signal
import time

LEDS = Path("/sys/class/leds")
BATTERY = Path("/sys/class/power_supply/battery")
running = True


def stop(_signal, _frame):
    global running
    running = False


def apply(red, green):
    for color, value in (("red", red), ("green", green), ("blue", 0)):
        led = LEDS / color
        led.joinpath("trigger").write_text("none\n")
        led.joinpath("brightness").write_text(f"{value}\n")


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
last = None
try:
    while running:
        try:
            status = BATTERY.joinpath("status").read_text().strip()
            capacity = int(BATTERY.joinpath("capacity").read_text())
            present = BATTERY.joinpath("present").read_text().strip() == "1"
            online = Path("/sys/class/power_supply/matepad-charger/online").read_text().strip() == "1"
            if not present or not online:
                state = (0, 0)
            elif status == "Full" or capacity == 100:
                state = (0, 120)
            elif status == "Charging":
                state = (70, 0)
            else:
                state = (0, 0)
        except (OSError, ValueError):
            state = (0, 0)
        if state != last:
            try:
                apply(*state)
                print(f"Charging LED red={state[0]} green={state[1]}", flush=True)
                last = state
            except OSError as error:
                print(f"LED unavailable: {error}", flush=True)
        time.sleep(0.5)
finally:
    try:
        apply(0, 0)
    except OSError:
        pass
