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
}

function MTK:available() return true end

function MTK:bringUpCmd(_force, device)
    local cmd = self:setPoweredCmd(true)
    if device then
        cmd = cmd .. "; sleep 3; " .. self:dbusCmd(device, "org.bluez.Device1.Connect")
    end
    return cmd
end

function MTK:powerOffCmd()
    return self:setPoweredCmd(false)
end

local BLUEZ = {
    dest = "org.bluez",
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

    function backend:setPoweredCmd(on)
        return self:dbusCmd(ADAPTER, "org.freedesktop.DBus.Properties.Set", "string:org.bluez.Adapter1",
            "string:Powered", "variant:boolean:" .. tostring(on))
    end

    function backend:getBool(path, iface, prop)
        if not self:available() then return false end
        local out = run(self:dbusCmd(path, "org.freedesktop.DBus.Properties.Get", "string:" .. iface, "string:" .. prop))
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

-- A bring-up can fail (e.g. while KOReader is restarting Wi-Fi on the same chip) and
-- suspend can take the stack down, so keep checking and rebuild it when it's gone.
function Shutter:checkBluetooth()
    if self.bt_wanted and not self.bt:available() and not fileExists(BT_LOCK) then
        self:bringUp(false, "watchdog")
    end
    UIManager:scheduleIn(WATCHDOG_EVERY_S, self.watchdog)
end

function Shutter:onCloseWidget()
    UIManager:unschedule(self.watchdog)
    UIManager:unschedule(self.connection_poll)
end

-- Bluetooth

function Shutter:isPowered()
    return self.bt:getBool(ADAPTER, "org.bluez.Adapter1", "Powered")
end

-- Device objects vanish while the adapter is off, so remember the shutter's path once found.
function Shutter:shutterPath()
    local cached = G_reader_settings:readSetting("shutter_bt_path")
    if cached then return cached end
    if not self.bt:available() then return end
    local xml = run(self.bt:dbusCmd(ADAPTER, "org.freedesktop.DBus.Introspectable.Introspect"))
    for node in xml:gmatch('node name="(dev_[%x_]+)"') do
        local path = ADAPTER .. "/" .. node
        local name = run(self.bt:dbusCmd(path, "org.freedesktop.DBus.Properties.Get",
            "string:org.bluez.Device1", "string:Name")):match('string "(.-)"')
        if name == SHUTTER_NAME then
            G_reader_settings:saveSetting("shutter_bt_path", path)
            return path
        end
    end
end

function Shutter:isConnected()
    local path = self:shutterPath()
    return path ~= nil and self.bt:getBool(path, "org.bluez.Device1", "Connected")
end

-- Power on and connect in the background; bringing the stack up can take several seconds.
function Shutter:bringUp(force, reason)
    runAsync(self.bt:bringUpCmd(force, self:shutterPath()), reason)
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
    if self.bt_wanted then
        -- Give the Bluetooth firmware a moment after wakeup.
        UIManager:scheduleIn(2, function() self:bringUp(true, "resume") end)
    end
end

function Shutter:addToMainMenu(menu_items)
    local bt_items = {}
    if self.bt then
        bt_items = {
            {
                text = _("Bluetooth"),
                checked_func = function() return self:isPowered() end,
                callback = function(touchmenu_instance)
                    if self:isPowered() then
                        self.bt_wanted = false
                        self:powerOff()
                        touchmenu_instance:updateItems()
                    else
                        self.bt_wanted = true
                        self:bringUp(false, "menu")
                        UIManager:show(InfoMessage:new{ text = _("Turning Bluetooth on…"), timeout = 3 })
                        UIManager:scheduleIn(8, function() touchmenu_instance:updateItems() end)
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
                    self:bringUp(false, "menu")
                    UIManager:show(InfoMessage:new{
                        text = _("Connecting… If it doesn't connect, press a shutter button once."),
                        timeout = 4,
                    })
                    UIManager:scheduleIn(8, function() touchmenu_instance:updateItems() end)
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
