local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"
local json = require "json"
local persist_json = require "persist_json"

local directory
local metrics
local chat
local store
local token

local function constant_time_equal(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then return false end
    local length = math.max(#left, #right)
    local diff = math.abs(#left - #right)
    for i = 1, length do
        if left:byte(i) ~= right:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local function authorization_header(headers)
    for name, value in pairs(headers or {}) do
        if type(name) == "string" and name:lower() == "authorization" then
            return value
        end
    end
end

local function reply(fd, status, payload)
    local body = persist_json.encode_external(payload)
    local ok, err = httpd.write_response(sockethelper.writefunc(fd), status, body, {
        ["content-type"] = "application/json; charset=utf-8",
        ["connection"] = "close",
    })
    if not ok then skynet.error("admin response failed", tostring(err)) end
end

local function require_room_id(query_or_body)
    local room_id = query_or_body and query_or_body.room_id
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 then
        return nil, "room_id is required"
    end
    return room_id
end

local function dispatch(method, url, body)
    local path, query = urllib.parse(url)
    local params = query and urllib.parse_query(query) or {}

    if method == "GET" and path == "/health" then
        return 200, { status = "ok" }
    elseif method == "GET" and path == "/metrics" then
        local runtime = skynet.call(directory, "lua", "queue_metrics")
        runtime.rooms = json.array(runtime.rooms or {})
        return 200, {
            generated_at = os.time(),
            metrics = skynet.call(metrics, "lua", "snapshot"),
            active_sessions = runtime.active_sessions,
            active_rooms = runtime.active_rooms,
            queues = {
                directory = runtime.queue,
                rooms = runtime.rooms,
                families = runtime.families,
                chat = skynet.call(chat, "lua", "queue_metrics"),
                store = skynet.call(store, "lua", "queue_metrics"),
            },
        }
    elseif method == "GET" and path == "/rooms" then
        local stats = skynet.call(directory, "lua", "stats")
        stats.rooms = json.array(stats.rooms or {})
        return 200, stats
    elseif method == "GET" and (path == "/room" or path == "/room/var" or
        path == "/room/replay" or path == "/room/online") then
        local room_id, err = require_room_id(params)
        if not room_id then return 400, { error = err } end
        if path == "/room" then
            local info, info_err = skynet.call(directory, "lua", "admin_room_info", room_id)
            if not info then return 404, { error = info_err or "room not found" } end
            return 200, info
        elseif path == "/room/var" then
            local name = params.name
            if name == nil then name = params.key end
            if name ~= nil and type(name) ~= "string" then
                return 400, { error = "name must be a string" }
            end
            if name ~= nil and #name > 255 then return 400, { error = "name is too long" } end
            local extended = params.extended == "1" or params.extended == "true" or
                params.ext == "1" or params.ext == "true"
            local info, info_err = skynet.call(directory, "lua", "admin_room_info", room_id)
            if not info then return 404, { error = info_err or "room not found" } end
            local values = extended and info.extVars or info.vars
            if name == nil then
                return 200, { room_id = room_id, extended = extended, values = values }
            end
            local value = values[name]
            return 200, {
                room_id = room_id,
                name = name,
                extended = extended,
                found = value ~= nil,
                value = value == nil and json.null or value,
            }
        elseif path == "/room/online" then
            local has_history = params.history == "1" or params.history == "true"
            local info, info_err = skynet.call(directory, "lua", "admin_room_online_info", room_id, has_history)
            if not info then return 404, { error = info_err or "room not found" } end
            return 200, { room_id = room_id, history = has_history, users = info }
        end
        local after_sequence = tonumber(params.after) or 0
        local limit = tonumber(params.limit) or 500
        if after_sequence < 0 or after_sequence % 1 ~= 0 or limit < 1 or limit % 1 ~= 0 then
            return 400, { error = "after must be nonnegative and limit must be positive integers" }
        end
        local replay, replay_err = skynet.call(directory, "lua", "admin_room_replay",
            room_id, after_sequence, limit)
        if not replay then return 404, { error = replay_err or "replay not available" } end
        return 200, replay
    end

    if method ~= "POST" then return 405, { error = "method not allowed" } end
    local decoded_ok, request = pcall(json.decode, body or "")
    if not decoded_ok or type(request) ~= "table" or json.is_null(request) then
        return 400, { error = "body must be a JSON object" }
    end
    local room_id, room_err = require_room_id(request)
    if not room_id then return 400, { error = room_err } end

    if path == "/room/var" then
        if type(request.name) ~= "string" or request.name == "" then
            return 400, { error = "name is required" }
        end
        local value = request.value
        if type(value) ~= "string" then value = json.encode(value) end
        local ok, err = skynet.call(directory, "lua", "admin_set_room_var", room_id, request.name, value)
        if not ok then return 404, { error = err or "room update failed" } end
        skynet.error("admin room variable updated", room_id, request.name)
        return 200, { ok = true }
    elseif path == "/room/end-time" then
        local end_at = tonumber(request.end_at)
        if not end_at then return 400, { error = "end_at is required" } end
        local ok, err = skynet.call(directory, "lua", "admin_update_room_end_at", room_id, end_at)
        if not ok then return 400, { error = err or "room end time update failed" } end
        skynet.error("admin room end time updated", room_id, end_at)
        return 200, { ok = true, end_at = end_at > 0 and end_at or json.null }
    elseif path == "/room/event" then
        local event_id = tonumber(request.id)
        local value = request.var
        if type(value) ~= "string" then value = json.encode(value) end
        if not event_id then return 400, { error = "id is required" } end
        local ok, err = skynet.call(directory, "lua", "admin_send_room_event", room_id, {
            id = event_id,
            var = value,
        })
        if not ok then return 404, { error = err or "event rejected" } end
        skynet.error("admin room event sent", room_id, event_id)
        return 200, { ok = true }
    elseif path == "/room/close" then
        local ok, err = skynet.call(directory, "lua", "admin_close_room", room_id)
        if not ok then return 400, { error = err or "room close failed" } end
        skynet.error("admin room closed", room_id)
        return 200, { ok = true }
    elseif path == "/room/open" then
        local ok, err = skynet.call(directory, "lua", "admin_open_room", room_id)
        if not ok then return 400, { error = err or "room open failed" } end
        skynet.error("admin room opened", room_id)
        return 200, { ok = true }
    end
    return 404, { error = "unknown admin route" }
end

local function handle(fd, address)
    socket.start(fd)
    local code, url, method, headers, body = httpd.read_request(sockethelper.readfunc(fd), 65536)
    if code ~= 200 then
        reply(fd, code or 400, { error = "invalid request" })
        socket.close(fd)
        return
    end
    local expected = "Bearer " .. token
    if not constant_time_equal(authorization_header(headers), expected) then
        reply(fd, 401, { error = "unauthorized" })
        socket.close(fd)
        return
    end
    local ok, status, payload = pcall(dispatch, method, url, body)
    if not ok then
        skynet.error("admin request failed", address, tostring(status))
        reply(fd, 500, { error = "internal error" })
    else
        reply(fd, status, payload)
    end
    socket.close(fd)
end

skynet.start(function()
    local host = skynet.getenv("admin_host") or "127.0.0.1"
    local port = assert(tonumber(skynet.getenv("admin_port")), "admin_port is required")
    token = skynet.getenv("admin_token") or ""
    assert(port > 0, "admin service should only start when admin_port is enabled")
    assert(#token >= 32, "admin_token must contain at least 32 bytes")
    directory = skynet.uniqueservice("room_directory")
    metrics = skynet.uniqueservice("metrics")
    chat = skynet.uniqueservice("chat")
    store = skynet.uniqueservice("store")

    local listen_id = socket.listen(host, port, 64)
    skynet.error("admin API listening", host, port)
    socket.start(listen_id, function(fd, address)
        skynet.fork(handle, fd, address)
    end)
end)
