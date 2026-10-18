#!/bin/sh
# Bring up the BlueZ Bluetooth stack on sunxi Kobos (Sage) without Nickel, then
# connect the shutter. Usage: bluez_up.sh [force] [device_object_path]
#
# koreader.sh cuts the chip's power and kills bluetoothd, and suspend can kill
# hciattach, so the UART link is rebuilt whenever it isn't fully up (or always,
# with "force"). The chip shares power with Wi-Fi, which KOReader is often
# bringing up at the same moment, so attaching can time out; give it a full
# power cycle with generous waits and retry a few times.

RFKILL=/sys/devices/platform/bt/rfkill/rfkill0/state
# Same command line Nickel uses on a Sage.
HCIATTACH="/sbin/hciattach -n /dev/ttyS1 bcm43xx 1500000 flow -t 20 -b bcm43xx_init"
BLUETOOTHD=/libexec/bluetooth/bluetoothd
KOREADER_DIR=/mnt/onboard/.adds/koreader
LOCK=/tmp/shutter_bt.lock

FORCE="$1"
DEVICE="$2"

log() { echo "$(date +%T) $*"; }

# KOReader runs the plugin once for the file manager and once for the reader;
# only one bring-up may touch the chip at a time.
if ! mkdir "$LOCK" 2>/dev/null; then
    log "bring-up already running, skipping"
    exit 0
fi
trap 'rmdir "$LOCK"' EXIT

chip_power() {
    (cd "$KOREADER_DIR" && ./luajit frontend/device/kobo/ntx_io.lua 126 "$1")
    echo "$1" > "$RFKILL"
}

link_up() {
    [ "$(cat "$RFKILL")" = 1 ] && pidof hciattach >/dev/null && [ -e /sys/class/bluetooth/hci0 ]
}

dbus() {
    dbus-send --system --print-reply --reply-timeout=8000 --dest=org.bluez "$@"
}

if [ "$FORCE" = force ] || ! link_up; then
    attached=
    for try in 1 2 3; do
        log "attaching controller (try $try)"
        killall -q bluetoothd hciattach
        sleep 1
        chip_power 0
        sleep 2
        chip_power 1
        sleep 2
        $HCIATTACH &
        i=0
        while [ ! -e /sys/class/bluetooth/hci0 ] && [ $i -lt 25 ]; do sleep 1; i=$((i + 1)); done
        # hci0 can show up just before hciattach gives up, so let it settle first.
        sleep 2
        if link_up; then attached=1; break; fi
        log "controller did not come up"
    done
    if [ -z "$attached" ]; then
        log "giving up"
        exit 1
    fi
    # After attaching, the controller answers commands but fails LE scans
    # ("Set scan parameters failed") until it gets an HCI reset, and then the
    # shutter is never seen.
    hciconfig hci0 reset
    sleep 1
fi

if ! pidof bluetoothd >/dev/null; then
    log "starting bluetoothd"
    $BLUETOOTHD &
    sleep 3
fi

log "powering adapter"
dbus /org/bluez/hci0 org.freedesktop.DBus.Properties.Set string:org.bluez.Adapter1 \
    string:Powered variant:boolean:true

# A paired, trusted HID device is reconnected by BlueZ as soon as it advertises;
# the explicit Connect only speeds that up when the shutter is already awake.
if [ -n "$DEVICE" ]; then
    sleep 2
    log "connecting $DEVICE"
    dbus "$DEVICE" org.bluez.Device1.Connect
fi
log "done"
