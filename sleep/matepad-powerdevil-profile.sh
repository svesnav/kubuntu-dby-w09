#!/bin/sh
# Android-like screen handling in a PowerDevil 5.27 profile file
# (~ubuntu/.config/powermanagementprofilesrc), all three profiles:
#   - power key: "Turn off screen" (64): the panel and any monitor go off.
#     While KWin has the outputs off it eats the next key press and turns
#     them on, so the key toggles. The cover sends the same key press when it
#     closes (matepad-volkeys). No suspend-to-RAM here: that is only Plasma's
#     Sleep button.
#   - screen off after 10 min on AC, 5 min on battery, 2 min on low battery
#     (DPMSControl idleTime is in seconds; DimDisplay before it stays).
#   - no SuspendSession section is added: never suspend when idle (an
#     existing one, set by the user in System Settings, is left alone).
# Usage: matepad-powerdevil-profile.sh <file>  (kwriteconfig5 is in the image)
F=$1
for p in AC Battery LowBattery; do
	kwriteconfig5 --file "$F" --group $p --group HandleButtonEvents --key powerButtonAction 64
	kwriteconfig5 --file "$F" --group $p --group DPMSControl --key lockBeforeTurnOff 0
done
kwriteconfig5 --file "$F" --group AC --group DPMSControl --key idleTime 600
kwriteconfig5 --file "$F" --group Battery --group DPMSControl --key idleTime 300
kwriteconfig5 --file "$F" --group LowBattery --group DPMSControl --key idleTime 120
