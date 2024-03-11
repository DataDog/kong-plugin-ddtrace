-- MessagePack encoder for datadog trace payloads. Original implementation:
-- lua-MessagePack : <https://fperrad.frama.io/lua-MessagePack/>
--
-- Modified to encode uint64_t values from FFI, and removed decoding functionality
-- that is not required for datadog tracing.
--
-- lua-MessagePack License
-- --------------------------
--
-- lua-MessagePack is licensed under the terms of the MIT/X11 license reproduced below.
--
-- ===============================================================================
--
-- Copyright (C) 2012-2019 Francois Perrad.
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- ===============================================================================
--

-- Exclude this code from test coverage, as it would be if it were a separate module.
-- luacov: disable
local ffi = require("ffi")

local maxinteger
local mininteger

local assert = assert
local error = error
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring
local type = type
local char = require("string").char
local floor = require("math").floor
local tointeger = require("math").tointeger or floor
local frexp = require("math").frexp or require("mathx").frexp
local ldexp = require("math").ldexp or require("mathx").ldexp
local huge = require("math").huge
local tconcat = require("table").concat
local format = require("string").format

local m = {}

local function hexadump(s)
    return (s:gsub(".", function(c)
        return format("%02X ", c:byte())
    end))
end
m.hexadump = hexadump

local function argerror(caller, narg, extramsg)
    error("bad argument #" .. tostring(narg) .. " to " .. caller .. " (" .. extramsg .. ")")
end

local packers = setmetatable({}, {
    __index = function(t, k)
        if k == 1 then
            return
        end -- allows ipairs
        error("pack '" .. k .. "' is unimplemented")
    end,
})
m.packers = packers

packers["nil"] = function(buffer)
    buffer[#buffer + 1] = char(0xC0) -- nil
end

packers["boolean"] = function(buffer, bool)
    if bool then
        buffer[#buffer + 1] = char(0xC3) -- true
    else
        buffer[#buffer + 1] = char(0xC2) -- false
    end
end

packers["string_compat"] = function(buffer, str)
    local n = #str
    if n <= 0x1F then
        buffer[#buffer + 1] = char(0xA0 + n) -- fixstr
    elseif n <= 0xFFFF then
        buffer[#buffer + 1] = char(
            0xDA, -- str16
            floor(n / 0x100),
            n % 0x100
        )
    elseif n <= 4294967295.0 then
        buffer[#buffer + 1] = char(
            0xDB, -- str32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100
        )
    else
        error("overflow in pack 'string_compat'")
    end
    buffer[#buffer + 1] = str
end

packers["_string"] = function(buffer, str)
    local n = #str
    if n <= 0x1F then
        buffer[#buffer + 1] = char(0xA0 + n) -- fixstr
    elseif n <= 0xFF then
        buffer[#buffer + 1] = char(
            0xD9, -- str8
            n
        )
    elseif n <= 0xFFFF then
        buffer[#buffer + 1] = char(
            0xDA, -- str16
            floor(n / 0x100),
            n % 0x100
        )
    elseif n <= 4294967295.0 then
        buffer[#buffer + 1] = char(
            0xDB, -- str32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100
        )
    else
        error("overflow in pack 'string'")
    end
    buffer[#buffer + 1] = str
end

packers["binary"] = function(buffer, str)
    local n = #str
    if n <= 0xFF then
        buffer[#buffer + 1] = char(
            0xC4, -- bin8
            n
        )
    elseif n <= 0xFFFF then
        buffer[#buffer + 1] = char(
            0xC5, -- bin16
            floor(n / 0x100),
            n % 0x100
        )
    elseif n <= 4294967295.0 then
        buffer[#buffer + 1] = char(
            0xC6, -- bin32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100
        )
    else
        error("overflow in pack 'binary'")
    end
    buffer[#buffer + 1] = str
end

local set_string = function(str)
    if str == "string_compat" then
        packers["string"] = packers["string_compat"]
    elseif str == "string" then
        packers["string"] = packers["_string"]
    elseif str == "binary" then
        packers["string"] = packers["binary"]
    else
        argerror("set_string", 1, "invalid option '" .. str .. "'")
    end
end
m.set_string = set_string

packers["map"] = function(buffer, tbl, n)
    if n <= 0x0F then
        buffer[#buffer + 1] = char(0x80 + n) -- fixmap
    elseif n <= 0xFFFF then
        buffer[#buffer + 1] = char(
            0xDE, -- map16
            floor(n / 0x100),
            n % 0x100
        )
    elseif n <= 4294967295.0 then
        buffer[#buffer + 1] = char(
            0xDF, -- map32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100
        )
    else
        error("overflow in pack 'map'")
    end
    for k, v in pairs(tbl) do
        packers[type(k)](buffer, k)
        packers[type(v)](buffer, v)
    end
end

packers["array"] = function(buffer, tbl, n)
    if n <= 0x0F then
        buffer[#buffer + 1] = char(0x90 + n) -- fixarray
    elseif n <= 0xFFFF then
        buffer[#buffer + 1] = char(
            0xDC, -- array16
            floor(n / 0x100),
            n % 0x100
        )
    elseif n <= 4294967295.0 then
        buffer[#buffer + 1] = char(
            0xDD, -- array32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100
        )
    else
        error("overflow in pack 'array'")
    end
    for i = 1, n do
        local v = tbl[i]
        packers[type(v)](buffer, v)
    end
end

local arrayheader = function(n)
    if n <= 0x0F then
        return char(0x90 + n) -- fixarray
    elseif n <= 0xFFFF then
        return char(
            0xDC, -- array16
            floor(n / 0x100),
            n % 0x100
        )
    elseif n <= 4294967295.0 then
        return char(
            0xDD, -- array32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100
        )
    else
        error("overflow in arrayheader")
    end
end
m.arrayheader = arrayheader

local set_array = function(array)
    if array == "without_hole" then
        packers["_table"] = function(buffer, tbl)
            local is_map, n, max = false, 0, 0
            for k in pairs(tbl) do
                if type(k) == "number" and k > 0 then
                    if k > max then
                        max = k
                    end
                else
                    is_map = true
                end
                n = n + 1
            end
            if max ~= n then -- there are holes
                is_map = true
            end
            if is_map then
                packers["map"](buffer, tbl, n)
            else
                packers["array"](buffer, tbl, n)
            end
        end
    elseif array == "with_hole" then
        packers["_table"] = function(buffer, tbl)
            local is_map, n, max = false, 0, 0
            for k in pairs(tbl) do
                if type(k) == "number" and k > 0 then
                    if k > max then
                        max = k
                    end
                else
                    is_map = true
                end
                n = n + 1
            end
            if is_map then
                packers["map"](buffer, tbl, n)
            else
                packers["array"](buffer, tbl, max)
            end
        end
    elseif array == "always_as_map" then
        packers["_table"] = function(buffer, tbl)
            local n = 0
            for k in pairs(tbl) do
                n = n + 1
            end
            packers["map"](buffer, tbl, n)
        end
    else
        argerror("set_array", 1, "invalid option '" .. array .. "'")
    end
end
m.set_array = set_array

packers["table"] = function(buffer, tbl)
    packers["_table"](buffer, tbl)
end

packers["unsigned"] = function(buffer, n)
    if n >= 0 then
        if n <= 0x7F then
            buffer[#buffer + 1] = char(n) -- fixnum_pos
        elseif n <= 0xFF then
            buffer[#buffer + 1] = char(
                0xCC, -- uint8
                n
            )
        elseif n <= 0xFFFF then
            buffer[#buffer + 1] = char(
                0xCD, -- uint16
                floor(n / 0x100),
                n % 0x100
            )
        elseif n <= 4294967295.0 then
            buffer[#buffer + 1] = char(
                0xCE, -- uint32
                floor(n / 0x1000000),
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        else
            buffer[#buffer + 1] = char(
                0xCF, -- uint64
                0, -- only 53 bits from double
                floor(n / 0x1000000000000) % 0x100,
                floor(n / 0x10000000000) % 0x100,
                floor(n / 0x100000000) % 0x100,
                floor(n / 0x1000000) % 0x100,
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        end
    else
        if n >= -0x20 then
            buffer[#buffer + 1] = char(0x100 + n) -- fixnum_neg
        elseif n >= -0x80 then
            buffer[#buffer + 1] = char(
                0xD0, -- int8
                0x100 + n
            )
        elseif n >= -0x8000 then
            n = 0x10000 + n
            buffer[#buffer + 1] = char(
                0xD1, -- int16
                floor(n / 0x100),
                n % 0x100
            )
        elseif n >= -0x80000000 then
            n = 4294967296.0 + n
            buffer[#buffer + 1] = char(
                0xD2, -- int32
                floor(n / 0x1000000),
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        else
            buffer[#buffer + 1] = char(
                0xD3, -- int64
                0xFF, -- only 53 bits from double
                floor(n / 0x1000000000000) % 0x100,
                floor(n / 0x10000000000) % 0x100,
                floor(n / 0x100000000) % 0x100,
                floor(n / 0x1000000) % 0x100,
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        end
    end
end

packers["signed"] = function(buffer, n)
    if n >= 0 then
        if n <= 0x7F then
            buffer[#buffer + 1] = char(n) -- fixnum_pos
        elseif n <= 0x7FFF then
            buffer[#buffer + 1] = char(
                0xD1, -- int16
                floor(n / 0x100),
                n % 0x100
            )
        elseif n <= 0x7FFFFFFF then
            buffer[#buffer + 1] = char(
                0xD2, -- int32
                floor(n / 0x1000000),
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        else
            buffer[#buffer + 1] = char(
                0xD3, -- int64
                0, -- only 53 bits from double
                floor(n / 0x1000000000000) % 0x100,
                floor(n / 0x10000000000) % 0x100,
                floor(n / 0x100000000) % 0x100,
                floor(n / 0x1000000) % 0x100,
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        end
    else
        if n >= -0x20 then
            buffer[#buffer + 1] = char(0xE0 + 0x20 + n) -- fixnum_neg
        elseif n >= -0x80 then
            buffer[#buffer + 1] = char(
                0xD0, -- int8
                0x100 + n
            )
        elseif n >= -0x8000 then
            n = 0x10000 + n
            buffer[#buffer + 1] = char(
                0xD1, -- int16
                floor(n / 0x100),
                n % 0x100
            )
        elseif n >= -0x80000000 then
            n = 4294967296.0 + n
            buffer[#buffer + 1] = char(
                0xD2, -- int32
                floor(n / 0x1000000),
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        else
            buffer[#buffer + 1] = char(
                0xD3, -- int64
                0xFF, -- only 53 bits from double
                floor(n / 0x1000000000000) % 0x100,
                floor(n / 0x10000000000) % 0x100,
                floor(n / 0x100000000) % 0x100,
                floor(n / 0x1000000) % 0x100,
                floor(n / 0x10000) % 0x100,
                floor(n / 0x100) % 0x100,
                n % 0x100
            )
        end
    end
end

local set_integer = function(integer)
    if integer == "unsigned" then
        packers["integer"] = packers["unsigned"]
    elseif integer == "signed" then
        packers["integer"] = packers["signed"]
    else
        argerror("set_integer", 1, "invalid option '" .. integer .. "'")
    end
end
m.set_integer = set_integer

packers["float"] = function(buffer, n)
    local sign = 0
    if n < 0.0 then
        sign = 0x80
        n = -n
    end
    local mant, expo = frexp(n)
    if mant ~= mant then
        buffer[#buffer + 1] = char(
            0xCA, -- nan
            0xFF,
            0x88,
            0x00,
            0x00
        )
    elseif mant == huge or expo > 0x80 then
        if sign == 0 then
            buffer[#buffer + 1] = char(
                0xCA, -- inf
                0x7F,
                0x80,
                0x00,
                0x00
            )
        else
            buffer[#buffer + 1] = char(
                0xCA, -- -inf
                0xFF,
                0x80,
                0x00,
                0x00
            )
        end
    elseif (mant == 0.0 and expo == 0) or expo < -0x7E then
        buffer[#buffer + 1] = char(
            0xCA, -- zero
            sign,
            0x00,
            0x00,
            0x00
        )
    else
        expo = expo + 0x7E
        mant = floor((mant * 2.0 - 1.0) * ldexp(0.5, 24))
        buffer[#buffer + 1] = char(
            0xCA,
            sign + floor(expo / 0x2),
            (expo % 0x2) * 0x80 + floor(mant / 0x10000),
            floor(mant / 0x100) % 0x100,
            mant % 0x100
        )
    end
end

packers["double"] = function(buffer, n)
    local sign = 0
    if n < 0.0 then
        sign = 0x80
        n = -n
    end
    local mant, expo = frexp(n)
    if mant ~= mant then
        buffer[#buffer + 1] = char(
            0xCB, -- nan
            0xFF,
            0xF8,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00
        )
    elseif mant == huge or expo > 0x400 then
        if sign == 0 then
            buffer[#buffer + 1] = char(
                0xCB, -- inf
                0x7F,
                0xF0,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00
            )
        else
            buffer[#buffer + 1] = char(
                0xCB, -- -inf
                0xFF,
                0xF0,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00
            )
        end
    elseif (mant == 0.0 and expo == 0) or expo < -0x3FE then
        buffer[#buffer + 1] = char(
            0xCB, -- zero
            sign,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00
        )
    else
        expo = expo + 0x3FE
        mant = floor((mant * 2.0 - 1.0) * ldexp(0.5, 53))
        buffer[#buffer + 1] = char(
            0xCB,
            sign + floor(expo / 0x10),
            (expo % 0x10) * 0x10 + floor(mant / 0x1000000000000),
            floor(mant / 0x10000000000) % 0x100,
            floor(mant / 0x100000000) % 0x100,
            floor(mant / 0x1000000) % 0x100,
            floor(mant / 0x10000) % 0x100,
            floor(mant / 0x100) % 0x100,
            mant % 0x100
        )
    end
end

local set_number = function(number)
    if number == "float" then
        packers["number"] = function(buffer, n)
            if floor(n) == n and n < maxinteger and n > mininteger then
                packers["integer"](buffer, n)
            else
                packers["float"](buffer, n)
            end
        end
    elseif number == "double" then
        packers["number"] = function(buffer, n)
            if floor(n) == n and n < maxinteger and n > mininteger then
                packers["integer"](buffer, n)
            else
                packers["double"](buffer, n)
            end
        end
    else
        argerror("set_number", 1, "invalid option '" .. number .. "'")
    end
end
m.set_number = set_number

for k = 0, 4 do
    local n = tointeger(2 ^ k)
    local fixext = 0xD4 + k
    packers["fixext" .. tostring(n)] = function(buffer, tag, data)
        assert(#data == n, "bad length for fixext" .. tostring(n))
        buffer[#buffer + 1] = char(fixext, tag < 0 and tag + 0x100 or tag)
        buffer[#buffer + 1] = data
    end
end

packers["ext"] = function(buffer, tag, data)
    local n = #data
    if n <= 0xFF then
        buffer[#buffer + 1] = char(
            0xC7, -- ext8
            n,
            tag < 0 and tag + 0x100 or tag
        )
    elseif n <= 0xFFFF then
        buffer[#buffer + 1] = char(
            0xC8, -- ext16
            floor(n / 0x100),
            n % 0x100,
            tag < 0 and tag + 0x100 or tag
        )
    elseif n <= 4294967295.0 then
        buffer[#buffer + 1] = char(
            0xC9, -- ext&32
            floor(n / 0x1000000),
            floor(n / 0x10000) % 0x100,
            floor(n / 0x100) % 0x100,
            n % 0x100,
            tag < 0 and tag + 0x100 or tag
        )
    else
        error("overflow in pack 'ext'")
    end
    buffer[#buffer + 1] = data
end

local uint64_t = ffi.typeof("uint64_t")
local int64_t = ffi.typeof("int64_t")

packers["cdata"] = function(buffer, cdata)
    if ffi.istype(uint64_t, cdata) then
        buffer[#buffer + 1] = char(
            0xCF, -- uint64
            tonumber(bit.band(bit.rshift(cdata, 56), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 48), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 40), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 32), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 24), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 16), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 8), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 0), 0xFFULL))
        )
    elseif ffi.istype(int64_t, cdata) then
        buffer[#buffer + 1] = char(
            0xd3, -- int64
            tonumber(bit.band(bit.rshift(cdata, 56), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 48), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 40), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 32), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 24), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 16), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 8), 0xFFULL)),
            tonumber(bit.band(bit.rshift(cdata, 0), 0xFFULL))
        )
    else
        error("can only encode cdata with type uint64_t or int64_t")
    end
end

function m.pack(data)
    local buffer = {}
    packers[type(data)](buffer, data)
    return tconcat(buffer)
end

set_string("string_compat")
set_integer("unsigned")
maxinteger = 9007199254740991
mininteger = -maxinteger
set_number("double")
set_array("with_hole")

m._VERSION = "0.5.2"
m._DESCRIPTION = "lua-MessagePack : a pure Lua implementation"
m._COPYRIGHT = "Copyright (c) 2012-2019 Francois Perrad"
return m
--
-- This library is licensed under the terms of the MIT/X11 license,
-- like Lua itself.
--
