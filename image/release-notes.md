Stock Kubuntu 24.04 LTS for the Huawei MatePad 11 (DBY-W09) on mainline Linux 7.0.

**Install** with the MatePad installer app on HarmonyOS (root required). It
downloads these files, writes the image to the whole microSD card, copies the
tablet's own firmware and vendor files into it, and sets up the boot
partitions from the tablet's stock ones. The first boot opens Kubuntu's setup
(language, keyboard, time zone, user account).

The image contains no Huawei files. A large image is split into `.partNN`
files; concatenated, they form the `.img.xz`.
