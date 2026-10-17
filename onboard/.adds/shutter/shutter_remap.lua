-- AB Shutter 3 -> Kobo page turns.
-- Both shutter buttons send KEY_VOLUMEUP, so press length decides the direction:
--   short press -> next page
--   long press  -> previous page, fired as soon as the hold passes LONG_MS
-- Works in Nickel (arrow keys) and KOReader (Kobo page-button codes).
-- Run with KOReader's LuaJIT: luajit shutter_remap.lua
local ffi = require("ffi")
local bit = require("bit")

local DEVICE_NAME = "AB Shutter3"
local LONG_MS = 500
local RESCAN_S = 3
local KEY_VOLUMEUP, KEY_LEFT, KEY_RIGHT = 115, 105, 106
-- Kobo page-turn button codes; these make KOReader's input scan pick the device up as pagination buttons.
local KEY_F23, KEY_F24 = 193, 194
local EV_SYN, EV_KEY = 0, 1

ffi.cdef[[
struct input_id { uint16_t bustype, vendor, product, version; };
struct uinput_user_dev { char name[80]; struct input_id id; uint32_t ff_effects_max; int32_t absmax[64], absmin[64], absfuzz[64], absflat[64]; };
struct input_event { long sec; long usec; uint16_t type; uint16_t code; int32_t value; };
struct pollfd { int fd; short events; short revents; };
int open(const char *, int);
int close(int);
long read(int, void *, size_t);
long write(int, const void *, size_t);
int ioctl(int, unsigned long, ...);
int poll(struct pollfd *, unsigned long, int);
unsigned int sleep(unsigned int);
int usleep(unsigned int);
]]
local C = ffi.C
local O_RDONLY, O_RDWR, O_NONBLOCK = 0, 2, 04000
local UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE = 0x40045564, 0x40045565, 0x5501
local EVIOCGRAB = 0x40044590
local POLLIN = 1

local function log(...)
    io.stdout:write(os.date("%H:%M:%S "), table.concat({...}, " "), "\n")
    io.stdout:flush()
end

-- Virtual keyboard that Nickel reads like a Bluetooth keyboard.
local function create_uinput()
    local fd = C.open("/dev/uinput", bit.bor(O_RDWR, O_NONBLOCK))
    assert(fd >= 0, "cannot open /dev/uinput")
    assert(C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_KEY)) == 0)
    for _, k in ipairs({KEY_LEFT, KEY_RIGHT, KEY_F23, KEY_F24}) do
        assert(C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", k)) == 0)
    end
    local dev = ffi.new("struct uinput_user_dev")
    ffi.copy(dev.name, "Shutter Remap")
    dev.id.bustype = 0x05
    dev.id.vendor = 0x1234
    dev.id.product = 0x5678
    dev.id.version = 1
    assert(C.write(fd, dev, ffi.sizeof(dev)) == ffi.sizeof(dev))
    assert(C.ioctl(fd, UI_DEV_CREATE) == 0)
    return fd
end

local out = create_uinput()
local ev_out = ffi.new("struct input_event")

local function emit(type, code, value)
    ev_out.type, ev_out.code, ev_out.value = type, code, value
    C.write(out, ev_out, ffi.sizeof(ev_out))
end

local function tap(key)
    emit(EV_KEY, key, 1); emit(EV_SYN, 0, 0)
    C.usleep(30000)
    emit(EV_KEY, key, 0); emit(EV_SYN, 0, 0)
end

-- Nickel turns pages on arrow keys, KOReader on the Kobo button codes.
-- KOReader kills Nickel when it starts, so Nickel running means we're in the stock reader.
local function nickel_running()
    local p = io.popen("pidof nickel")
    local out = p:read("*a")
    p:close()
    return out:match("%d") ~= nil
end

-- The KOReader plugin pauses remapping with this flag instead of killing us,
-- so the virtual device KOReader has open never disappears under it.
local PAUSE_FLAG = "/tmp/shutter_remap.paused"

local function paused()
    local f = io.open(PAUSE_FLAG)
    if f then f:close() end
    return f ~= nil
end

local function page(forward)
    if paused() then return end
    if nickel_running() then
        tap(forward and KEY_RIGHT or KEY_LEFT)
    else
        tap(forward and KEY_F24 or KEY_F23)
    end
end

-- The event number changes every time the shutter reconnects.
local function find_device()
    local f = io.open("/proc/bus/input/devices")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    for block in text:gmatch("(.-)\n\n") do
        if block:find('N: Name="' .. DEVICE_NAME .. '"', 1, true) then
            local ev = block:match("Handlers=[^\n]*(event%d+)")
            if ev then return "/dev/input/" .. ev end
        end
    end
end

local function now_ms()
    local f = io.open("/proc/uptime")
    local up = f:read("*n")
    f:close()
    return up * 1000
end

local ev_in = ffi.new("struct input_event")
local pfd = ffi.new("struct pollfd[1]")

local function handle_device(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_NONBLOCK))
    if fd < 0 then return end
    -- Keep Nickel from also seeing the volume key.
    C.ioctl(fd, EVIOCGRAB, ffi.cast("int", 1))
    log("connected", path)
    local pressed_at, long_fired = nil, false
    pfd[0].fd, pfd[0].events = fd, POLLIN
    while true do
        local timeout = -1
        if pressed_at and not long_fired then
            timeout = math.max(0, math.floor(pressed_at + LONG_MS - now_ms()))
        end
        local r = C.poll(pfd, 1, timeout)
        if r == 0 then
            -- Held long enough: go back right away, ignore the release.
            page(false)
            long_fired = true
        elseif r > 0 then
            if bit.band(pfd[0].revents, POLLIN) == 0 then break end -- POLLERR/POLLHUP: device gone
            local n = C.read(fd, ev_in, ffi.sizeof(ev_in))
            if n ~= ffi.sizeof(ev_in) then break end
            if ev_in.type == EV_KEY and ev_in.code == KEY_VOLUMEUP then
                if ev_in.value == 1 then
                    pressed_at, long_fired = now_ms(), false
                elseif ev_in.value == 0 and pressed_at then
                    if not long_fired then page(true) end
                    pressed_at = nil
                end
            end
        end
    end
    C.close(fd)
    log("disconnected")
end

log("started")
while true do
    local path = find_device()
    if path then handle_device(path) end
    C.sleep(RESCAN_S)
end
