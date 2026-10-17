-- AB Shutter 3 remap: the Clara has no page-turn buttons, so KOReader skips
-- registering page-key handlers. Pretend it has keys so the remapped
-- RPgFwd/RPgBack (193/194) from the "Shutter Remap" uinput device turn pages.
local Device = require("device")
Device.hasKeys = function() return true end
