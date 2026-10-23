local M = {}
local array_metatable = {}
local null_value = setmetatable({}, { __metatable = "json.null" })

function M.array(value)
    return setmetatable(value or {}, array_metatable)
end

function M.is_array(value)
    return type(value) == "table" and getmetatable(value) == array_metatable
end

function M.is_null(value)
    return value == null_value
end

M.null = null_value

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function utf8_valid(value)
    local index, length = 1, #value
    while index <= length do
        local first = value:byte(index)
        if first < 0x80 then
            index = index + 1
        elseif first >= 0xc2 and first <= 0xdf then
            local second = value:byte(index + 1)
            if not second or second < 0x80 or second > 0xbf then return false end
            index = index + 2
        elseif first >= 0xe0 and first <= 0xef then
            local second, third = value:byte(index + 1), value:byte(index + 2)
            if not second or not third or third < 0x80 or third > 0xbf then return false end
            if first == 0xe0 then
                if second < 0xa0 or second > 0xbf then return false end
            elseif first == 0xed then
                if second < 0x80 or second > 0x9f then return false end
            elseif second < 0x80 or second > 0xbf then
                return false
            end
            index = index + 3
        elseif first >= 0xf0 and first <= 0xf4 then
            local second, third, fourth = value:byte(index + 1), value:byte(index + 2), value:byte(index + 3)
            if not second or not third or not fourth or
               third < 0x80 or third > 0xbf or fourth < 0x80 or fourth > 0xbf then
                return false
            end
            if first == 0xf0 then
                if second < 0x90 or second > 0xbf then return false end
            elseif first == 0xf4 then
                if second < 0x80 or second > 0x8f then return false end
            elseif second < 0x80 or second > 0xbf then
                return false
            end
            index = index + 4
        else
            return false
        end
    end
    return true
end

local function encode_string(value, binary_safe)
    if binary_safe and not utf8_valid(value) then
        local out = { '"' }
        for index = 1, #value do
            local byte = value:byte(index)
            local char = value:sub(index, index)
            if escapes[char] then
                out[#out + 1] = escapes[char]
            elseif byte < 0x20 then
                out[#out + 1] = string.format("\\u%04x", byte)
            elseif byte >= 0x80 then
                out[#out + 1] = string.format("\\udc%02x", byte)
            else
                out[#out + 1] = char
            end
        end
        out[#out + 1] = '"'
        return table.concat(out)
    end
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(value)
    if M.is_array(value) then return true end
    local count, max = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
        if key > max then max = key end
    end
    return count > 0 and count == max
end

local function encode_value(value, stack, binary_safe)
    if value == null_value then return "null" end
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "invalid JSON number")
        return string.format("%.17g", value)
    end
    if kind == "string" then return encode_string(value, binary_safe) end
    assert(kind == "table", "unsupported JSON value: " .. kind)
    assert(not stack[value], "cyclic JSON value")
    stack[value] = true
    local out = {}
    if is_array(value) then
        for i = 1, #value do out[i] = encode_value(value[i], stack, binary_safe) end
        stack[value] = nil
        return "[" .. table.concat(out, ",") .. "]"
    end
    for key, item in pairs(value) do
        assert(type(key) == "string", "JSON object keys must be strings")
        out[#out + 1] = encode_string(key, binary_safe) .. ":" .. encode_value(item, stack, binary_safe)
    end
    stack[value] = nil
    return "{" .. table.concat(out, ",") .. "}"
end

function M.encode(value)
    return encode_value(value, {}, false)
end

-- Internal persistence only: invalid UTF-8 bytes become unpaired low-surrogate
-- escapes and must be read with decode_binary_safe to recover their raw values.
function M.encode_binary_safe(value)
    return encode_value(value, {}, true)
end

local function utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
    end
    if code < 0x10000 then
        return string.char(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
    end
    return string.char(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
end

local function decode(source, binary_safe)
    local pos, length = 1, #source
    local function whitespace()
        while pos <= length and source:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function parse_string()
        assert(source:sub(pos, pos) == '"', "expected JSON string")
        pos = pos + 1
        local out, start = {}, pos
        local function append_raw_segment()
            local segment = source:sub(start, pos - 1)
            if binary_safe then
                assert(utf8_valid(segment), "invalid persisted JSON UTF-8")
                assert(not segment:find("[%z\1-\31]"), "unescaped persisted JSON control byte")
            end
            out[#out + 1] = segment
        end
        while pos <= length do
            local c = source:sub(pos, pos)
            if c == '"' then
                append_raw_segment()
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                append_raw_segment()
                pos = pos + 1
                local esc = source:sub(pos, pos)
                local simple = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
                if simple[esc] then
                    out[#out + 1] = simple[esc]
                    pos = pos + 1
                elseif esc == "u" then
                    local hex = source:sub(pos + 1, pos + 4)
                    local code = tonumber(hex, 16)
                    assert(code, "invalid JSON unicode escape")
                    pos = pos + 5
                    if binary_safe and code >= 0xdc80 and code <= 0xdcff then
                        out[#out + 1] = string.char(code - 0xdc00)
                    else
                        if code >= 0xd800 and code <= 0xdbff and source:sub(pos, pos + 1) == "\\u" then
                            local low = tonumber(source:sub(pos + 2, pos + 5), 16)
                            if low and low >= 0xdc00 and low <= 0xdfff then
                                code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00
                                pos = pos + 6
                            end
                        end
                        if binary_safe then
                            assert(code < 0xd800 or code > 0xdfff, "invalid persisted JSON surrogate escape")
                        end
                        out[#out + 1] = utf8(code)
                    end
                else
                    error("invalid JSON escape")
                end
                start = pos
            else
                pos = pos + 1
            end
        end
        error("unterminated JSON string")
    end

    local parse_value
    parse_value = function()
        whitespace()
        local c = source:sub(pos, pos)
        if c == '"' then return parse_string() end
        if c == "{" then
            pos = pos + 1
            whitespace()
            local out = {}
            if source:sub(pos, pos) == "}" then pos = pos + 1; return out end
            while true do
                whitespace()
                local key = parse_string()
                whitespace()
                assert(source:sub(pos, pos) == ":", "expected JSON colon")
                pos = pos + 1
                out[key] = parse_value()
                whitespace()
                local sep = source:sub(pos, pos)
                pos = pos + 1
                if sep == "}" then return out end
                assert(sep == ",", "expected JSON object separator")
            end
        end
        if c == "[" then
            pos = pos + 1
            whitespace()
            local out = M.array()
            if source:sub(pos, pos) == "]" then pos = pos + 1; return out end
            while true do
                out[#out + 1] = parse_value()
                whitespace()
                local sep = source:sub(pos, pos)
                pos = pos + 1
                if sep == "]" then return out end
                assert(sep == ",", "expected JSON array separator")
            end
        end
        local literals = { ["true"] = true, ["false"] = false }
        for word, value in pairs(literals) do
            if source:sub(pos, pos + #word - 1) == word then
                pos = pos + #word
                return value
            end
        end
        if source:sub(pos, pos + 3) == "null" then pos = pos + 4; return null_value end
        local start = pos
        while pos <= length and source:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
        assert(pos > start, "invalid JSON value")
        local value = tonumber(source:sub(start, pos - 1))
        assert(value, "invalid JSON number")
        return value
    end

    local value = parse_value()
    whitespace()
    assert(pos > length, "trailing JSON data")
    return value
end

function M.decode(source)
    return decode(source, false)
end

function M.decode_binary_safe(source)
    return decode(source, true)
end

return M
