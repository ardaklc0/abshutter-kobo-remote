# Kobo + AB Shutter 3: a cheap Bluetooth page turner

> 🇹🇷 Türkçe: [README.tr.md](README.tr.md)

Turns a cheap Bluetooth camera shutter remote (**AB Shutter 3**) into a page turner for Kobo e-readers. It works in Kobo's stock reader (Nickel) and in **KOReader**.

- **Short press:** next page
- **Long press** (over half a second): previous page. Fires as soon as the hold passes the threshold, without waiting for release.

It also fixes two common annoyances for KOReader users on Kobo:

- **NickelMenu disappearing** after exiting KOReader
- **KFMon not starting at boot** after a Kobo firmware update (`kfmon: error checking '/tmp/kfmon-ipc.ctl'`)

> ⚠️ This modifies a Kobo system file (`/etc/init.d/on-animator.sh`) and installs scripts that run as root. Use at your own risk. Not affiliated with Kobo or KOReader.

---

## Tested devices

| Device | Kobo FW | KOReader | Bluetooth stack | Nickel | KOReader |
|---|---|---|---|---|---|
| Kobo Clara Colour (BW is the same family) | 4.46 | v2026.03 | MediaTek (`mtkbtd`) | ✅ | ✅ |
| Kobo Sage | 4.38 | v2026.07.2 | BlueZ (`bluetoothd`, Broadcom) | ✅ | ✅ |

Other Bluetooth Kobos (Libra 2, Libra Colour, Elipsa 2E, Clara 2E) will probably work. Some Sage-specific values, such as the `hciattach` arguments, may need adjusting. See below.


---

## How it works

### 1. What the shutter sends

Both buttons on the AB Shutter 3 (CAMERA 360 / iOS and ANDROID) send **the exact same event at the hardware level**: `KEY_VOLUMEUP` (code 115). Its HID descriptor has a single consumer-control report: Volume Up, Volume Down, Mute and Power. There is no keyboard (Enter) report, so the two buttons cannot be told apart. The direction is therefore decided by **press length**.

Kobo doesn't treat that key as a page turn, which is why the shutter pairs fine but does nothing.

### 2. The remapper (`shutter_remap.lua`)

A small program run with the LuaJIT that ships with KOReader:

1. Finds the `AB Shutter3` device in `/proc/bus/input/devices` and grabs it exclusively with `EVIOCGRAB`.
2. Creates a virtual keyboard called **"Shutter Remap"** through `/dev/uinput`.
3. Sends keys from the virtual keyboard depending on press length:
   - **In Nickel:** `KEY_RIGHT` / `KEY_LEFT`. Nickel turns pages on arrow keys from Bluetooth keyboards; `KEY_PAGEDOWN` did not work.
   - **In KOReader:** `KEY_F24` (194) / `KEY_F23` (193), the codes of Kobo's physical page buttons. Because of these, KOReader's input scan (FBInk) classifies the virtual device as `PAGINATION_BUTTONS` and opens it automatically.
4. If the shutter disconnects, it rescans every 3 seconds, so it recovers after the Kobo sleeps and wakes.

If `/tmp/shutter_remap.paused` exists, key presses are ignored. The KOReader plugin uses this to pause remapping. The program keeps running, so the virtual device KOReader has open never disappears.

### 3. KOReader plugin (`shutter.koplugin`)

Adds a **Network → Bluetooth & Shutter** menu:

- **Bluetooth:** on/off
- **Shutter: connected / not connected:** tap to connect
- **Turn pages with shutter:** enable or pause remapping
- **Auto-connect on start and wake:** on by default

KOReader stops Nickel when it starts, and on devices like the Sage it also shuts Bluetooth down. The plugin manages Bluetooth without Nickel:

- **MediaTek devices (Clara BW/Colour):** Kobo's `mtkbtd` service keeps running under KOReader and is driven over D-Bus (`com.kobo.mtk.bluedroid`, which exposes BlueZ-compatible `org.bluez.Adapter1`/`Device1` interfaces). The plugin never calls `Device1.Connect` there: when the shutter doesn't answer, that call blocks the whole service until it gives up, and every other call times out meanwhile. Instead it power-cycles the adapter, which makes `mtkbtd` scan for its paired devices and reconnect the shutter by itself, in about 10 seconds. After a wake `mtkbtd` is busy for a while and also gets reset when KOReader restores Wi-Fi (Wi-Fi and Bluetooth share one chip), so the plugin waits for it to answer before acting.
- **BlueZ devices (Sage):** at startup, `koreader.sh` cuts power to the chip (`rfkill` + `ntx_io 126 0`) and kills `bluetoothd`. Nickel's `hciattach` keeps running, though, so `hci0` still exists even though the chip is off. The plugin:
  1. Kills the stale `hciattach`.
  2. Powers the chip back on (`ntx_io 126 1`, `rfkill` = 1).
  3. Restarts `hciattach`.
  4. Starts `bluetoothd` in the background.
  5. Powers the adapter and connects the shutter.

  This lives in `bluez_up.sh`. After `hciattach` restarts, the controller answers commands but can't run LE scans until it gets an HCI reset (`hciconfig hci0 reset`), so the script resets it; without that the shutter is never seen. The chip also handles Wi-Fi, which KOReader is often bringing up at the same moment, so the script power-cycles the chip with generous waits and retries up to 3 times. A lock keeps the two plugin instances (file manager and reader) from working on the chip at once.

  Pairings are stored persistently in `/var/db/bluetooth`, so there is no need to pair again.

Everything is automatic while **Auto-connect** is on:

- **On start and on wake**, the plugin brings Bluetooth up. On BlueZ, sleep can kill `hciattach`, so a wake always rebuilds the link. A "Shutter connected" notification appears when it's ready. Measured from wake to connected: about **15 s on the Sage** and about **35-40 s on the Clara**, where `mtkbtd` only starts looking for the shutter that long after a wake, whatever the plugin does. On start, after a disconnect or from the menu it takes about 10 s on both.
- **Follow-up checks and a watchdog.** For 2.5 minutes after start or wake the plugin checks every 20 s, and after that a watchdog checks every minute. If the adapter is off it turns it on; if the shutter is missing it reconnects it (after 2 failed watchdog checks on BlueZ it restarts `bluetoothd`). Tapping the shutter line in the menu does the strongest reconnect right away. Turning Bluetooth off from the menu stops all of this until you turn Bluetooth back on.
- The **Bluetooth** tick shows whether Bluetooth is meant to be on; while a bring-up is still running the line reads "Bluetooth (turning on…)".
- Every AB Shutter 3 has the same name. The plugin uses whichever one is currently paired (preferring a connected one), so pairing a different shutter just works.
- Every bring-up is logged to `/tmp/shutter_bt.log` with the reason (`start`, `resume`, `watchdog`, `menu`).

KOReader scans input devices only at startup. If the remapper starts after KOReader, the plugin opens the virtual device itself with `Device.input:open()`.

### 4. KOReader patch, button-less devices only (`2-shutter-pagekeys.lua`)

On devices without physical page buttons, such as the Clara (`hasKeys = no`), KOReader never registers page-key handlers. This user patch sets `Device.hasKeys` to `true`. It is **not needed** on devices with buttons such as the Sage.

### 5. Boot script fixes (`on-animator.sh`)

KFMon starts at boot by replacing `/etc/init.d/on-animator.sh` with its own version. `nickel.sh` also runs this script when exiting KOReader. Two blocks are added at the top:

- **NickelMenu fix.** While loading, NickelMenu temporarily renames its library to `libnm.so.failsafe`. If Nickel starts properly, it renames it back about 20 seconds later. If KOReader is launched before then (KOReader kills Nickel), the file stays `.failsafe` and **NickelMenu is missing on the next start**. The added block renames a stuck failsafe back before Nickel starts.
- **Shutter autostart.** Starts the remapper unless it is already running.

> This mostly disables NickelMenu's failsafe. If NickelMenu ever really causes a crash, it can no longer disable itself. In that case delete `libnm.so` over SSH, or create `.adds/nm/uninstall`.

A **Kobo firmware update** can restore the original `on-animator.sh`. KFMon not starting is the symptom. If that happens, reinstall KFMon (KOReader/KFMon `KoboRoot.tgz`) and add the header block again.

---

## Files

```
onboard/                                    → Kobo's USB storage (/mnt/onboard)
  .adds/shutter/shutter_remap.lua           Remapper
  .adds/nm/shutter                          NickelMenu entries (start/stop shutter and SSH)
  .adds/koreader/plugins/shutter.koplugin/  KOReader plugin (bluez_up.sh: BlueZ bring-up)
  .adds/koreader/patches/2-shutter-pagekeys.lua   Button-less devices (Clara) only
rootfs/
  etc/init.d/on-animator-head.sh            Block to insert at the top of /etc/init.d/on-animator.sh
```

---

## Installation

### Requirements

- A Kobo with Bluetooth
- [KOReader](https://github.com/koreader/koreader), [NickelMenu](https://pgaskin.net/NickelMenu/) and [KFMon](https://github.com/NiLuJe/kfmon). These usually come with KOReader's one-click install package.
- A root shell on the Kobo. KOReader's SSH server (port 2222) is enough.

### 1. Copy over USB

Connect the Kobo over USB and copy everything under `onboard/` to its root, including the hidden `.adds` folder.

- **Devices without page buttons** (Clara): keep `patches/2-shutter-pagekeys.lua`.
- **Devices with page buttons** (Sage, Libra, Forma, Elipsa): delete it.

On Windows, make sure line endings stay LF. NickelMenu and `sh` can break on CRLF.

### 2. System side over SSH

Copy `on-animator-head.sh` to `/mnt/onboard/` first; you can delete it afterwards. Then run:

```sh
f=/etc/init.d/on-animator.sh
grep -q 'NM_LIB=' "$f" && echo "already installed" || {
  cp -p "$f" /usr/local/kfmon/on-animator.sh.kfmon            # backup
  { echo '#!/bin/sh'; cat /mnt/onboard/on-animator-head.sh; tail -n +2 /usr/local/kfmon/on-animator.sh.kfmon; } > "$f"
  chmod 755 "$f"; sh -n "$f" && sync
}
```

### 3. Pairing

1. Turn on Bluetooth from Kobo's own menu.
2. Hold the shutter's power button until the light blinks.
3. Pair "AB Shutter3" when it appears in the list.

You only need to pair once.

### 4. Usage

- **Nickel:** the remapper starts automatically at boot. If needed, use NickelMenu → **Start shutter / Stop shutter**.
- **KOReader:** **Network → Bluetooth & Shutter**. With auto-connect on, Bluetooth comes up and the shutter connects when KOReader starts. This can take 10-15 seconds. If it doesn't connect, press a shutter button once.

---

## Known issues and notes

- **Bluetooth in Nickel:** Kobo turns Bluetooth off when it sleeps. Turn it back on after waking; the shutter reconnects by itself.
- **First key on a new virtual device:** Nickel may miss the first key from a newly created virtual keyboard. The remapper creates the device once and keeps it, so this doesn't matter in practice.
- **On-screen keyboard (unverified):** Nickel may treat the virtual keyboard as a physical one and hide the on-screen keyboard. If that happens, use NickelMenu → **Stop shutter**.
- **Sage values:** the `hciattach` arguments (`/dev/ttyS1 bcm43xx 1500000 ...`) were taken from the process Nickel runs on a Sage. On other sunxi devices, run `ps | grep hciattach` while Nickel is running and update `BLUEZ.hciattach` in `main.lua`.
- **KOReader SSH security:** if "allow login without password" is on in KOReader, anyone on the same network can log in as root. Use a key and turn on **Login with key only**.
- **Exiting KOReader:** unless KFMon's `koreader.ini` has `reboot_on_exit=false`, KOReader reboots the Kobo on exit. This setup works either way.

---

## Uninstall

1. Turn off **Turn pages with shutter** in KOReader, or use NickelMenu → **Stop shutter**.
2. Delete:
   - `.adds/shutter/`
   - `.adds/nm/shutter`
   - `.adds/koreader/plugins/shutter.koplugin/`
   - `.adds/koreader/patches/2-shutter-pagekeys.lua`
3. Restore the boot script over SSH:
   ```sh
   cp -p /usr/local/kfmon/on-animator.sh.kfmon /etc/init.d/on-animator.sh && sync
   ```

---

## How this was built

This was developed step by step with [Claude Code](https://claude.com/claude-code) by reverse engineering on the device:

1. Reading raw events from `/dev/input` and the shutter's HID descriptor.
2. Watching D-Bus traffic.
3. Testing which key codes Nickel and KOReader accept.
4. Exploring both Bluetooth stacks on the device.

To adapt this setup to another device with an AI agent, see [`PROMPT.md`](PROMPT.md).

## Credits

Built on top of [KOReader](https://github.com/koreader/koreader), [NickelMenu](https://github.com/pgaskin/NickelMenu), [KFMon](https://github.com/NiLuJe/kfmon) and [FBInk](https://github.com/NiLuJe/FBInk). Thanks to their developers.

## License

[AGPL-3.0](LICENSE), the same license as KOReader.
