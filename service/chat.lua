local skynet = require "skynet"
local bounded_lock = require "bounded_lock"

local CMD = {}
-- Store calls yield; serialize subscription changes and send/persist/fanout as one operation.
local lock, lock_stats = bounded_lock.new("chat_command_queue_max_outstanding", 512, "chat command queue full")
local metrics
local store
local sessions = {}
local channels = {}
local local_history = {}
local MAX_MESSAGE_BYTES = 5000
local MAX_HISTORY = 500
local MAX_CHANNELS_PER_REQUEST = 32
local configured_history_channels = tonumber(skynet.getenv("chat_history_cache_channels")) or 1024
local MAX_HISTORY_CHANNELS = math.max(1, math.min(65536, math.floor(configured_history_channels)))
local history_channel_count = 0
local history_last_used = {}
local history_use_sequence = 0

local function add_channel_alias(target, value)
    if type(value) == "number" then value = tostring(value) end
    if type(value) ~= "string" or value == "" or #value > 128 then return end
    target[value] = true
    local numeric = value:match("^r_(%d+)$")
    if numeric then target[numeric] = true end
end

local function authorized_channels(room_id, root_room_id, sub_rooms, explicit_channels)
    local allowed = {}
    add_channel_alias(allowed, room_id)
    add_channel_alias(allowed, root_room_id)
    for _, value in ipairs(sub_rooms or {}) do add_channel_alias(allowed, value) end
    for _, value in ipairs(explicit_channels or {}) do
        if type(value) == "table" then value = value.channel end
        add_channel_alias(allowed, value)
    end
    return allowed
end

local function validate_channel_list(names, allowed, require_nonempty)
    if type(names) ~= "table" or #names > MAX_CHANNELS_PER_REQUEST then return nil end
    if require_nonempty and #names == 0 then return nil end
    local result, seen = {}, {}
    for _, name in ipairs(names) do
        if type(name) == "number" then name = tostring(name) end
        if type(name) ~= "string" or name == "" or #name > 128 or not (allowed["*"] or allowed[name]) then
            return nil
        end
        if not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end
    return result
end

local function channel(name)
    local entry = channels[name]
    if not entry then
        entry = { listeners = {} }
        channels[name] = entry
    end
    return entry
end

local function release_channel_if_empty(name, entry)
    if channels[name] == entry and next(entry.listeners) == nil then
        channels[name] = nil
    end
end

local function load_filter()
    local path = skynet.getenv("sensitive_words_file") or "etc/sensitive_words.txt"
    local file = io.open(path, "r")
    if not file then return {} end
    local words = {}
    for line in file:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then words[#words + 1] = line end
    end
    file:close()
    table.sort(words, function(a, b) return #a > #b end)
    return words
end

local banned_words = load_filter()

local function filter_text(text)
    local filtered = text
    for _, word in ipairs(banned_words) do
        local lower = filtered:lower()
        local from = 1
        while true do
            local first, last = lower:find(word:lower(), from, true)
            if not first then break end
            filtered = filtered:sub(1, first - 1) .. string.rep("*", last - first + 1) .. filtered:sub(last + 1)
            lower = filtered:lower()
            from = last + 1
        end
    end
    return filtered
end

local function push_history(channel_name, record)
    local history = local_history[channel_name]
    if not history then
        if history_channel_count >= MAX_HISTORY_CHANNELS then
            local oldest_name, oldest_sequence
            for name, sequence in pairs(history_last_used) do
                if oldest_sequence == nil or sequence < oldest_sequence then
                    oldest_name, oldest_sequence = name, sequence
                end
            end
            if oldest_name then
                local_history[oldest_name] = nil
                history_last_used[oldest_name] = nil
                history_channel_count = history_channel_count - 1
            end
        end
        history = {}
        local_history[channel_name] = history
        history_channel_count = history_channel_count + 1
    end
    history_use_sequence = history_use_sequence + 1
    history_last_used[channel_name] = history_use_sequence
    history[#history + 1] = record
    while #history > MAX_HISTORY do table.remove(history, 1) end
end

local function touch_history(channel_name)
    if not local_history[channel_name] then return nil end
    history_use_sequence = history_use_sequence + 1
    history_last_used[channel_name] = history_use_sequence
    return local_history[channel_name]
end

local function send_to(session, name, payload)
    pcall(skynet.send, session, "lua", "send", name, payload)
end

function CMD.register(session, id, is_master, auth_source, room_id, root_room_id, sub_rooms, explicit_channels)
    local source = auth_source or "legacy_unverified"
    local chat_sub_rooms = source == "legacy_unverified" and sub_rooms or {}
    local allowed = authorized_channels(room_id, root_room_id, chat_sub_rooms, explicit_channels)
    if source == "legacy_unverified" and skynet.getenv("legacy_chat_channels_unrestricted") ~= "0" then
        allowed["*"] = true
    end
    sessions[session] = {
        id = id,
        is_master = is_master == true,
        auth_source = source,
        allowed_channels = allowed,
        send_window = skynet.now(),
        send_count = 0,
    }
    return true
end

function CMD.unregister(session)
    sessions[session] = nil
    for name, entry in pairs(channels) do
        entry.listeners[session] = nil
        release_channel_if_empty(name, entry)
    end
    return true
end

function CMD.listen(session, names)
    local identity = sessions[session]
    if not identity then return false end
    local valid = validate_channel_list(names, identity.allowed_channels, false)
    if not valid then
        skynet.error("chat listen denied", identity.id, identity.auth_source)
        return false
    end
    for _, name in ipairs(valid) do channel(name).listeners[session] = true end
    return true
end

function CMD.unlisten(session, names)
    local identity = sessions[session]
    if not identity then return false end
    local valid = validate_channel_list(names, identity.allowed_channels, false)
    if not valid then return false end
    for _, name in ipairs(valid) do
        local entry = channels[name]
        if entry then
            entry.listeners[session] = nil
            release_channel_if_empty(name, entry)
        end
    end
    return true
end

function CMD.send_message(session, names, text, disable_filter)
    local identity = sessions[session]
    if not identity or type(text) ~= "string" or #text > MAX_MESSAGE_BYTES then return false end
    local valid = validate_channel_list(names, identity.allowed_channels, true)
    if not valid then
        skynet.error("chat send denied", identity.id, identity.auth_source)
        return false
    end

    local now = skynet.now()
    if now - identity.send_window >= 1000 then
        identity.send_window, identity.send_count = now, 0
    end
    identity.send_count = identity.send_count + 1
    local send_limit = tonumber(skynet.getenv("chat_messages_per_10s")) or 30
    if identity.send_count > send_limit then
        skynet.error("chat rate exceeded", identity.id)
        return false
    end

    local content = text
    if not (disable_filter and identity.is_master) then content = filter_text(content) end
    local timestamp = os.time()
    local saved, err = skynet.call(store, "lua", "save_chat_batch", valid, identity.id, content, timestamp)
    if not saved then
        skynet.error("chat persistence failed", identity.id, err)
        return false
    end
    for _, name in ipairs(valid) do
        local record = { timestamp = timestamp, sender = identity.id, text = content }
        push_history(name, record)
        local response = { sender = identity.id, channel = name, text = content }
        local entry = channels[name]
        if entry then
            for listener in pairs(entry.listeners) do send_to(listener, "chatRecv_Response", response) end
        end
    end
    return true, content, valid
end

function CMD.queue_metrics()
    local queue = lock_stats()
    queue.outstanding = math.max(0, queue.outstanding - 1)
    return queue
end

function CMD.history(session, name, count)
    local identity = sessions[session]
    if not identity or type(name) ~= "string" or
       not (identity.allowed_channels["*"] or identity.allowed_channels[name]) then
        if identity then skynet.error("chat history denied", identity.id, identity.auth_source) end
        return false
    end
    count = math.max(0, math.min(math.floor(tonumber(count) or MAX_HISTORY), MAX_HISTORY))
    local records = skynet.call(store, "lua", "chat_history", name, count)
    if not records then
        local cached = touch_history(name) or {}
        records = {}
        for i = math.max(1, #cached - count + 1), #cached do records[#records + 1] = cached[i] end
    end
    send_to(session, "chatHistory_Response", { channel = name, records = records or {} })
    return true
end

skynet.start(function()
    metrics = skynet.uniqueservice("metrics")
    store = skynet.uniqueservice("store")
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown chat command " .. tostring(command))
        local args = table.pack(...)
        local command_started = skynet.now()
        local result = table.pack(pcall(function()
            return lock(fn, table.unpack(args, 1, args.n))
        end))
        skynet.send(metrics, "lua", "command_latency", "chat", command, skynet.now() - command_started)
        if session ~= 0 then
            if result[1] then skynet.ret(skynet.pack(table.unpack(result, 2, result.n)))
            else skynet.ret(skynet.pack(false, tostring(result[2]))) end
        elseif not result[1] then
            skynet.error("chat command failed", command, result[2])
        elseif result[2] == false and type(result[3]) == "string" and result[3]:match(" queue full$") then
            skynet.error("chat command queue full", command)
        end
    end)
    skynet.error("Chat service ready", "sensitive words", #banned_words)
end)
