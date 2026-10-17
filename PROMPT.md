# Prompt for an AI agent: install or adapt

> 🇹🇷 Türkçe: [PROMPT.tr.md](PROMPT.tr.md)

Give the text below to an agent with terminal and file access, such as Claude Code. Run the agent in this repository's folder. The Kobo must be connected over USB or reachable over SSH on the same network.

---

```
This repository contains a setup that turns an AB Shutter 3 Bluetooth shutter
remote into a page turner for Kobo e-readers (read README.md in full). Your job
is to install it on my Kobo and adapt it to my device where needed.

My device: <MODEL, e.g. Kobo Libra 2>. It has Bluetooth. KOReader, NickelMenu
and KFMon are installed (if not, tell me first).

Steps:

1. Identify the device.
   - Over USB, read the model and firmware version from .kobo/version.
   - For SSH, use KOReader's SSH server (port 2222). Generate a new ed25519
     key on the PC and add it to .adds/koreader/settings/SSH/authorized_keys.
     Don't rely on passwordless login.
   - With Nickel running (not KOReader), inspect:
     * /proc/bus/input/devices
     * The Bluetooth stack: does ps show mtkbtd/btservice or
       bluetoothd/hciattach?
     * D-Bus names (org.bluez or com.kobo.mtk.bluedroid?)
     * /sys/devices/platform/bt/rfkill
     * The full hciattach command line
     * Whether /etc/init.d/on-animator.sh is KFMon's version
       (KFMon log: /usr/local/kfmon/kfmon.log)

2. Verify the shutter. Ask me to pair the shutter from Nickel, then read raw
   events from /dev/input/eventN to confirm the buttons really send
   KEY_VOLUMEUP (115). You can use FFI with KOReader's luajit. If a different
   code arrives, adapt shutter_remap.lua.

3. Install the files. Copy onboard/ to /mnt/onboard (line endings must be LF).
   - If the device has physical page buttons, do NOT install
     patches/2-shutter-pagekeys.lua.
   - To find out, check the model's hasKeys value in KOReader's
     frontend/device/kobo/device.lua.

4. System side. First back up /etc/init.d/on-animator.sh. Then insert the
   rootfs/etc/init.d/on-animator-head.sh block at the top of the file (after
   the shebang) and check it with `sh -n`. Tell me what you are about to do
   and get my approval before this step.

5. Adapt the Bluetooth backend.
   - On MediaTek, the MTK backend should work as is.
   - On BlueZ, replace BLUEZ.hciattach in main.lua with the real command line
     from the device.
   - With KOReader running (after koreader.sh has shut Bluetooth down), first
     test the plugin's power-on sequence by hand over SSH: chip power/rfkill,
     hciattach, bluetoothd (in the background!), Adapter1.Powered,
     Device1.Connect. Put the sequence that works into the plugin.

6. Test. Ask me to do the following and verify the results:
   - Short and long press in Nickel
   - Short and long press in KOReader
   - Bluetooth off/on from the KOReader menu, and reconnecting
   - Exiting KOReader, with NickelMenu still present afterwards

Rules:
- Back up and ask me before changing any Kobo system file.
- Change only what this task needs. Don't edit KOReader's own files
  (koreader.sh, frontend/); updates overwrite them. Use the plugin and user
  patches (patches/) instead.
- If something doesn't work, don't guess; read the logs:
  /tmp/shutter_remap.log, .adds/koreader/crash.log, logread, dmesg.
- When done, summarize what you changed, where the backups are, and what you
  could not verify.
```
