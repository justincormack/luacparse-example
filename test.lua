
local stat = require "stat"

local st = stat.stat_t()

print(type(st))

local mt = getmetatable(st)

assert(mt, "has a metatable")

