
local stat = require "stat"

local st = stat.stat_t()

assert(type(st) == "userdata")

local mt = getmetatable(st)

assert(mt, "has a metatable")

st:set_st_size(3)
assert(st:st_size() == 3, "should have set value")

local ok, err = stat.stat("cindex.lua", st)
assert(st:st_size() == 12916, "cindex.lua is 12916 bytes long, got " .. st:st_size())

local ok, err = stat.stat("non existent file", st)
assert(ok == nil and err == "No such file or directory", "should got no such file")

