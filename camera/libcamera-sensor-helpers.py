"""libcamera: gain models (camera sensor helpers) for the MatePad 11 sensors.

Without them the software ISP's auto-exposure cannot use analogue gain and
the picture stays dark indoors.
  OV13B10 (rear):  gain = code / 128 (driver range 128..1984, 1x..15.5x),
                   black level 64 at 10 bits
  Hi-846 (front):  gain = 1 + code / 16 (driver range 0..240, 1x..16x),
                   black level 64 at 10 bits
"""
import sys

path = sys.argv[1]
text = open(path).read()
anchor = 'REGISTER_CAMERA_SENSOR_HELPER("ov8858", CameraSensorHelperOv8858)\n'
add = '''
class CameraSensorHelperOv13b10 : public CameraSensorHelper
{
public:
	CameraSensorHelperOv13b10()
	{
		blackLevel_ = 4096;
		gain_ = AnalogueGainLinear{ 1, 0, 0, 128 };
	}
};
REGISTER_CAMERA_SENSOR_HELPER("ov13b10", CameraSensorHelperOv13b10)

class CameraSensorHelperHi846 : public CameraSensorHelper
{
public:
	CameraSensorHelperHi846()
	{
		blackLevel_ = 4096;
		gain_ = AnalogueGainLinear{ 1, 16, 0, 16 };
	}
};
REGISTER_CAMERA_SENSOR_HELPER("hi846", CameraSensorHelperHi846)
'''
if "CameraSensorHelperOv13b10" not in text:
    if text.count(anchor) != 1:
        sys.exit("anchor not found")
    text = text.replace(anchor, anchor + add)
    open(path, "w").write(text)
print("helpers in place")
