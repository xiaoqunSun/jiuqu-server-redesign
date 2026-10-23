local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do out[clone(key, seen)] = clone(item, seen) end
    return setmetatable(out, getmetatable(value))
end

function class(name, super)
    local cls = { __cname = name, super = super }
    cls.__index = cls
    setmetatable(cls, { __index = super })
    function cls.new(...)
        local instance = setmetatable({}, cls)
        instance.class = cls
        if instance.ctor then instance:ctor(...) end
        return instance
    end
    function cls.create(_, ...) return cls.new(...) end
    return cls
end

_G.clone = clone
_G.ternary = function(condition, yes, no) if condition then return yes end return no end
_G.checknumber = function(value) return tonumber(value) or 0 end
_G.checkint = function(value) return math.floor(tonumber(value) or 0) end
_G.checkbool = function(value) return value ~= nil and value ~= false end
_G.unpack = table.unpack

function table.foreach(value, fn)
    for key, item in pairs(value) do fn(key, item) end
end

function table.walk(value, fn)
    for key, item in pairs(value) do fn(item, key) end
end

function string.split(value, delimiter)
    value, delimiter = tostring(value), tostring(delimiter)
    assert(delimiter ~= "", "delimiter must not be empty")
    local out, from = {}, 1
    while true do
        local first, last = value:find(delimiter, from, true)
        if not first then out[#out + 1] = value:sub(from); break end
        out[#out + 1] = value:sub(from, first - 1)
        from = last + 1
    end
    return out
end

function string.utf8len(value)
    local count = utf8.len(value)
    if count then return count end
    local n = 0
    for _ in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end

function string.utf8sub(value, first, count)
    local total = string.utf8len(value)
    if first < 0 then first = total + first + 1 end
    first = math.max(first, 1)
    if count == nil then count = total - first + 1 end
    if count <= 0 then return "" end
    local begin_byte = utf8.offset(value, first)
    if not begin_byte then return "" end
    local end_byte = utf8.offset(value, first + count)
    if not end_byte then return value:sub(begin_byte) end
    return value:sub(begin_byte, end_byte - 1)
end

function string.delete(value, first, last, is_utf8)
    local length = is_utf8 and string.utf8len(value) or #value
    first, last = math.max(first, 1), math.min(last, length)
    if first > last then first, last = last, first end
    local before = first > 1 and (is_utf8 and string.utf8sub(value, 1, first - 1) or value:sub(1, first - 1)) or ""
    local after = last < length and (is_utf8 and string.utf8sub(value, last + 1) or value:sub(last + 1)) or ""
    return before .. after
end

function string.insert(value, position, inserted, is_utf8)
    local length = is_utf8 and string.utf8len(value) or #value
    if position <= 1 then return inserted .. value end
    if position > length then return value .. inserted end
    local left = is_utf8 and string.utf8sub(value, 1, position - 1) or value:sub(1, position - 1)
    local right = is_utf8 and string.utf8sub(value, position) or value:sub(position)
    return left .. inserted .. right
end

function string.push(value, suffix) return value .. suffix end
function string.trim(value)
    local trimmed = value:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", "")
    return trimmed
end
function string.htmlspecialchars(value)
    local escaped = value:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("'", "&#039;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return escaped
end
function string.restorehtmlspecialchars(value)
    local restored = value:gsub("&gt;", ">"):gsub("&lt;", "<"):gsub("&#039;", "'"):gsub("&quot;", '"'):gsub("&amp;", "&")
    return restored
end

