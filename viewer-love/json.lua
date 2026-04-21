--[[
  json.lua -- Minimal JSON encoder/decoder for the reactjit bridge.

  Used by bridge_quickjs.lua to decode mutation commands sent as JSON strings
  from the JS reconciler, avoiding QuickJS GC race conditions during FFI
  object property enumeration.

  Based on rxi/json.lua (MIT license), stripped to essentials.
]]

local json = { _version = "0.1.0" }

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local encode

local escape_char_map = {
  [ "\\" ] = "\\\\",
  [ "\"" ] = "\\\"",
  [ "\b" ] = "\\b",
  [ "\f" ] = "\\f",
  [ "\n" ] = "\\n",
  [ "\r" ] = "\\r",
  [ "\t" ] = "\\t",
}

local function escape_char(c)
  return escape_char_map[c] or string.format("\\u%04x", c:byte())
end

local function encode_nil()
  return "null"
end

local function encode_table(val, stack)
  local res = {}
  stack = stack or {}

  if stack[val] then error("circular reference") end
  stack[val] = true

  if rawget(val, 1) ~= nil or next(val) == nil then
    -- Treat as array (or empty table → empty array)
    local n = #val
    for i = 1, n do
      res[i] = encode(val[i], stack)
    end
    stack[val] = nil
    return "[" .. table.concat(res, ",") .. "]"
  else
    -- Object
    local i = 0
    for k, v in pairs(val) do
      i = i + 1
      res[i] = encode(tostring(k), stack) .. ":" .. encode(v, stack)
    end
    stack[val] = nil
    return "{" .. table.concat(res, ",") .. "}"
  end
end

encode = function(val, stack)
  local t = type(val)
  if t == "table" then
    return encode_table(val, stack)
  elseif t == "string" then
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
  elseif t == "number" then
    if val ~= val then return "null" end  -- NaN
    if val >= math.huge then return "1e999" end
    if val <= -math.huge then return "-1e999" end
    return string.format("%.14g", val)
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "nil" then
    return "null"
  else
    error("unexpected type '" .. t .. "'")
  end
end

function json.encode(val)
  return encode(val)
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local decode

local literal_map = {
  ["true"]  = true,
  ["false"] = false,
  ["null"]  = nil,  -- won't actually store nil, handled specially
}

local function create_set(...)
  local s = {}
  for i = 1, select("#", ...) do s[select(i, ...)] = true end
  return s
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local escape_char_map_inv = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function next_char(str, idx, set, negate)
  for i = idx, #str do
    if set[str:sub(i, i)] ~= negate then return i end
  end
  return #str + 1
end

local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
    col_count = col_count + 1
    if str:sub(i, i) == "\n" then
      line_count = line_count + 1
      col_count = 1
    end
  end
  error(string.format("%s at line %d col %d", msg, line_count, col_count))
end

local function codepoint_to_utf8(n)
  if n <= 0x7f then
    return string.char(n)
  elseif n <= 0x7ff then
    return string.char(0xc0 + math.floor(n / 64), 0x80 + (n % 64))
  elseif n <= 0xffff then
    return string.char(0xe0 + math.floor(n / 4096), 0x80 + math.floor((n % 4096) / 64), 0x80 + (n % 64))
  elseif n <= 0x10ffff then
    return string.char(
      0xf0 + math.floor(n / 262144),
      0x80 + math.floor((n % 262144) / 4096),
      0x80 + math.floor((n % 4096) / 64),
      0x80 + (n % 64))
  end
  error("invalid unicode codepoint")
end

local function parse_unicode_escape(s, i)
  local n1 = tonumber(s:sub(i, i + 3), 16)
  if not n1 then decode_error(s, i, "invalid unicode escape") end
  -- Surrogate pair?
  if n1 >= 0xD800 and n1 <= 0xDBFF then
    if s:sub(i + 4, i + 5) ~= "\\u" then decode_error(s, i, "missing surrogate pair") end
    local n2 = tonumber(s:sub(i + 6, i + 9), 16)
    if not n2 or n2 < 0xDC00 or n2 > 0xDFFF then decode_error(s, i, "invalid surrogate pair") end
    n1 = (n1 - 0xD800) * 0x400 + (n2 - 0xDC00) + 0x10000
    return codepoint_to_utf8(n1), i + 10
  end
  return codepoint_to_utf8(n1), i + 4
end

local function parse_string(str, i)
  local res = {}
  local j = i + 1
  local k = j

  while j <= #str do
    local x = str:byte(j)

    if x < 32 then
      decode_error(str, j, "control character in string")
    elseif x == 92 then -- backslash
      res[#res + 1] = str:sub(k, j - 1)
      j = j + 1
      local c = str:sub(j, j)
      if c == "u" then
        local s, nj = parse_unicode_escape(str, j + 1)
        res[#res + 1] = s
        j = nj
        k = j
      else
        if not escape_chars[c] then decode_error(str, j, "invalid escape char '" .. c .. "'") end
        res[#res + 1] = escape_char_map_inv[c]
        j = j + 1
        k = j
      end
    elseif x == 34 then -- quote
      res[#res + 1] = str:sub(k, j - 1)
      return table.concat(res), j + 1
    else
      j = j + 1
    end
  end

  decode_error(str, i, "expected closing quote for string")
end

local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then decode_error(str, i, "invalid number '" .. s .. "'") end
  return n, x
end

local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if word == "true" then return true, x end
  if word == "false" then return false, x end
  if word == "null" then return nil, x end
  decode_error(str, i, "invalid literal '" .. word .. "'")
end

local function parse_array(str, i)
  local res = {}
  local n = 0
  i = i + 1
  while true do
    local x
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) == "]" then return res, i + 1 end
    x, i = decode(str, i)
    n = n + 1
    res[n] = x
    i = next_char(str, i, space_chars, true)
    local c = str:sub(i, i)
    if c == "]" then return res, i + 1 end
    if c ~= "," then decode_error(str, i, "expected ']' or ','") end
    i = i + 1
  end
end

local function parse_object(str, i)
  local res = {}
  i = i + 1
  while true do
    local key, val
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) == "}" then return res, i + 1 end
    if str:sub(i, i) ~= '"' then decode_error(str, i, "expected string for key") end
    key, i = parse_string(str, i)
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) ~= ":" then decode_error(str, i, "expected ':' after key") end
    i = next_char(str, i + 1, space_chars, true)
    val, i = decode(str, i)
    res[key] = val
    i = next_char(str, i, space_chars, true)
    local c = str:sub(i, i)
    if c == "}" then return res, i + 1 end
    if c ~= "," then decode_error(str, i, "expected '}' or ','") end
    i = i + 1
  end
end

decode = function(str, idx)
  idx = idx or next_char(str, 1, space_chars, true)
  local c = str:sub(idx, idx)
  if c == '"' then return parse_string(str, idx) end
  if c == "{" then return parse_object(str, idx) end
  if c == "[" then return parse_array(str, idx) end
  if c == "-" or (c >= "0" and c <= "9") then return parse_number(str, idx) end
  return parse_literal(str, idx)
end

function json.decode(str)
  if type(str) ~= "string" then
    error("expected argument of type string, got " .. type(str))
  end
  local result, _ = decode(str)
  return result
end

return json
