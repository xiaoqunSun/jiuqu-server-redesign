local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local compat = require "compat_v1"

local CMD = {}
local context = {
    closed = false,
    cleaned = false,
    close_when_drained = false,
    outbound = {},
    outbound_head = 1,
    outbound_tail = 0,
    outbound_bytes = 0,
}
local directory
local auth
local chat
local metrics
local worker_started = false
local close_transport
local rate = {
    second_bucket = math.floor(skynet.now() / 100), one_sec_count = 0,
    five_sec_bucket = math.floor(skynet.now() / 100), five_sec_count = 0,
}

local function within_message_rate()
    local now = math.floor(skynet.now() / 100)
    local one_sec_limit = tonumber(skynet.getenv("oneSec_frequencyLimit"))
    local five_sec_limit = tonumber(skynet.getenv("fiveSec_frequencyLimit"))

    if one_sec_limit then
        if now ~= rate.second_bucket then rate.second_bucket, rate.one_sec_count = now, 0 end
        rate.one_sec_count = rate.one_sec_count + 1
        if rate.one_sec_count > one_sec_limit then return false end
    end
    if five_sec_limit then
        if now - rate.five_sec_bucket >= 5 then rate.five_sec_bucket, rate.five_sec_count = now, 0 end
        rate.five_sec_count = rate.five_sec_count + 1
        if rate.five_sec_count > five_sec_limit then return false end
    end
    return true
end

local function report_outbound_queue()
    if metrics and context.metrics_open then
        local queued = context.outbound_tail - context.outbound_head + 1
        skynet.send(metrics, "lua", "session_queue", math.max(0, queued), context.outbound_bytes)
    end
end

local function report_session_closed()
    if not metrics or not context.metrics_open then return end
    context.metrics_open = false
    skynet.send(metrics, "lua", "session_close")
end

local function metric_increment(name)
    if metrics then skynet.send(metrics, "lua", "increment", name, 1) end
end

local function write_packet(packet)
    local ok, result, err = pcall(function()
        if context.transport == "ws" then return websocket.write(context.fd, packet, "binary") end
        return socket.write(context.fd, packet)
    end)
    if not ok or result == false then
        skynet.error("client write failed", context.address, ok and err or result)
        close_transport()
        return false
    end
    return true
end

local function outbound_loop()
    context.outbound_worker = coroutine.running()
    while not context.closed do
        if context.outbound_head > context.outbound_tail then
            if context.close_when_drained then
                close_transport()
            else
                skynet.wait(context.outbound_worker)
            end
        else
            local index = context.outbound_head
            local packet = context.outbound[index]
            context.outbound[index] = nil
            context.outbound_head = index + 1
            context.outbound_bytes = context.outbound_bytes - #packet
            if context.outbound_head > context.outbound_tail then
                context.outbound = {}
                context.outbound_head, context.outbound_tail = 1, 0
            end
            report_outbound_queue()
            write_packet(packet)
        end
    end
    context.outbound = {}
    context.outbound_bytes = 0
end

local function send_packet(message, payload)
    if context.closed or context.close_when_drained then return false end
    local ok, packet = pcall(compat.encode_packet, message, payload)
    if not ok then
        skynet.error("protocol encode failed", message, packet)
        return false
    end

    local max_packets = tonumber(skynet.getenv("outbound_queue_max_packets")) or 256
    local max_bytes = tonumber(skynet.getenv("outbound_queue_max_bytes")) or 1024 * 1024
    local queued = context.outbound_tail - context.outbound_head + 1
    if queued >= max_packets or context.outbound_bytes + #packet > max_bytes then
        skynet.error("client outbound queue exceeded", context.address, queued, context.outbound_bytes)
        metric_increment("slow_client_disconnects")
        close_transport()
        return false
    end

    context.outbound_tail = context.outbound_tail + 1
    context.outbound[context.outbound_tail] = packet
    context.outbound_bytes = context.outbound_bytes + #packet
    report_outbound_queue()
    if context.outbound_worker then skynet.wakeup(context.outbound_worker) end
    return true
end

local function schedule_auth_expiration(expires_at)
    context.auth_expiration_generation = (context.auth_expiration_generation or 0) + 1
    local generation = context.auth_expiration_generation
    context.auth_expires_at = tonumber(expires_at)
    if not context.auth_expires_at then return end

    local function check_expiration()
        if context.closed or generation ~= context.auth_expiration_generation then return end
        local remaining = context.auth_expires_at - os.time()
        if remaining > 0 then
            local delay = math.ceil(math.min(remaining, 86400) * 100)
            skynet.timeout(math.max(1, delay), check_expiration)
            return
        end

        skynet.error("access token expired", context.address)
        if send_packet("kickOut", {}) then
            context.close_when_drained = true
            if context.outbound_worker then skynet.wakeup(context.outbound_worker) end
        else
            close_transport()
        end
    end

    local remaining = math.max(0, context.auth_expires_at - os.time())
    local delay = math.ceil(math.min(remaining, 86400) * 100)
    skynet.timeout(math.max(1, delay), check_expiration)
end

local function cleanup_call(service, service_name, command, ...)
    local args = table.pack(...)
    local attempt = 0
    while true do
        local called, result, detail = pcall(skynet.call,
            service, "lua", command, table.unpack(args, 1, args.n))
        if called and (result == true or detail == nil) then
            return true
        end

        attempt = attempt + 1
        if attempt == 1 or attempt % 20 == 0 then
            skynet.error("session cleanup waiting for service", service_name, command, attempt)
        end
        local unique_ok, unique_service = pcall(skynet.uniqueservice, service_name)
        if unique_ok then service = unique_service end
        skynet.sleep(math.min(100, attempt * 5))
    end
end

local function cleanup()
    if context.cleaned or context.cleanup_running then return end
    if context.login_pending then
        context.cleanup_pending = true
        return
    end
    context.cleanup_running = true
    if context.id and directory then
        cleanup_call(directory, "room_directory", "leave", skynet.self(), context.id)
    end
    if context.id and chat then
        cleanup_call(chat, "chat", "unregister", skynet.self())
    end
    context.cleanup_running = false
    context.cleaned = true
    -- Listener creates one Session Actor per connection. Retire it after the
    -- room and chat indexes no longer reference this connection.
    if context.closed and not context.exit_scheduled then
        context.exit_scheduled = true
        skynet.timeout(1, function() skynet.exit() end)
    end
end

close_transport = function()
    if context.closed then return end
    context.closed = true
    report_session_closed()
    cleanup()
    if context.outbound_worker then skynet.wakeup(context.outbound_worker) end
    if context.fd then
        if context.transport == "ws" then pcall(websocket.close, context.fd, 1000, "session closed")
        else pcall(socket.close, context.fd) end
    end
end

local function require_room()
    if not context.id or not context.room_actor then
        error("client command before login")
    end
end

local function login(message)
    context.login_pending = true
    local called, result = pcall(function()
        local accepted, begin_at, claims = skynet.call(auth, "lua", "check", message)
        if not accepted then
            metric_increment("login_denied")
            send_packet("loginResponse", { error = 1 })
            return true
        end
        if context.closed then return true end
        claims = claims or {}
        local previous_id = context.id
        local id = claims.id or message.id
        local room_id = claims.room_id or message.room or ""
        local root_room_id = claims.root_room_id or message.rootRoom
        if not root_room_id or root_room_id == "" then root_room_id = room_id end
        local is_master = claims.is_master == true
        local logged_in, err = skynet.call(directory, "lua", "login",
            skynet.self(), id, room_id, root_room_id, is_master, begin_at, claims.source, claims.sub_rooms, previous_id)
        if not logged_in then
            metric_increment("login_denied")
            send_packet("loginResponse", { error = 1 })
            skynet.error("login rejected", tostring(err))
            return true
        end

        -- Publish the accepted identity before releasing deferred disconnect
        -- cleanup. A socket write failure during login must leave no orphaned
        -- Room Membership behind.
        context.id = id
        context.room_id = room_id
        context.root_room_id = root_room_id
        context.is_master = is_master
        context.auth_source = claims.source or "legacy_unverified"
        schedule_auth_expiration(context.auth_source == "local_token" and claims.expires_at or nil)
        metric_increment("login_success")
        context.sub_rooms = claims.sub_rooms or {}
        context.allowed_chat_channels = claims.allowed_chat_channels or {}
        if context.closed then return true end

        chat = chat or skynet.uniqueservice("chat")
        if previous_id then pcall(skynet.call, chat, "lua", "unregister", skynet.self()) end
        context.room_actor = skynet.call(directory, "lua", "get_room", room_id, root_room_id)
        skynet.call(chat, "lua", "register", skynet.self(), context.id, context.is_master,
            context.auth_source, room_id, root_room_id, context.sub_rooms, context.allowed_chat_channels)
        return true
    end)
    context.login_pending = false
    if context.cleanup_pending or context.closed then cleanup() end
    if not called then
        metric_increment("login_denied")
        error(result)
    end
    return result
end

local function dispatch_message(name, message)
    if name == "loginRequest" then return login(message) end
    if name == "heartbeat" then
        context.last_heartbeat_ticks = skynet.now()
        return true
    end
    if name == "ping" then
        send_packet("pong", { timestamp = message.timestamp })
        return true
    end
    if name == "pong" then return true end
    if name == "volumestatistics" then
        require_room()
        return true
    end

    if name == "chatListen_Request" or name == "chatUnlisten_Request" or
       name == "chatSend_Request" or name == "chatHistory_Request" then
        if not context.id then error("chat command before login") end
        chat = chat or skynet.uniqueservice("chat")
        if name == "chatListen_Request" then
            local accepted, err = skynet.call(chat, "lua", "listen", skynet.self(), message.channels or {})
            if not accepted and err == "chat command queue full" then return false, err end
        elseif name == "chatUnlisten_Request" then
            local accepted, err = skynet.call(chat, "lua", "unlisten", skynet.self(), message.channels or {})
            if not accepted and err == "chat command queue full" then return false, err end
        elseif name == "chatSend_Request" then
            local accepted, delivered_text, delivered_channels = skynet.call(chat, "lua", "send_message",
                skynet.self(), message.channels or {}, message.text, message.disableWordsFilter == true)
            if not accepted and delivered_text == "chat command queue full" then return false, delivered_text end
            if accepted and message.saveToReplay then
                require_room()
                skynet.call(context.room_actor, "lua", "chat_replay", context.id, {
                    text = delivered_text, channels = delivered_channels,
                })
            end
        else
            local accepted, err = skynet.call(chat, "lua", "history", skynet.self(), message.channel, message.count)
            if not accepted and err == "chat command queue full" then return false, err end
        end
        return true
    end

    require_room()
    local room = context.room_actor
    if name == "updateVar_Request" then
        return skynet.call(room, "lua", "update_var", message.name, message.var, message.onlyToMaster, context.id)
    elseif name == "updateExtVar_Request" then
        return skynet.call(room, "lua", "update_ext_var", message.name, message.var,
            message.varIsTable, message.isMerge, message.onlyToMaster, context.id)
    elseif name == "queryExtVar_Request" then
        return skynet.call(room, "lua", "query_ext_var", skynet.self(), message.name)
    elseif name == "event_Request" then
        return skynet.call(room, "lua", "event", message, context.id)
    elseif name == "updateCursorPosition_Request" then
        return skynet.call(room, "lua", "update_cursor", message, context.id)
    elseif name == "saveRoomData_Request" then
        return skynet.call(room, "lua", "save_room_data", message, context.id)
    elseif name == "subRoomVar_Request" then
        return skynet.call(directory, "lua", "query_sub_room", skynet.self(), context.id, context.root_room_id, message)
    elseif name == "addVar_Request" then
        return skynet.call(room, "lua", "add_var", context.id, message.name, message.count, message.clampMin, message.clampMax)
    elseif name == "servertime_Request" then
        send_packet("servertime_Response", { client = message.client, server = os.time() })
        return true
    elseif name == "pageUpdate_Request" then
        return skynet.call(room, "lua", "page_update", context.id, message)
    elseif name == "pageCopy_Request" then
        return skynet.call(room, "lua", "page_copy", context.id, message.from, message.to)
    elseif name == "pageQuery_Request" then
        return skynet.call(room, "lua", "page_query", skynet.self(), message.pageId)
    elseif name == "styleAdd_Request" then
        return skynet.call(room, "lua", "style_add", context.id, message)
    elseif name == "styleQuery_Request" then
        return skynet.call(room, "lua", "style_query", skynet.self())
    elseif name == "createVote_Request" then
        return skynet.call(room, "lua", "create_vote", context.id, message)
    elseif name == "endVote_Request" then
        return skynet.call(room, "lua", "end_vote", context.id, message)
    elseif name == "closeVote_Request" then
        return skynet.call(room, "lua", "close_vote", context.id, message)
    elseif name == "submitVote_Request" then
        return skynet.call(room, "lua", "submit_vote", skynet.self(), context.id, message)
    elseif name == "queryVote_Request" then
        return skynet.call(room, "lua", "query_vote", skynet.self(), context.id, message)
    end
    error("unsupported client message " .. tostring(name))
end

local function process_packet(packet)
    if context.close_when_drained then return false end
    if not within_message_rate() then
        skynet.error("client message rate exceeded", context.address)
        close_transport()
        return false
    end
    local ok, name, message = pcall(compat.decode_packet, packet)
    if not ok then
        skynet.error("invalid client frame", context.address, name)
        close_transport()
        return false
    end
    local command_started = skynet.now()
    local handled, result, detail = pcall(dispatch_message, name, message)
    if metrics then
        skynet.send(metrics, "lua", "command_latency", "client", name,
            skynet.now() - command_started, context.room_id, context.id)
    end
    if not handled then
        skynet.error("client dispatch failed", name, result)
        close_transport()
        return false
    end
    if result == false and type(detail) == "string" and detail:match(" queue full$") then
        skynet.error("client rejected by bounded service queue", name, context.address, detail)
        close_transport()
        return false
    end
    return true
end

local websocket_handle = {}
function websocket_handle.message(_, packet)
    process_packet(packet)
end
function websocket_handle.close()
    context.closed = true
    report_session_closed()
    cleanup()
    if context.outbound_worker then skynet.wakeup(context.outbound_worker) end
end
function websocket_handle.error(_, err)
    skynet.error("websocket session error", context.address, err)
    context.closed = true
    report_session_closed()
    cleanup()
    if context.outbound_worker then skynet.wakeup(context.outbound_worker) end
end
function websocket_handle.ping() end
function websocket_handle.pong() end
function websocket_handle.connect() end
function websocket_handle.handshake() end

local function tcp_loop()
    local ok, err = pcall(function()
        local started, start_err = socket.start(context.fd)
        if not started then error(start_err or "socket start failed") end
        while not context.closed and not context.close_when_drained do
            local prefix = socket.read(context.fd, 2)
            if not prefix then break end
            local size = string.unpack(">I2", prefix)
            if size == 0 then error("empty client frame") end
            local body = socket.read(context.fd, size)
            if not body then break end
            if not process_packet(prefix .. body) then break end
        end
    end)
    if not ok then skynet.error("tcp session failed", context.address, err) end
    if not context.close_when_drained then close_transport() end
end

local function websocket_loop()
    local called, ok, err = pcall(websocket.accept, context.fd, websocket_handle, "ws", context.address)
    if not called then
        skynet.error("websocket session failed", context.address, ok)
    elseif not ok and not context.closed then
        skynet.error("websocket accept failed", context.address, err)
    end
    if not context.closed then
        close_transport()
    end
end

function CMD.start(conf)
    assert(not worker_started, "session already started")
    worker_started = true
    context.fd = conf.fd
    context.transport = conf.transport
    context.address = conf.address
    context.last_heartbeat_ticks = skynet.now()
    metrics = skynet.uniqueservice("metrics")
    directory = skynet.uniqueservice("room_directory")
    auth = skynet.uniqueservice("auth")
    chat = skynet.uniqueservice("chat")
    context.metrics_open = true
    skynet.send(metrics, "lua", "session_open")
    skynet.fork(outbound_loop)
    skynet.fork(context.transport == "ws" and websocket_loop or tcp_loop)
    skynet.fork(function()
        while not context.closed do
            skynet.sleep(300)
            if not context.closed then
                if skynet.now() - context.last_heartbeat_ticks > 3000 then
                    skynet.error("client heartbeat timeout", context.address)
                    close_transport()
                    break
                end
                send_packet("heartbeat", { timestamp = 0 })
            end
        end
    end)
    return true
end

function CMD.send(message, payload)
    return send_packet(message, payload)
end

function CMD.close()
    close_transport()
    return true
end

function CMD.close_after_flush()
    if context.closed then return true end
    context.close_when_drained = true
    if context.outbound_worker then skynet.wakeup(context.outbound_worker) end
    return true
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown session command " .. tostring(command))
        local ok, result = pcall(fn, ...)
        if session ~= 0 then
            if ok then skynet.ret(skynet.pack(result))
            else skynet.ret(skynet.pack(false, tostring(result))) end
        elseif not ok then
            skynet.error("session command failed", command, result)
        end
    end)
end)
