-- Bluetooth + AB Shutter 3 control for Kobos without Nickel.
-- Two Bluetooth stacks are supported:
--   * MTK (Clara BW/Colour): Kobo's mtkbtd D-Bus service keeps running after KOReader
--     kills Nickel, so we only toggle the adapter and connect.
--   * BlueZ on sunxi (Sage): koreader.sh powers the chip down and kills bluetoothd,
--     so powering on rebuilds the stack the way Nickel does (bluez_up.sh).
-- Page turns come from shutter_remap.lua, which turns the shutter's volume-up key
-- into Kobo page-button codes on a uinput device.
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")

if not Device:isKobo() then
    return { disabled = true, }
end

local ADAPTER = "/org/bluez/hci0"
local SHUTTER_NAME = "AB Shutter3"
local KOREADER_DIR = "/mnt/onboard/.adds/koreader"
local LUAJIT = KOREADER_DIR .. "/luajit"
local REMAP_LUA = "/mnt/onboard/.adds/shutter/shutter_remap.lua"
local REMAP_PID = "/tmp/shutter_remap.pid"
local REMAP_LOG = "/tmp/shutter_remap.log"
local REMAP_PAUSED = "/tmp/shutter_remap.paused"
local REMAP_DEVICE_NAME = "Shutter Remap"
-- Output of Bluetooth bring-ups, for troubleshooting.
local BT_LOG = "/tmp/shutter_bt.log"
-- Held by bluez_up.sh while it works on the chip.
local BT_LOCK = "/tmp/shutter_bt.lock"
-- A bring-up takes ~15 s and can retry, so the first check waits for it.
local WATCHDOG_FIRST_S = 90
local WATCHDOG_EVERY_S = 60
-- Consecutive checks without the shutter before bluetoothd is restarted.
local RESTART_AFTER_MISSES = 2
-- After a start or wake bring-up, check again after this long...
local FOLLOW_UP_S = 20
-- ...then repeat this often...
local FOLLOW_UP_EVERY_S = 20
-- ...for this long.
local FOLLOW_UP_FOR_S = 150
-- A "start" within this long of another bring-up is a duplicate.
local RECENT_BRINGUP_S = 60
-- Shared by the file manager's and the reader's plugin instances.
local last_bringup = 0
-- How often to look up which paired device is the shutter again.
local SHUTTER_RECHECK_S = 30
-- How long to keep watching for the shutter after a bring-up, to announce it.
local ANNOUNCE_WITHIN_S = 150

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    local out = p:read("*a")
    p:close()
    return out
end

-- Appends to BT_LOG under a header naming why it ran; the log is cut when it gets big.
local function runAsync(cmd, reason)
    os.execute(string.format(
        "( [ \"$(wc -c < %s 2>/dev/null || echo 0)\" -gt 50000 ] && : > %s;"
            .. " echo \"== $(date '+%%F %%T') %s\"; %s ) >> %s 2>&1 &",
        BT_LOG, BT_LOG, reason or "", cmd, BT_LOG))
end

local function fileExists(path)
    local f = io.open(path)
    if f then f:close() end
    return f ~= nil
end

local function isRunning(name)
    return run("pidof " .. name):match("%d") ~= nil
end

-- Bluetooth backends

local MTK = {
    dest = "com.kobo.mtk.bluedroid",
    -- mtkbtd is busy for a while after a wake (each call takes ~5 s and it only starts
    -- looking for the shutter ~35 s in, whatever we do), so don't rush it.
    resume_delay = 8,
}

function MTK:available() return true end

-- mtkbtd restarts on wake and doesn't answer for a while (commands sent meanwhile are
-- lost), and comes back with the adapter off, so wait until it answers first.
function MTK:waitReadyCmd()
    return "i=0; until dbus-send --system --print-reply --reply-timeout=2000 --dest=" .. self.dest
        .. " " .. ADAPTER .. " org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:Powered"
        .. " >/dev/null 2>&1 || [ $i -ge 20 ]; do sleep 1; i=$((i+1)); done; echo \"mtkbtd ready after ${i}s\""
end

-- mtkbtd's Device1.Connect blocks the whole service until it gives up when the shutter
-- doesn't answer (asleep, or right after a wake), and every other call times out
-- meanwhile. Power-cycling the adapter instead makes mtkbtd scan for its paired
-- devices and reconnect the shutter by itself, within ~5 s when it's awake. So on
-- MediaTek, bringing up and reconnecting are both just a power-cycle, never Connect.
function MTK:powerCycleCmd()
    return self:waitReadyCmd() .. "; " .. self:setPoweredCmd(false) .. "; sleep 2; " .. self:setPoweredCmd(true)
end

function MTK:bringUpCmd(_force, _device)
    return self:powerCycleCmd()
end

function MTK:reconnectCmd(_device, _restart)
    return self:powerCycleCmd()
end

function MTK:powerOffCmd()
    return self:setPoweredCmd(false)
end

local BLUEZ = {
    dest = "org.bluez",
    resume_delay = 2,
    rfkill = "/sys/devices/platform/bt/rfkill/rfkill0/state",
    bluetoothd = "/libexec/bluetooth/bluetoothd",
    -- Rebuilds the UART link with retries and a lock; see the comments in the script.
    script = KOREADER_DIR .. "/plugins/shutter.koplugin/bluez_up.sh",
}

function BLUEZ:chipPowered()
    local f = io.open(self.rfkill)
    local state = f and f:read("*l")
    if f then f:close() end
    return state == "1"
end

function BLUEZ:available()
    return self:chipPowered() and isRunning("bluetoothd") and fileExists("/sys/class/bluetooth/hci0")
end

-- BlueZ sometimes stops reconnecting the shutter after it drops, while a fresh
-- bluetoothd always picks it back up, so restart bluetoothd when asked.
function BLUEZ:reconnectCmd(device, restart)
    local cmd = self:dbusCmd(device, "org.bluez.Device1.Connect")
    if restart then
        cmd = "killall -q bluetoothd; sleep 1; " .. self.bluetoothd .. " & sleep 3; "
            .. self:setPoweredCmd(true) .. "; sleep 2; " .. cmd
    end
    return cmd
end

-- Suspend can kill hciattach, so a resume always rebuilds (force).
function BLUEZ:bringUpCmd(force, device)
    return string.format("sh %s %s %s", self.script, force and "force" or "''", device or "")
end

-- Mirror koreader.sh: leave the chip powered down so it doesn't drain the battery.
function BLUEZ:powerOffCmd()
    return table.concat({
        self:setPoweredCmd(false),
        "killall -q bluetoothd hciattach",
        "echo 0 > " .. self.rfkill,
        "cd " .. KOREADER_DIR .. " && ./luajit frontend/device/kobo/ntx_io.lua 126 0",
    }, "; ")
end

for _i, backend in ipairs({MTK, BLUEZ}) do
    function backend:dbusCmd(path, method, ...)
        return string.format("dbus-send --system --print-reply --reply-timeout=5000 --dest=%s %s %s %s",
            self.dest, path, method, table.concat({...}, " "))
    end

    -- Status queries run on the UI thread, so don't let a busy or restarting
    -- Bluetooth service stall page turns for long.
    function backend:queryCmd(path, method, ...)
        return (self:dbusCmd(path, method, ...):gsub("reply%-timeout=5000", "reply-timeout=1500"))
    end

    function backend:setPoweredCmd(on)
        return self:dbusCmd(ADAPTER, "org.freedesktop.DBus.Properties.Set", "string:org.bluez.Adapter1",
            "string:Powered", "variant:boolean:" .. tostring(on))
    end

    function backend:getBool(path, iface, prop)
        if not self:available() then return false end
        local out = run(self:queryCmd(path, "org.freedesktop.DBus.Properties.Get", "string:" .. iface, "string:" .. prop))
        return out:match("boolean (%a+)") == "true"
    end
end

local function detectBackend()
    if fileExists("/usr/local/Kobo/mtkbtd") then return MTK end
    if fileExists(BLUEZ.bluetoothd) then return BLUEZ end
end

local Shutter = WidgetContainer:extend{
    name = "shutter",
    is_doc_only = false,
}

function Shutter:init()
    self.bt = detectBackend()
    self.autoconnect = G_reader_settings:nilOrTrue("shutter_autoconnect")
    self.ui.menu:registerToMainMenu(self)
    self:ensureRemap()
    -- Whether Bluetooth should be up; turning it off from the menu stops the watchdog.
    self.bt_wanted = self.bt ~= nil and self.autoconnect
    if self.bt_wanted then
        self:bringUp(false, "start")
    end
    self.watchdog = function() self:checkBluetooth() end
    UIManager:scheduleIn(WATCHDOG_FIRST_S, self.watchdog)
end

-- A bring-up can fail (e.g. while KOReader is restarting Wi-Fi on the same chip),
-- suspend can take the stack down, and the shutter can drop and not come back, so
-- keep checking: rebuild Bluetooth when it's gone, and reconnect a missing shutter,
-- restarting bluetoothd when plain reconnects keep failing.
function Shutter:checkBluetooth()
    logger.dbg("Shutter: watchdog check, wanted:", self.bt_wanted)
    if self.bt_wanted and not fileExists(BT_LOCK) then
        local device = self:shutterPath()
        -- The adapter can also come back switched off (mtkbtd restarts on wake).
        if not self.bt:available() or not self:isPowered() then
            self.missed_checks = 0
            self:bringUp(false, "watchdog")
        elseif device and not self:isConnected() then
            self.missed_checks = (self.missed_checks or 0) + 1
            local restart = self.missed_checks % RESTART_AFTER_MISSES == 0
            runAsync(self.bt:reconnectCmd(device, restart), restart and "reconnect+restart" or "reconnect")
        else
            self.missed_checks = 0
        end
    end
    UIManager:scheduleIn(WATCHDOG_EVERY_S, self.watchdog)
end

function Shutter:onCloseWidget()
    UIManager:unschedule(self.watchdog)
    UIManager:unschedule(self.connection_poll)
    UIManager:unschedule(self.follow_up)
end

-- Bluetooth

function Shutter:isPowered()
    return self.bt:getBool(ADAPTER, "org.bluez.Adapter1", "Powered")
end

-- Finds the paired shutter, preferring a connected one. Every AB Shutter 3 has the
-- same name and the old pairing can linger after pairing a new one, so the name
-- alone isn't enough.
function Shutter:findShutter()
    local xml = run(self.bt:queryCmd(ADAPTER, "org.freedesktop.DBus.Introspectable.Introspect"))
    local paired
    for node in xml:gmatch('node name="(dev_[%x_]+)"') do
        local path = ADAPTER .. "/" .. node
        local props = run(self.bt:queryCmd(path, "org.freedesktop.DBus.Properties.GetAll", "string:org.bluez.Device1"))
        if props:match('"Name"%s+variant%s+string "(.-)"') == SHUTTER_NAME
                and props:match('"Paired"%s+variant%s+boolean (%a+)') == "true" then
            if props:match('"Connected"%s+variant%s+boolean (%a+)') == "true" then
                return path
            end
            paired = paired or path
        end
    end
    return paired
end

-- Device objects vanish while the adapter is off, so the last shutter found is kept in
-- the settings; while Bluetooth is up it's looked up again now and then, so pairing a
-- different shutter is picked up.
function Shutter:shutterPath()
    -- Only look while the adapter is on: while it's off (or mtkbtd is restarting) the
    -- device objects are gone, which says nothing about the pairing, so never forget
    -- the saved shutter because of that.
    if os.time() - (self.shutter_checked_at or 0) >= SHUTTER_RECHECK_S
            and self.bt:available() and self:isPowered() then
        self.shutter_checked_at = os.time()
        local found = self:findShutter()
        if found and found ~= G_reader_settings:readSetting("shutter_bt_path") then
            G_reader_settings:saveSetting("shutter_bt_path", found)
        end
    end
    return G_reader_settings:readSetting("shutter_bt_path")
end

function Shutter:isConnected()
    local path = self:shutterPath()
    return path ~= nil and self.bt:getBool(path, "org.bluez.Device1", "Connected")
end

-- Power on and connect in the background; bringing the stack up can take several seconds.
function Shutter:bringUp(force, reason)
    -- Opening a book right after start or wake creates a second plugin instance; don't
    -- run a second bring-up, but take over the follow-up check, since the file
    -- manager's instance cancels its own when it closes.
    if reason == "start" and os.time() - last_bringup < RECENT_BRINGUP_S then
        self:scheduleFollowUp(reason)
        return
    end
    last_bringup = os.time()
    runAsync(self.bt:bringUpCmd(force, self:shutterPath()), reason)
    self:announceConnection()
    if reason == "start" or reason == "resume" then
        self:scheduleFollowUp(reason)
    end
end

-- A plain connect often isn't enough after start or wake (the Bluetooth service can be
-- stuck on an old attempt), so if the shutter still isn't there shortly after, force
-- the reconnect that a menu tap would do instead of waiting for the watchdog.
-- On the Clara, KOReader restoring Wi-Fi after a wake resets the shared Wi-Fi/Bluetooth
-- chip, which kills the Bluetooth service ~35 s later; it comes back with the adapter
-- off. So keep checking for a couple of minutes and repair whatever is missing.
function Shutter:scheduleFollowUp(reason)
    UIManager:unschedule(self.follow_up)
    local deadline = os.time() + FOLLOW_UP_FOR_S
    local forced = false
    self.follow_up = function()
        logger.info("Shutter: follow-up check", reason, "wanted:", self.bt_wanted)
        if not self.bt_wanted then return end
        if not fileExists(BT_LOCK) then -- otherwise a BlueZ bring-up is still running
            local device = self:shutterPath()
            if not self.bt:available() or not self:isPowered() then
                runAsync(self.bt:bringUpCmd(false, device), reason .. " follow-up: power on")
            elseif device and not self:isConnected() then
                -- First a plain connect; if that didn't do it, the stronger restart.
                runAsync(self.bt:reconnectCmd(device, forced), reason .. " follow-up: reconnect")
                forced = not forced
            elseif device then
                return -- connected
            end
        end
        if os.time() < deadline then
            UIManager:scheduleIn(FOLLOW_UP_EVERY_S, self.follow_up)
        end
    end
    UIManager:scheduleIn(FOLLOW_UP_S, self.follow_up)
    self:announceConnection()
end

-- Bring-ups run in the background and can take most of a minute, so tell the user
-- when the shutter is actually ready.
function Shutter:announceConnection()
    UIManager:unschedule(self.connection_poll)
    local deadline = os.time() + ANNOUNCE_WITHIN_S
    self.connection_poll = function()
        if self:isConnected() then
            UIManager:show(Notification:new{ text = _("Shutter connected") })
        elseif os.time() < deadline then
            UIManager:scheduleIn(3, self.connection_poll)
        end
    end
    UIManager:scheduleIn(3, self.connection_poll)
end

function Shutter:powerOff()
    run(self.bt:powerOffCmd())
end

-- Page-turn remapper

function Shutter:remapPid()
    local f = io.open(REMAP_PID)
    if not f then return end
    local pid = f:read("*n")
    f:close()
    if pid and fileExists("/proc/" .. pid) then
        local cmdline = io.open("/proc/" .. pid .. "/cmdline")
        local s = cmdline and cmdline:read("*a") or ""
        if cmdline then cmdline:close() end
        if s:find("shutter_remap", 1, true) then return pid end
    end
end

function Shutter:isRemapping()
    return self:remapPid() ~= nil and not fileExists(REMAP_PAUSED)
end

-- KOReader only scans input devices at startup, so open the remapper's device
-- ourselves if it appeared later. Input:open ignores devices it already has.
function Shutter:openRemapDevice()
    local f = io.open("/proc/bus/input/devices")
    if not f then return end
    local text = f:read("*a")
    f:close()
    for block in text:gmatch("(.-)\n\n") do
        if block:find('N: Name="' .. REMAP_DEVICE_NAME .. '"', 1, true) then
            local ev = block:match("Handlers=[^\n]*(event%d+)")
            if ev then
                local ok, err = pcall(Device.input.open, Device.input, "/dev/input/" .. ev, REMAP_DEVICE_NAME)
                if not ok then logger.warn("Shutter: cannot open remap device:", err) end
            end
        end
    end
end

function Shutter:ensureRemap()
    if not fileExists(REMAP_LUA) then return end
    if self:remapPid() then
        self:openRemapDevice()
        return
    end
    os.execute(string.format("%s %s > %s 2>&1 & echo $! > %s", LUAJIT, REMAP_LUA, REMAP_LOG, REMAP_PID))
    UIManager:scheduleIn(1.5, function() self:openRemapDevice() end)
end

function Shutter:setRemapping(on)
    if on then
        os.remove(REMAP_PAUSED)
        self:ensureRemap()
    else
        local f = io.open(REMAP_PAUSED, "w")
        if f then f:close() end
    end
end

function Shutter:onResume()
    logger.info("Shutter: resume, wanted:", self.bt_wanted)
    if self.bt_wanted then
        -- Give the Bluetooth firmware a moment after wakeup.
        UIManager:scheduleIn(self.bt.resume_delay, function() self:bringUp(true, "resume") end)
    end
end

-- Keep an open menu's Bluetooth and shutter lines current while a bring-up runs.
function Shutter:refreshUntilReady(touchmenu_instance)
    local deadline = os.time() + ANNOUNCE_WITHIN_S
    local function refresh()
        -- The menu may have been closed meanwhile; that's fine, just stop.
        if not pcall(touchmenu_instance.updateItems, touchmenu_instance) then return end
        if not self:isConnected() and os.time() < deadline then
            UIManager:scheduleIn(3, refresh)
        end
    end
    UIManager:scheduleIn(3, refresh)
end

function Shutter:addToMainMenu(menu_items)
    local bt_items = {}
    if self.bt then
        bt_items = {
            {
                -- The tick shows whether Bluetooth is meant to be on (auto-connect turns it
                -- on at start); a bring-up takes a while, so say when it isn't ready yet.
                text_func = function()
                    if self.bt_wanted and not self:isPowered() then
                        return _("Bluetooth (turning on…)")
                    end
                    return _("Bluetooth")
                end,
                checked_func = function() return self.bt_wanted end,
                callback = function(touchmenu_instance)
                    if self.bt_wanted then
                        self.bt_wanted = false
                        self:powerOff()
                        touchmenu_instance:updateItems()
                    else
                        self.bt_wanted = true
                        self:bringUp(false, "menu")
                        self:refreshUntilReady(touchmenu_instance)
                    end
                end,
            },
            {
                text_func = function()
                    if not self:shutterPath() then
                        return _("Shutter: no paired shutter found")
                    end
                    return self:isConnected() and _("Shutter: connected") or _("Shutter: not connected (tap to connect)")
                end,
                keep_menu_open = true,
                enabled_func = function() return self:shutterPath() ~= nil end,
                callback = function(touchmenu_instance)
                    self.bt_wanted = true
                    -- A tap is the user saying it's stuck, so use the strongest fix:
                    -- reconnect with an adapter/bluetoothd restart, or a full bring-up.
                    local device = self:shutterPath()
                    if device and self.bt:available() then
                        runAsync(self.bt:reconnectCmd(device, true), "menu reconnect")
                        self:announceConnection()
                    else
                        self:bringUp(false, "menu")
                    end
                    UIManager:show(InfoMessage:new{
                        text = _("Connecting… If it doesn't connect, press a shutter button once."),
                        timeout = 4,
                    })
                    self:refreshUntilReady(touchmenu_instance)
                end,
            },
        }
    end
    table.insert(bt_items, {
        text = _("Turn pages with shutter"),
        help_text = _("Short press: next page. Long press: previous page."),
        checked_func = function() return self:isRemapping() end,
        callback = function()
            self:setRemapping(not self:isRemapping())
        end,
    })
    if self.bt then
        table.insert(bt_items, {
            text = _("Auto-connect on start and wake"),
            checked_func = function() return self.autoconnect end,
            callback = function()
                self.autoconnect = not self.autoconnect
                G_reader_settings:saveSetting("shutter_autoconnect", self.autoconnect)
            end,
        })
    end
    menu_items.bluetooth_shutter = {
        text = _("Bluetooth & Shutter"),
        sorting_hint = "network",
        sub_item_table = bt_items,
    }
end

return Shutter
