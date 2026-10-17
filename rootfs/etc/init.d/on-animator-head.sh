
# Undo a NickelMenu failsafe left behind when Nickel was killed (e.g. by KOReader starting)
# within its first ~20s, which would otherwise hide NickelMenu until reinstalled.
NM_LIB="/usr/local/Kobo/imageformats/libnm.so"
if [ -f "${NM_LIB}.failsafe" ] && [ ! -f "${NM_LIB}" ] ; then
	mv "${NM_LIB}.failsafe" "${NM_LIB}"
fi

# Start the AB Shutter 3 page-turn remapper (also controllable from NickelMenu).
SHUTTER_LUA="/mnt/onboard/.adds/shutter/shutter_remap.lua"
if [ -f "${SHUTTER_LUA}" ] && ! kill -0 "$(cat /tmp/shutter_remap.pid 2>/dev/null)" 2>/dev/null ; then
	/mnt/onboard/.adds/koreader/luajit "${SHUTTER_LUA}" > /tmp/shutter_remap.log 2>&1 &
	echo $! > /tmp/shutter_remap.pid
fi
