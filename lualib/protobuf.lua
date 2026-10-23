-- Small proto2 wire codec for the client compatibility boundary.
-- The schema files are checked into compat/v1/proto; domain services never
-- depend on the returned Lua tables.
local M = {}

local primitive_wire = {
    bytes = 2, string = 2,
    int32 = 0, int64 = 0, uint32 = 0, uint64 = 0, bool = 0,
    float = 5, double = 1,
}

local function tokenize(source)
    source = source:gsub("/%*.-%*/", " "):gsub("//[^\n]*", " ")
    local out, i, n = {}, 1, #source
    while i <= n do
        local c = source:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == '"' then
            i = i + 1
            while i <= n do
                local q = source:sub(i, i)
                if q == "\\" then
                    i = i + 2
                elseif q == '"' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
        elseif c:match("[%a_]") then
            local j = i + 1
            while j <= n and source:sub(j, j):match("[%w_]") do j = j + 1 end
            out[#out + 1] = source:sub(i, j - 1)
            i = j
        elseif c:match("%d") then
            local j = i + 1
            while j <= n and source:sub(j, j):match("%d") do j = j + 1 end
            out[#out + 1] = source:sub(i, j - 1)
            i = j
        elseif c:match("[%{%}=;%[%],%.]") then
            out[#out + 1] = c
            i = i + 1
        else
            i = i + 1
        end
    end
    return out
end

local function parse_file(source, schemas)
    local without_comments = source:gsub("/%*.-%*/", " "):gsub("//[^\n]*", " ")
    local declared_syntax = without_comments:match('syntax%s*=%s*"([^"]+)"')
    assert(not declared_syntax or declared_syntax == "proto2",
        "unsupported protobuf syntax " .. tostring(declared_syntax) .. "; only proto2 is supported")
    local tokens, i = tokenize(source), 1
    local function take()
        local t = tokens[i]
        i = i + 1
        return t
    end
    local function skip_statement()
        while tokens[i] and tokens[i] ~= ";" and tokens[i] ~= "}" do i = i + 1 end
        if tokens[i] == ";" then i = i + 1 end
    end
    local parse_message
    parse_message = function(parent)
        assert(take() == "message", "expected message")
        local short = assert(take(), "message name expected")
        local full = parent and (parent .. "." .. short) or short
        assert(take() == "{", "message body expected")
        assert(not schemas[full], "duplicate protobuf message " .. full)
        local schema = { name = full, fields = {}, by_number = {}, by_name = {} }
        schemas[full] = schema
        while tokens[i] and tokens[i] ~= "}" do
            local first = tokens[i]
            if first == "message" then
                parse_message(full)
            elseif first == "required" or first == "optional" or first == "repeated" then
                local label = take()
                local kind = assert(take(), "field type expected")
                local name = assert(take(), "field name expected")
                assert(take() == "=", "field number expected")
                local number_token = assert(take(), "field number expected")
                local number = tonumber(number_token)
                assert(number and number >= 1 and number <= 536870911 and
                    not (number >= 19000 and number <= 19999),
                    "invalid protobuf field number in " .. full .. "." .. tostring(name))
                while tokens[i] and tokens[i] ~= ";" do i = i + 1 end
                assert(take() == ";", "field terminator expected")
                local field = { label = label, type = kind, name = name, number = number }
                assert(not schema.by_number[number], "duplicate protobuf field number")
                assert(not schema.by_name[name], "duplicate protobuf field name " .. name .. " in " .. full)
                schema.fields[#schema.fields + 1] = field
                schema.by_number[number] = field
                schema.by_name[name] = field
            elseif first == "}" then
                break
            elseif first == "option" or first == "reserved" or first == "extensions" then
                skip_statement()
            elseif first == "enum" or first == "map" or first == "oneof" or first == "group" then
                error("unsupported protobuf construct " .. first .. " in " .. full)
            else
                error("unsupported protobuf declaration " .. tostring(first) .. " in " .. full)
            end
        end
        assert(take() == "}", "unterminated message " .. full)
    end

    while tokens[i] do
        if tokens[i] == "message" then
            parse_message(nil)
        elseif tokens[i] == "import" or tokens[i] == "option" or tokens[i] == "syntax" then
            skip_statement()
        elseif tokens[i] == "package" then
            error("protobuf package declarations are unsupported")
        elseif tokens[i] == ";" then
            i = i + 1
        else
            error("unsupported top-level protobuf declaration " .. tostring(tokens[i]))
        end
    end
end

local function resolve_types(schemas)
    for _, schema in pairs(schemas) do
        for _, field in ipairs(schema.fields) do
            field.wire = primitive_wire[field.type]
            if not field.wire then
                local scope = schema.name
                local resolved
                while scope do
                    local candidate = scope .. "." .. field.type
                    if schemas[candidate] then
                        resolved = candidate
                        break
                    end
                    scope = scope:match("^(.*)%.[^.]+$")
                end
                if not resolved and schemas[field.type] then resolved = field.type end
                assert(resolved, "unknown protobuf type " .. field.type .. " in " .. schema.name)
                field.message = resolved
                field.wire = 2
            end
        end
    end
end

function M.load(directory)
    local schemas = {}
    local files = {
        "room.proto", "page.proto", "vote.proto", "heartbeat.proto",
        "statistics.proto", "login.proto",
    }
    for _, filename in ipairs(files) do
        local file = assert(io.open(directory .. "/" .. filename, "rb"))
        local source = file:read("*a")
        file:close()
        parse_file(source, schemas)
    end
    resolve_types(schemas)
    return setmetatable({ schemas = schemas }, { __index = M })
end

local function varint(value)
    value = math.tointeger(value) or math.floor(value)
    if value < 0 then
        return string.rep("\255", 9) .. "\1"
    end
    local out = {}
    repeat
        local byte = value & 0x7f
        value = value >> 7
        if value ~= 0 then byte = byte | 0x80 end
        out[#out + 1] = string.char(byte)
    until value == 0
    return table.concat(out)
end

local function read_varint(data, pos)
    local value, shift = 0, 0
    for index = 1, 10 do
        local byte = data:byte(pos)
        if not byte then error("truncated protobuf varint") end
        -- Lua integers are signed 64 bit. The tenth byte may only carry the
        -- sign-extension bit used by negative int32/int64 values; accepting
        -- more bits silently wraps tags and lengths into negative numbers.
        if index == 10 and byte > 1 then error("protobuf varint exceeds 64 bits") end
        pos = pos + 1
        value = value | ((byte & 0x7f) << shift)
        if byte < 0x80 then return value, pos end
        shift = shift + 7
    end
    error("protobuf varint exceeds 10 bytes")
end

local function read_length(data, pos)
    local length
    length, pos = read_varint(data, pos)
    local available = #data - pos + 1
    if length < 0 or length > available then
        error("protobuf length exceeds remaining message")
    end
    return length, pos
end

local function encode_one(codec, field, value)
    local tag = varint((field.number << 3) | field.wire)
    if field.message then
        local encoded = codec:_encode(field.message, value)
        return tag .. varint(#encoded) .. encoded
    elseif field.wire == 2 then
        value = tostring(value)
        return tag .. varint(#value) .. value
    elseif field.wire == 0 then
        if field.type == "bool" then value = value and 1 or 0 end
        return tag .. varint(value)
    elseif field.wire == 5 then
        return tag .. string.pack("<f", value)
    elseif field.wire == 1 then
        return tag .. string.pack("<d", value)
    end
    error("unsupported protobuf wire type")
end

function M:_encode(name, value)
    local schema = assert(self.schemas[name], "unknown protobuf message " .. name)
    assert(type(value) == "table", "protobuf message must be a table")
    local out = {}
    for _, field in ipairs(schema.fields) do
        local v = value[field.name]
        if field.label == "required" and v == nil then
            error("missing required protobuf field " .. name .. "." .. field.name)
        end
        if field.label == "repeated" then
            if v ~= nil then
                assert(type(v) == "table", "repeated protobuf field must be a table")
                for _, item in ipairs(v) do out[#out + 1] = encode_one(self, field, item) end
            end
        elseif v ~= nil then
            out[#out + 1] = encode_one(self, field, v)
        end
    end
    return table.concat(out)
end

function M:encode(name, value)
    return self:_encode(name, value)
end

local function skip_wire(data, pos, wire)
    if wire == 0 then
        local _, next_pos = read_varint(data, pos)
        return next_pos
    elseif wire == 1 then
        pos = pos + 8
    elseif wire == 2 then
        local length
        length, pos = read_length(data, pos)
        pos = pos + length
    elseif wire == 5 then
        pos = pos + 4
    else
        error("unsupported protobuf wire type " .. wire)
    end
    if pos - 1 > #data then error("truncated protobuf field") end
    return pos
end

local function decode_one(codec, field, data, pos, wire)
    if field.message then
        local length
        length, pos = read_length(data, pos)
        local finish = pos + length - 1
        return codec:_decode(field.message, data:sub(pos, finish)), finish + 1
    elseif field.wire == 2 then
        local length
        length, pos = read_length(data, pos)
        local finish = pos + length - 1
        return data:sub(pos, finish), finish + 1
    elseif field.wire == 0 then
        local value
        value, pos = read_varint(data, pos)
        if field.type == "bool" then return value ~= 0, pos end
        if field.type == "int32" and (value & 0x80000000) ~= 0 then
            value = (value & 0xffffffff) - 0x100000000
        end
        return value, pos
    elseif field.wire == 5 then
        if pos + 3 > #data then error("truncated protobuf float") end
        return string.unpack("<f", data, pos)
    elseif field.wire == 1 then
        if pos + 7 > #data then error("truncated protobuf double") end
        return string.unpack("<d", data, pos)
    end
    error("unsupported protobuf field wire")
end

function M:_decode(name, data)
    local schema = assert(self.schemas[name], "unknown protobuf message " .. name)
    local result, pos = {}, 1
    while pos <= #data do
        local key
        key, pos = read_varint(data, pos)
        local number, wire = key >> 3, key & 7
        if number < 1 or number > 536870911 then error("invalid protobuf field number") end
        local field = schema.by_number[number]
        if not field then
            pos = skip_wire(data, pos, wire)
        elseif field.label == "repeated" and field.wire ~= 2 and wire == 2 then
            local length
            length, pos = read_length(data, pos)
            local finish = pos + length
            if field.wire == 1 and length % 8 ~= 0 then
                error("invalid packed protobuf double length")
            elseif field.wire == 5 and length % 4 ~= 0 then
                error("invalid packed protobuf float length")
            end
            local values = result[field.name] or {}
            while pos < finish do
                local item
                if field.wire == 0 then
                    item, pos = read_varint(data, pos)
                    if pos > finish then error("truncated packed protobuf varint") end
                    if field.type == "bool" then item = item ~= 0 end
                    if field.type == "int32" and (item & 0x80000000) ~= 0 then
                        item = (item & 0xffffffff) - 0x100000000
                    end
                elseif field.wire == 5 then
                    item, pos = string.unpack("<f", data, pos)
                elseif field.wire == 1 then
                    item, pos = string.unpack("<d", data, pos)
                end
                if pos > finish then error("truncated packed protobuf field") end
                values[#values + 1] = item
            end
            result[field.name] = values
        elseif wire ~= field.wire then
            pos = skip_wire(data, pos, wire)
        else
            local value
            value, pos = decode_one(self, field, data, pos, wire)
            if field.label == "repeated" then
                local values = result[field.name] or {}
                values[#values + 1] = value
                result[field.name] = values
            else
                result[field.name] = value
            end
        end
    end
    for _, field in ipairs(schema.fields) do
        if field.label == "required" and result[field.name] == nil then
            error("missing required protobuf field " .. name .. "." .. field.name)
        end
    end
    return result
end

function M:decode(name, data)
    return self:_decode(name, data)
end

return M
