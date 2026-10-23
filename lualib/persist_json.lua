local json = require "json"

local M = { version = 2 }
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local alphabet_index = {}
for index = 1, #alphabet do
    alphabet_index[alphabet:sub(index, index)] = index - 1
end

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

local function base64_encode(value)
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index)
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local combined = (first << 16) | ((second or 0) << 8) | (third or 0)
        output[#output + 1] = alphabet:sub(((combined >> 18) & 0x3f) + 1, ((combined >> 18) & 0x3f) + 1)
        output[#output + 1] = alphabet:sub(((combined >> 12) & 0x3f) + 1, ((combined >> 12) & 0x3f) + 1)
        output[#output + 1] = second and alphabet:sub(((combined >> 6) & 0x3f) + 1, ((combined >> 6) & 0x3f) + 1) or "="
        output[#output + 1] = third and alphabet:sub((combined & 0x3f) + 1, (combined & 0x3f) + 1) or "="
    end
    return table.concat(output)
end

local function base64_decode(value)
    assert(type(value) == "string" and #value % 4 == 0, "invalid persisted base64")
    local output = {}
    for index = 1, #value, 4 do
        local first, second = value:sub(index, index), value:sub(index + 1, index + 1)
        local third, fourth = value:sub(index + 2, index + 2), value:sub(index + 3, index + 3)
        local last = index + 3 == #value
        local a, b = alphabet_index[first], alphabet_index[second]
        assert(a and b, "invalid persisted base64")
        local c = third == "=" and nil or alphabet_index[third]
        local d = fourth == "=" and nil or alphabet_index[fourth]
        assert((third ~= "=" and c ~= nil or third == "=") and
            (fourth ~= "=" and d ~= nil or fourth == "="), "invalid persisted base64")
        assert(last or (third ~= "=" and fourth ~= "="), "invalid persisted base64 padding")
        assert(third ~= "=" or fourth == "=", "invalid persisted base64 padding")
        local combined = (a << 18) | (b << 12) | ((c or 0) << 6) | (d or 0)
        output[#output + 1] = string.char((combined >> 16) & 0xff)
        if third ~= "=" then output[#output + 1] = string.char((combined >> 8) & 0xff) end
        if fourth ~= "=" then output[#output + 1] = string.char(combined & 0xff) end
    end
    local decoded = table.concat(output)
    assert(base64_encode(decoded) == value, "noncanonical persisted base64")
    return decoded
end

local function tagged(tag, value)
    if value == nil then return json.array({ tag }) end
    return json.array({ tag, value })
end

local function encode_node(value, stack)
    if value == nil or json.is_null(value) then return tagged("z"), false end
    local kind = type(value)
    if kind == "string" then
        if utf8_valid(value) then return tagged("s", value), false end
        return tagged("b", base64_encode(value)), true
    elseif kind == "number" then
        return tagged("n", value), false
    elseif kind == "boolean" then
        return tagged("t", value), false
    end

    assert(kind == "table", "unsupported persistent JSON value: " .. kind)
    assert(not stack[value], "cyclic persistent JSON value")
    stack[value] = true
    local contains_binary = false
    local node
    if json.is_array(value) then
        local items = json.array()
        for index = 1, #value do
            local item, item_has_binary = encode_node(value[index], stack)
            items[index] = item
            contains_binary = contains_binary or item_has_binary
        end
        node = tagged("a", items)
    else
        local keys = {}
        for key in pairs(value) do
            assert(type(key) == "string", "persistent JSON object keys must be strings")
            keys[#keys + 1] = key
        end
        table.sort(keys)
        local entries = json.array()
        for index, key in ipairs(keys) do
            local encoded_key, key_has_binary = encode_node(key, stack)
            local encoded_value, value_has_binary = encode_node(value[key], stack)
            entries[index] = json.array({ encoded_key, encoded_value })
            contains_binary = contains_binary or key_has_binary or value_has_binary
        end
        node = tagged("o", entries)
    end
    stack[value] = nil
    return node, contains_binary
end

local function require_array(value, expected_length, description)
    assert(type(value) == "table" and json.is_array(value), description .. " is not an array")
    if expected_length then assert(#value == expected_length, description .. " has an invalid length") end
end

local function decode_node(node)
    require_array(node, nil, "persistent JSON node")
    local tag = node[1]
    if tag == "z" then
        require_array(node, 1, "null node")
        return json.null
    elseif tag == "s" then
        require_array(node, 2, "string node")
        assert(type(node[2]) == "string" and utf8_valid(node[2]), "invalid persisted UTF-8 string")
        return node[2]
    elseif tag == "b" then
        require_array(node, 2, "binary node")
        return base64_decode(node[2])
    elseif tag == "n" then
        require_array(node, 2, "number node")
        assert(type(node[2]) == "number", "invalid persisted number")
        return node[2]
    elseif tag == "t" then
        require_array(node, 2, "boolean node")
        assert(type(node[2]) == "boolean", "invalid persisted boolean")
        return node[2]
    elseif tag == "a" then
        require_array(node, 2, "array node")
        require_array(node[2], nil, "array items")
        local result = json.array()
        for index, item in ipairs(node[2]) do result[index] = decode_node(item) end
        return result
    elseif tag == "o" then
        require_array(node, 2, "object node")
        require_array(node[2], nil, "object entries")
        local result = {}
        for _, entry in ipairs(node[2]) do
            require_array(entry, 2, "object entry")
            local key = decode_node(entry[1])
            assert(type(key) == "string", "persistent JSON object key is not a string")
            assert(result[key] == nil, "duplicate persistent JSON object key")
            result[key] = decode_node(entry[2])
        end
        return result
    end
    error("unknown persistent JSON node tag")
end

function M.encode(value)
    return json.encode_binary_safe(value)
end

function M.decode(source, schema_version)
    local version = tonumber(schema_version) or 1
    if version == 1 then return json.decode(source) end
    assert(version == M.version, "unsupported persistent JSON schema version")
    return json.decode_binary_safe(source)
end

function M.encode_external(value)
    local data, contains_binary = encode_node(value, {})
    if not contains_binary then return json.encode(value) end
    return json.encode({
        ["$jiuqu_binary_json"] = M.version,
        data = data,
    })
end

function M.decode_external(envelope)
    assert(type(envelope) == "table" and
        tonumber(envelope["$jiuqu_binary_json"]) == M.version,
        "invalid external binary JSON envelope")
    return decode_node(envelope.data)
end

function M.base64_encode(value)
    assert(type(value) == "string", "binary value must be a string")
    return base64_encode(value)
end

return M
