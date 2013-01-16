package.cpath = package.cpath .. ';../build/?.so'

local clang = require 'luaclang-parser'

-- from http://stevedonovan.github.com/Penlight/api/modules/pl.text.html#format_operator
do
    local format = string.format

    -- a more forgiving version of string.format, which applies
    -- tostring() to any value with a %s format.
    local function formatx (fmt,...)
        local args = {...}
        local i = 1
        for p in fmt:gmatch('%%.') do
            if p == '%s' and type(args[i]) ~= 'string' then
                args[i] = tostring(args[i])
            end
            i = i + 1
        end
        return format(fmt,unpack(args))
    end

    -- Note this goes further than the original, and will allow these cases:
    -- 1. a single value
    -- 2. a list of values
    getmetatable("").__mod = function(a, b)
        if b == nil then
            return a
        elseif type(b) == "table" then
            return formatx(a,unpack(b))
        else
            return formatx(a,b)
        end
    end
end

---[[
local DBG = function() end
--[=[]]
local DBG = print
--]=]

do
    local cache = setmetatable({}, {__mode="k"})
    function getExtent(file, fromRow, fromCol, toRow, toCol)
        if not file then
            DBG(file, fromRow, fromCol, toRow, toCol)
            return ''
        end
        if not cache[file] then
            local f = assert(io.open(file))
            local t, n = {}, 0
            for l in f:lines() do
                n = n + 1
                t[n] = l
            end
            cache[file] = t
        end
        local lines = cache[file]
        if not (lines and lines[fromRow] and lines[toRow]) then
            DBG('!!! Missing lines '..fromRow..'-'..toRow..' in file '..file)
            return ''
        end
        if fromRow == toRow then
            return lines[fromRow]:sub(fromCol, toCol-1)
        else
            local res = {}
            for i=fromRow, toRow do
                if i==fromRow then
                    res[#res+1] = lines[i]:sub(fromCol)
                elseif i==toRow then
                    res[#res+1] = lines[i]:sub(1,toCol-1)
                else
                    res[#res+1] = lines[i]
                end
            end
            return table.concat(res, '\n')
        end
    end
end

-- Create index
local index = clang.createIndex(false, true)

-- Create translation unit

local tu = assert(index:parse(arg))

-- write code

function findChildrenByType(cursor, type)
    local children, n = {}, 0
    local function finder(cur)
        for i,c in ipairs(cur:children()) do
            if c and (c:kind() == type) then
                n = n + 1
                children[n] = c
            end
            finder(c)
        end
   end
   finder(cursor)
   return children
end

function translateType(cur, typ)
    if not typ then
        typ = cur:type()
    end

    local typeKind = tostring(typ)
    if typeKind == 'Typedef' or typeKind == 'Record' then
        return typ:declaration():name()
    elseif typeKind == 'Pointer' then
        return translateType(cur, typ:pointee()) .. '*'
    elseif typeKind == 'LValueReference' then
        return translateType(cur, typ:pointee()) .. '&'
    elseif typeKind == 'Unexposed' then
        local def = getExtent(cur:location())
        DBG('!Unexposed!', def)
        return def
    else
        return typeKind
    end
end

local function trim(s)
 local from = s:match"^%s*()"
 local res = from > #s and "" or s:match(".*%S", from)
 return res
end

local dumpCode

local libname = arg[1]:gsub(".c", "")

local code = assert(io.open('code.c', 'w'))

code:write [[
#include "lua.h"
#include "lauxlib.h"

]]

local sf, pf = {}, {}

local function structFields(cur, name)
  sf[name] = {}
  fields = findChildrenByType(cur, "FieldDecl")
  for _, f in ipairs(fields) do
    sf[name][#sf[name] + 1] = f
    code:write("/* field " .. f:name() .. " */\n")
  end
end

local function parmFields(cur, name)
  pf[name] = {}
  fields = findChildrenByType(cur, "ParmDecl")
  for _, f in ipairs(fields) do
    pf[name][#pf[name] + 1] = f
    code:write("/* parm " .. f:name() .. " */\n")
  end
end

local kinds = {
  TranslationUnit = function(cur, name, text, children)
    for _, c in ipairs(children) do
      dumpCode(c)
    end
  end,
  TypedefDecl = function(cur, name, text, children)
    if name:sub(1, 2) == "__" then return end
    code:write(text .. ';\n')
    struct = findChildrenByType(cur, "StructDecl")
    if #struct > 0 then
      if #struct > 1 then print("???", #struct) end
      struct = struct[1]
      structFields(struct, name)
    end
  end,
  VarDecl = function(cur, name, text, children)
    code:write(text .. ';\n')
  end,
  StructDecl = function(cur, name, text, children)
    if name == "" then return end
    code:write(text .. ';\n')
    structFields(cur, name)
  end,
  FunctionDecl = function(cur, name, text, children)
    code:write(text .. ';\n')
    parmFields(cur, name)
  end,
}

dumpCode = function(cur)
    local tag = cur:kind()
    local name = trim(cur:name())
    local attr = ' name="' .. name .. '"'
    --local dname = trim(cur:displayName())
    --if dname ~= name then
    --    attr = attr .. ' display="' .. dname .. '"'
    --end
    local text = trim(getExtent(cur:location()))
    local children = cur:children()

    if kinds[tag] then kinds[tag](cur, name, text, children) end
end

dumpCode(tu:cursor())

code:write [[

/* output userdata for structs */

]]

-- how to handle C types

local typeHandlers = {
  Long = "LuaL_checkint",
  ULong = "LuaL_checkint",
  Int = "LuaL_checkint",
  UInt = "LuaL_checkint",
}

for k, t in pairs(sf) do
  -- create constructor for type
  local sk = "struct " .. k 
  code:write("static int new_" .. k .. "(lua_State *L) {\n")
  -- TODO accept table initializer
  code:write("  " .. sk .. " *a;\n")
  code:write("  a = (" .. sk .. " *) lua_newuserdata(L, sizeof(" .. sk .. "));\n")
  code:write('  luaL_getmetatable(L, "' .. libname .. "." .. k .. '");\n')
  code:write "  lua_setmetatable(L, -2);\n"
  code:write "  return 1;\n"
  code:write "}\n"
  code:write "\n"

  -- function to check userdata is this type and assign to a
  local check = '  ' .. sk .. ' *a = (' .. sk .. ' *) luaL_checkudata(L, 1, "' .. libname .. '.' .. k .. '");\n'

  -- set functions
  for f, ft in pairs(t) do
    local tp = translateType(ft)
    local name = ft:name()
    if name:sub(1, 2) == "__" then break end
    code:write("static int set_" .. k .. "_" .. name .. "(lua_State *L) {\n")
    code:write(check)
print(name, tp)
    code:write "}\n"
    code:write "\n"
  end
  -- get functions

  -- create metatable
  -- __index
  code:write("static const struct luaL_Reg mt_" .. k .. " [] = {\n")
  -- TODO change to __index and __newindex not set, get
  
  code:write "};\n"
end

-- output code for functions

code:write [[

/* register our module */

]]

code:write("static const struct luaL_Reg " .. libname .. "_mod [] = {\n")
-- output types
for k, t in pairs(sf) do
  code:write('  {"' .. k .. '_t", new_' .. k .. '},\n')
end
-- TODO output functions
code:write "  {NULL, NULL}\n"
code:write "};\n"
code:write "\n"
code:write("int luaopen_" .. libname .. "(lua_State *L) {\n")
for k, t in pairs(sf) do
  code:write('  luaL_newmetatable(L, "' .. libname .. "." .. k .. '");\n')
end
code:write('  luaL_register(L, "' .. libname .. '", ' .. libname .. '_mod);\n')
code:write "  return 1;\n"
code:write "}\n"
code:write "\n"

