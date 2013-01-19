local clang = require 'luaclang-parser'

do
    local cache = setmetatable({}, {__mode="k"})
    function getExtent(file, fromRow, fromCol, toRow, toCol)
        if not file then
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

local function trim(s)
 local from = s:match"^%s*()"
 local res = from > #s and "" or s:match(".*%S", from)
 return res
end

function translateType(cur, typ)
    if not typ then
        typ = cur:type()
    end

    local tr_tb = {
      Int = "int",
      UInt = "unsigned int",
      Long = "long",
      ULong = "unsigned long",
      ["Char_S *"] = "const char *",
    }

    local function tr(d) return tr_tb[d] or d end 

    local typeKind = tostring(typ)
    if typeKind == 'Typedef' or typeKind == 'Record' then
        return typ:declaration():name()
    elseif typeKind == 'Pointer' then
        return tr(translateType(cur, typ:pointee()) .. ' *')
    elseif typeKind == 'LValueReference' then
        return translateType(cur, typ:pointee()) .. ' &'
    elseif typeKind == 'Unexposed' then
        local def = getExtent(cur:location())
        def = trim(def:gsub("%*.*", "")) -- change eg struct stat *buf to struct stat
        return tr(def)
    elseif typeKind == 'FunctionProto' then
        local def = getExtent(cur:location())
        def = trim(def:gsub("%s.+%(.*%)", "")) -- remove function name and args, just return type
        return tr(def)
    else
        return tr(typeKind)
    end
end

local dumpCode

local libname = arg[1]:gsub(".c", "")

local code = assert(io.open('code.c', 'w'))

code:write [[
#include "lua.h"
#include "lauxlib.h"
#include <errno.h>
#include <string.h>

]]

local sf, pf, funcs = {}, {}, {}

local function structFields(cur, name)
  sf[name] = {}
  fields = findChildrenByType(cur, "FieldDecl")
  for _, f in ipairs(fields) do
    if f:name():sub(1, 2) ~= "__" then
      sf[name][#sf[name] + 1] = f
    end
  end
end

local function parmFields(cur, name)
  pf[name] = {}
  funcs[name] = cur
  fields = findChildrenByType(cur, "ParmDecl")
  for _, f in ipairs(fields) do
    pf[name][#pf[name] + 1] = f
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
    code:write(text, ';\n')
    struct = findChildrenByType(cur, "StructDecl")
    if #struct > 0 then
      assert(#struct == 1)
      struct = struct[1]
      structFields(struct, name)
    end
  end,
  VarDecl = function(cur, name, text, children)
    code:write(text, ';\n')
  end,
  StructDecl = function(cur, name, text, children)
    if name == "" then return end
    code:write(text, ';\n\n')
    structFields(cur, name)
  end,
  FunctionDecl = function(cur, name, text, children)
    code:write(text, ';\n')
    parmFields(cur, name)
  end,
}

dumpCode = function(cur)
    local tag = cur:kind()
    local name = trim(cur:name())
    local attr = ' name="' .. name .. '"'
    local text = trim(getExtent(cur:location()))
    local children = cur:children()

    if kinds[tag] then kinds[tag](cur, name, text, children) end
end

dumpCode(tu:cursor())

code:write [[

/* output userdata for structs */

]]

-- how to handle C types

local function check_s(str)
  return function(s) return str .. "(L, " .. s .. ")" end
end

local function check_u(sk, k)
  return function(s) return '(' .. sk .. ') luaL_checkudata(L, ' .. s .. ', "' .. libname .. '.' .. k .. '")' end
end

local function opt(str, default)
  return function(s) return str .. "(L, " .. s .. ", " .. default .. ")" end
end

local typeHandlers = {
  int = {check = check_s "luaL_checkint", push = "lua_pushinteger", opt = opt("luaL_optint", 0)},
  ["unsigned int"] = {check = check_s "luaL_checkint", push = "lua_pushinteger", opt = opt("luaL_optint", 0)},
  -- TODO more work here for long values larger than 32 bits
  long = {check = check_s "luaL_checklong", push = "lua_pushinteger", opt = opt("luaL_optlong", 0)},
  ["unsigned long"] = {check = check_s "luaL_checklong", push = "lua_pushinteger", opt = opt("luaL_optlong", 0)},
  ["const char *"] = {check = check_s "luaL_checkstring", push = "lua_pushstring"},
}

for k, t in pairs(sf) do
  -- create constructor for type
  local sk = "struct " .. k
  local skk = sk .. " *"

  -- add a type handler so we can deal with functions that use this type
  typeHandlers[skk] = {check = check_u(skk, k)}

  code:write("static int new_", k, "(lua_State *L) {\n")
  code:write("  ", skk, " a = (", skk, ") lua_newuserdata(L, sizeof(", sk, "));\n")
  code:write('  luaL_getmetatable(L, "', libname, ".", k, '");\n')
  code:write "  lua_setmetatable(L, -2);\n"

  -- TODO accept initializers

  code:write "  return 1;\n"
  code:write "}\n"
  code:write "\n"

  -- check userdata is this type and assign to a
  local function check(s) return skk .. 'a = ' .. check_u(skk, k)(s) ..';\n' end

  -- set functions
  for _, ft in pairs(t) do
    local tp = translateType(ft)
    local th = assert(typeHandlers[tp], "Cannot handle type " .. tp)
    local name = ft:name()
    code:write("static int set_", k, "_", name, "(lua_State *L) {\n")
    code:write("  ", check(1))
    code:write("  ", tp, " v = ", th.check(2), ";\n")
    code:write("  a->", name, " = v;\n")
    code:write "  return 0;\n"
    code:write "}\n"
    code:write "\n"
  end
  -- get functions
  for _, ft in pairs(t) do
    local tp = translateType(ft)
    local th = assert(typeHandlers[tp], "Cannot handle type " .. tp)
    local name = ft:name()
    code:write("static int get_", k, "_", name, "(lua_State *L) {\n")
    code:write("  ", check(1))
    code:write("  ", tp, " v = a->", name, ";\n")
    code:write("  ", th.push, "(L, v);\n")
    code:write "  return 1;\n"
    code:write "}\n"
    code:write "\n"
  end
  -- create metatable
  code:write("static const struct luaL_Reg mt_", k, " [] = {\n")
  -- get functions
  for _, ft in pairs(t) do
    local name = ft:name()
    code:write('  {"', name, '", get_', k, '_', name, '},\n')
  end
  -- set functions
  for _, ft in pairs(t) do
    local name = ft:name()
    code:write('  {"set_', name, '", set_', k, '_', name, '},\n')
  end
  code:write "  {NULL, NULL}\n"
  code:write "};\n\n"
end

-- output code for functions
for k, as in pairs(pf) do
  code:write("static int ", k, "_f(lua_State *L) {\n")
  for n, a in ipairs(as) do
    local tp = translateType(a)
    local name = a:name()
    local th = assert(typeHandlers[tp], "Cannot handle type " .. tp)
    code:write("  ", tp, " ", name, " = ", th.check(n), ";\n")
  end
  local tp = translateType(funcs[k])
  local name = funcs[k]:name()
  code:write("  ", tp, " ret = ", name, "(")
  for n, a in ipairs(as) do
    if n ~= 1 then code:write ", " end
    code:write(a:name())
  end
  code:write ");\n"
  code:write "  if (ret == -1) {\n"
  code:write "    lua_pushnil(L);\n"
  code:write "    lua_pushstring(L, strerror(errno));\n"
  code:write "    return 2;\n"
  code:write "  }\n"
  code:write "  lua_pushnumber(L, ret);\n"
  code:write "  return 1;\n"
  code:write "};\n\n"
end

-- register module

code:write [[

/* register our module */

]]

code:write("static const struct luaL_Reg ", libname, "_mod [] = {\n")
-- output types
for k, t in pairs(sf) do
  code:write('  {"', k, '_t", new_', k, '},\n')
end
for k, t in pairs(funcs) do
  code:write('  {"', k, '", ', k, '_f},\n')
end
code:write "  {NULL, NULL}\n"
code:write "};\n"
code:write "\n"
code:write("int luaopen_", libname, "(lua_State *L) {\n")
for k, t in pairs(sf) do
  code:write('  luaL_newmetatable(L, "', libname, ".", k, '");\n')
  code:write "  lua_pushvalue(L, -1);\n"
  code:write '  lua_setfield(L, -2, "__index");\n'
  code:write("  luaL_register(L, NULL, mt_", k, ");\n")
end
code:write('  luaL_register(L, "', libname, '", ', libname, '_mod);\n')
code:write "  return 1;\n"
code:write "}\n"
code:write "\n"

