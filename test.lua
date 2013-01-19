
local stat = require "stat"

local st = stat.stat_t()

assert(type(st) == "userdata")

local mt = getmetatable(st)

assert(mt, "has a metatable")

st:set_st_size(3)
assert(st:st_size() == 3, "should have set value")

local e = stat.example_t()

e:set_x(4)
assert(e:x() == 4, "should have set value")

