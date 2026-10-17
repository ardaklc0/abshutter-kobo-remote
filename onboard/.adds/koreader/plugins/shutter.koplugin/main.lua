-- Bluetooth + AB Shutter 3 control for Kobos without Nickel.
-- Two Bluetooth stacks are supported:
--   * MTK (Clara BW/Colour): Kobo's mtkbtd D-Bus service keeps running after KOReader
--     kills Nickel, so we only toggle the adapter and connect.
--   * BlueZ on sunxi (Sage): koreader.sh powers the chip down and kills bluetoothd,
--     so powering on rebuilds the stack the way Nickel does.
-- Page turns come from shutter_remap.lua, which turns the shutter's volume-up key
-- into Kobo page-button codes on a uinput device.
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
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

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    local out = p:read("*a")
    p:close()
    return out
end

local function runAsync(cmd)
    os.execute("(" .. cmd .. ") >/dev/null 2>&1 &")
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

function MTK:powerOnCmd()
    return self:setPoweredCmd(true)
end

function MTK:powerOffCmd()
    return self:setPoweredCmd(false)
end

-- Same sequence Nickel uses on sunxi; values taken from the running processes on a Sage.
local BLUEZ = {
    dest = "org.bluez",
    rfkill = "/sys/devices/platform/bt/rfkill/rfkill0/state",
    hciattach = "/sbin/hciattach -n /dev/ttyS1 bcm43xx 1500000 flow -t 20 -b bcm43xx_init",
    bluetoothd = "/libexec/bluetooth/bluetoothd",
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

-- koreader.sh cuts the chip's power but leaves Nickel's hciattach (and so hci0) around,
-- so the chip state, not hci0, decides whether the UART link has to be rebuilt.
function BLUEZ:powerOnCmd()
    return table.concat({
        "cd " .. KOREADER_DIR,
        "if [ \"$(cat " .. self.rfkill .. ")\" != 1 ] || ! pidof hciattach >/dev/null; then"
            .. " killall -q bluetoothd hciattach; sleep 1;"
            .. " ./luajit frontend/device/kobo/ntx_io.lua 126 1;"
            .. " echo 1 > " .. self.rfkill .. "; sleep 1;"
            .. " " .. self.hciattach .. " &"
            .. " i=0; while [ ! -e /sys/class/bluetooth/hci0 ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done;"
            .. " sleep 2;"
            .. " fi",
        -- bluetoothd stays in the foreground here.
        "pidof bluetoothd >/dev/null || { " .. self.bluetoothd .. " & sleep 3; }",
        self:setPoweredCmd(true),
    }, "; ")
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
    if self.bt and self.autoconnect then
        self:bringUp()
    end
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
function Shutter:bringUp()
    local cmd = self.bt:powerOnCmd()
    local path = self:shutterPath()
    if path then
        cmd = cmd .. "; sleep 3; " .. self.bt:dbusCmd(path, "org.bluez.Device1.Connect")
    end
    runAsync(cmd)
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
    if self.bt and self.autoconnect then
        -- Give the Bluetooth firmware a moment after wakeup.
        UIManager:scheduleIn(2, function() self:bringUp() end)
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
                        self:powerOff()
                        touchmenu_instance:updateItems()
                    else
                        self:bringUp()
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
                    self:bringUp()
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
