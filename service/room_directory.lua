local skynet = require "skynet"
local bounded_lock = require "bounded_lock"
local json = require "json"
local persist_json = require "persist_json"
require "skynet.manager"

local CMD = {}
local lock, lock_stats = bounded_lock.new("directory_command_queue_max_outstanding", 512, "room directory queue full")
local metrics
local rooms = {}
local room_roots = {}
local families = {}
local room_last_active = {}
local room_idle_workers = {}
local online = {}

local function idle_timeout_ticks()
    local timeout = tonumber(skynet.getenv("room_idle_timeout"))
    if timeout == nil then timeout = 3600 end
    if timeout <= 0 then return 0 end
    return math.max(1, math.floor(timeout * 100))
end

local function touch_room(room_id)
    room_last_active[room_id] = skynet.now()
    local worker = room_idle_workers[room_id]
    if worker then skynet.wakeup(worker) end
end

local function start_idle_worker(room_id, room)
    if room_idle_workers[room_id] then return end
    local timeout_ticks = idle_timeout_ticks()
    if timeout_ticks == 0 then return end

    room_idle_workers[room_id] = {}
    skynet.fork(function()
        local worker = coroutine.running()
        room_idle_workers[room_id] = worker
        while rooms[room_id] == room do
            local last_active = room_last_active[room_id] or skynet.now()
            local remaining = timeout_ticks - (skynet.now() - last_active)
            if remaining > 0 then skynet.sleep(remaining, worker) end
            if rooms[room_id] ~= room then break end
            local retired = skynet.call(skynet.self(), "lua", "retire_idle_room", room_id, room)
            if retired then break end
        end
        if room_idle_workers[room_id] == worker then room_idle_workers[room_id] = nil end
    end)
end

local function call_actor_with_retry(actor, command, ...)
    local args = table.pack(...)
    local attempt = 0
    while true do
        local result = table.pack(pcall(skynet.call, actor, "lua", command,
            table.unpack(args, 1, args.n)))
        if not result[1] then return false, result[2] end
        local queue_full = result[2] == false and type(result[3]) == "string" and
            result[3]:match(" queue full$")
        if not queue_full then
            return true, table.unpack(result, 2, result.n)
        end
        attempt = attempt + 1
        if attempt >= 20 then return false, result[3] end
        skynet.sleep(math.min(100, attempt * 5))
    end
end

local function call_actor_boolean(actor, command, ...)
    local called, accepted, err = call_actor_with_retry(actor, command, ...)
    if called and accepted == true then return true end
    return false, err or accepted
end

local function resync_family_children(root_room_id, root_room)
    root_room = root_room or rooms[root_room_id]
    if not root_room then return false end
    local ready_ok, ready = pcall(skynet.call, root_room, "lua", "ready")
    if not ready_ok or not ready then
        skynet.error("room family root is not ready", root_room_id, tostring(ready))
        return false
    end
    local family = families[root_room_id]
    if not family then return false end
    for room_id, room in pairs(rooms) do
        if room_id ~= root_room_id and room_roots[room_id] == root_room_id then
            local synced, sync_err = call_actor_boolean(family, "reconcile_room", room_id)
            if not synced then
                skynet.error("room family recovery sync failed", room_id, tostring(sync_err))
            end
        end
    end
    return true
end

local function family_for(root_room_id)
    local family = families[root_room_id]
    if family then
        local ok, identity, identity_err = call_actor_with_retry(family, "identity")
        if ok and identity == root_room_id then return family end
        if not ok and type(identity) == "string" and identity:match(" queue full$") then
            error(identity)
        end
        skynet.error("replacing unavailable room family coordinator", root_room_id,
            tostring(identity_err or identity))
    end

    family = skynet.newservice("room_family", root_room_id)
    families[root_room_id] = family
    for room_id, room in pairs(rooms) do
        if room_roots[room_id] == root_room_id then
            local registered, register_err = call_actor_boolean(family,
                "register_room", room_id, room)
            local attached, attach_err = false, nil
            if registered then
                attached, attach_err = call_actor_boolean(room, "set_family_service", family)
            end
            if not attached then
                if registered then
                    local removed = call_actor_with_retry(family, "unregister_room", room_id, room)
                    if not removed then
                        skynet.error("stale room family registration cleanup failed", room_id)
                    end
                end
                rooms[room_id] = nil
                room_roots[room_id] = nil
                room_last_active[room_id] = nil
                skynet.error("room family recovery registration failed", room_id,
                    tostring(register_err or attach_err))
            end
        end
    end

    -- A recreated coordinator may have missed root publications while it was
    -- down. Reconcile surviving child actors from the durable root snapshot.
    if rooms[root_room_id] then resync_family_children(root_room_id) end
    return family
end

local function room_for(room_id, root_room_id)
    assert(type(room_id) == "string" and room_id ~= "", "room id is required")
    root_room_id = root_room_id or room_id

    if room_id ~= root_room_id then
        room_for(root_room_id, root_room_id)
    end

    local room = rooms[room_id]
    if room then
        assert(room_roots[room_id] == root_room_id, "room root mapping changed")
        local alive, identity = pcall(skynet.call, room, "lua", "info")
        if not alive or type(identity) ~= "table" or identity.room_id ~= room_id then
            skynet.error("replacing unavailable room actor", room_id)
            rooms[room_id] = nil
            room_roots[room_id] = nil
            room_last_active[room_id] = nil
            room_idle_workers[room_id] = nil
            room = nil
        end
    end
    if room then
        local family = family_for(root_room_id)
        local registered, register_err = call_actor_boolean(family,
            "register_room", room_id, room)
        assert(registered, register_err or "room family registration failed")
        local attached, attach_err = call_actor_boolean(room, "set_family_service", family)
        assert(attached, attach_err or "room family attachment failed")
        touch_room(room_id)
        return room
    end
    local family = family_for(root_room_id)
    room = skynet.newservice("room", room_id, root_room_id, family)
    rooms[room_id] = room
    room_roots[room_id] = root_room_id
    local registered, register_err = call_actor_boolean(family, "register_room", room_id, room)
    assert(registered, register_err or "room family registration failed")
    touch_room(room_id)
    start_idle_worker(room_id, room)
    if room_id == root_room_id then resync_family_children(root_room_id, room) end
    return room
end

local function prepare_room(room_id, root_room_id, room)
    local ready, err = skynet.call(room, "lua", "ready")
    if not ready then return false, err end
    if room_id == root_room_id then return true end

    local root_room = room_for(root_room_id, root_room_id)
    local root_ready, root_err = skynet.call(root_room, "lua", "ready")
    if not root_ready then return false, root_err end
    local family = family_for(root_room_id)
    local synced, sync_err = call_actor_boolean(family, "reconcile_room", room_id)
    if not synced then return false, sync_err or "family sync failed" end
    return true
end

local function schedule_room_exit(room, room_id, session, id, membership_version)
    local safe_room_id = type(room_id) == "string" and room_id:gsub("[%z\1-\31\127]", "?") or ""
    skynet.fork(function()
        local attempt = 0
        while true do
            local called, exited, err = pcall(skynet.call,
                room, "lua", "exit", session, id, membership_version)
            if not called then return end -- the Room Actor is gone with its membership
            if exited == true or (exited == false and err == nil) then return end
            attempt = attempt + 1
            if attempt == 1 or attempt % 20 == 0 then
                skynet.error("previous room membership cleanup retrying", safe_room_id, attempt)
            end
            skynet.sleep(math.min(100, attempt * 5))
        end
    end)
end

function CMD.login(session, id, room_id, root_room_id, is_master, begin_at, auth_source, sub_rooms, previous_id)
    if type(id) ~= "string" or id == "" then return false, "missing id" end
    if type(room_id) ~= "string" or room_id == "" then return false, "missing room" end
    root_room_id = root_room_id or room_id
    if #id > 255 or #room_id > 191 or type(root_room_id) ~= "string" or #root_room_id > 191 then
        return false, "identity or room id exceeds storage limits"
    end
    local store = skynet.uniqueservice("store")
    local status_ok, persisted_closed, status_err = pcall(skynet.call, store, "lua", "room_is_closed", room_id)
    if not status_ok or persisted_closed == nil then
        return false, status_ok and status_err or persisted_closed or "room lifecycle unavailable"
    end
    if persisted_closed then
        return false, "room is closed"
    end
    local old = online[id]
    local previous = type(previous_id) == "string" and online[previous_id] or nil
    if previous and previous.session ~= session then previous = nil end
    local room = room_for(room_id, root_room_id)
    local ready, ready_err = prepare_room(room_id, root_room_id, room)
    if not ready then return false, ready_err end
    local eligible, eligibility_err = skynet.call(room, "lua", "can_enter")
    if not eligible then return false, eligibility_err end

    local old_chat
    if old and old.session ~= session then old_chat = skynet.uniqueservice("chat") end
    -- Join the target Room before evicting another Session for this identity.
    -- Room.enter repeats lifecycle checks under its own lock, so a scheduled
    -- close between preflight and entry also leaves the existing Session intact.
    local ok, err, membership_version = skynet.call(room, "lua", "enter", session, id, is_master, begin_at, auth_source)
    if not ok then return false, err end
    if old and old.session ~= session then
        pcall(skynet.call, old_chat, "lua", "unregister", old.session)
        skynet.send(old.session, "lua", "send", "kickOut", {})
        skynet.send(old.session, "lua", "close_after_flush")
        schedule_room_exit(old.room, old.room_id, old.session, id, old.membership_version)
    end
    online[id] = {
        session = session, room = room, room_id = room_id, root_room_id = root_room_id,
        membership_version = membership_version,
        auth_source = auth_source or "legacy_unverified",
        sub_rooms = type(sub_rooms) == "table" and sub_rooms or {},
    }

    -- Keep this Session's previous membership until the target room has
    -- accepted it. That way a rejected re-login leaves the active session intact.
    if previous and (previous_id ~= id or previous.room ~= room) then
        if previous_id ~= id and online[previous_id] == previous then
            online[previous_id] = nil
        end
        touch_room(previous.room_id)
        if previous.root_room_id ~= previous.room_id then touch_room(previous.root_room_id) end
        schedule_room_exit(previous.room, previous.room_id, session, previous_id, previous.membership_version)
    end
    return true
end

function CMD.leave(session, id)
    local current = online[id]
    if not current or current.session ~= session then return false end
    local called, exited, leave_err = pcall(skynet.call,
        current.room, "lua", "exit", session, id, current.membership_version)
    if called and exited ~= true and not (exited == false and leave_err == nil) then
        -- Preserve the identity index so a disconnect cleanup can retry after
        -- the Room Actor drains its bounded queue or recovers from a command error.
        return false, leave_err or "room exit was not confirmed"
    end

    -- A dead Room Actor has already lost its in-memory membership. Otherwise,
    -- remove the Directory index only after Room confirms (or idempotently
    -- reports) that the Session is no longer a member.
    online[id] = nil
    touch_room(current.room_id)
    if current.root_room_id ~= current.room_id then touch_room(current.root_room_id) end
    return true
end

function CMD.get_room(room_id, root_room_id)
    return room_for(room_id, root_room_id)
end

function CMD.retire_idle_room(room_id, room)
    if rooms[room_id] ~= room then return true end
    local timeout_ticks = idle_timeout_ticks()
    if timeout_ticks == 0 then return false end
    local last_active = room_last_active[room_id] or skynet.now()
    if skynet.now() - last_active < timeout_ticks then return false end
    local family_root = room_roots[room_id] or room_id
    for _, current in pairs(online) do
        if current.room_id == room_id or current.root_room_id == room_id then
            touch_room(room_id)
            return false
        end
    end
    local family = families[family_root]
    if family then
        local called, room_count = call_actor_with_retry(family, "unregister_room", room_id, room)
        if not called then
            skynet.error("room family unregister failed", room_id, tostring(room_count))
            return false
        end
        if tonumber(room_count) == 0 then
            families[family_root] = nil
            skynet.kill(family)
        end
    end
    rooms[room_id] = nil
    room_roots[room_id] = nil
    room_last_active[room_id] = nil
    room_idle_workers[room_id] = nil
    skynet.kill(room)
    skynet.error("retired idle room actor", room_id)
    return true
end

function CMD.query_sub_room(session, id, root_room_id, message)
    local current = online[id]
    if not current or current.session ~= session or current.root_room_id ~= root_room_id then return false end
    -- The legacy Live path only published sub-room queries from the root
    -- Room. A member in a child Room must not use this command to inspect
    -- sibling Rooms.
    if current.room_id ~= current.root_room_id then return false end
    local requested
    if type(message.subRoom) == "string" then
        requested = message.subRoom
    elseif type(message.subRoom) == "number" then
        local integer = math.tointeger(message.subRoom)
        if integer then requested = tostring(integer) end
    end
    requested = requested or ""
    if requested == "" or #requested > 191 then
        skynet.send(session, "lua", "send", "subRoomVar_Response", {
            subRoom = message.subRoom, keys = message.keys, var = "",
        })
        return true
    end
    local allowed = current.auth_source == "legacy_unverified" and
        skynet.getenv("legacy_sub_rooms_unrestricted") ~= "0"
    if not allowed then
        local aliases = {
            [requested] = true,
            ["r_" .. requested] = true,
            [root_room_id .. ":" .. requested] = true,
        }
        for _, sub_room in ipairs(current.sub_rooms or {}) do
            if aliases[tostring(sub_room)] then allowed = true; break end
        end
    end
    if not allowed then
        skynet.error("sub-room query denied", id, root_room_id, requested, current.auth_source)
        skynet.send(session, "lua", "send", "subRoomVar_Response", {
            subRoom = message.subRoom, keys = message.keys, var = "",
        })
        return false
    end
    local family = family_for(root_room_id)
    local room_id = skynet.call(family, "lua", "resolve_sub_room", message.subRoom)
    if not rooms[room_id] then
        local store = skynet.uniqueservice("store")
        -- The old live-room path matched subRoom against the target Room's
        -- actual room id. Resolve persisted targets in the same order as the
        -- active Actor aliases, so an inactive child is not mistaken for an
        -- absent root:subRoom room.
        local candidates = { requested, "r_" .. requested, root_room_id .. ":" .. requested }
        for _, candidate in ipairs(candidates) do
            if candidate ~= root_room_id and candidate ~= room_id and #candidate <= 191 then
                local has_candidate_state, candidate_err = skynet.call(store, "lua", "room_has_state", candidate)
                if has_candidate_state == nil then
                    skynet.error("sub-room state lookup failed", candidate, tostring(candidate_err))
                    return false
                end
                if has_candidate_state then
                    room_id = candidate
                    break
                end
            end
        end
        local has_state, state_err = skynet.call(store, "lua", "room_has_state", room_id)
        if has_state == nil then
            skynet.error("sub-room state lookup failed", room_id, tostring(state_err))
            return false
        end
        if not has_state then
            skynet.send(session, "lua", "send", "subRoomVar_Response", {
                subRoom = message.subRoom, keys = message.keys, var = "",
            })
            return true
        end
    end
    local room = room_for(room_id, root_room_id)
    local ready, ready_err = prepare_room(room_id, root_room_id, room)
    if not ready then
        skynet.error("sub room preparation failed", room_id, tostring(ready_err))
        return false
    end
    local ok, keys = pcall(json.decode, message.keys or "")
    if not ok or type(keys) ~= "table" then keys = message.keys end
    local called, value = pcall(skynet.call, room, "lua", "get_var_path", keys)
    if not called then return false end
    local encoded
    if value == nil then encoded = ""
    elseif type(value) == "table" then encoded = json.encode(value)
    else encoded = tostring(value) end
    skynet.send(session, "lua", "send", "subRoomVar_Response", {
        subRoom = message.subRoom, keys = message.keys, var = encoded,
    })
    return true
end

function CMD.stats()
    local active = 0
    for _ in pairs(online) do active = active + 1 end
    local room_ids = {}
    for id in pairs(rooms) do room_ids[#room_ids + 1] = id end
    table.sort(room_ids)
    return { active_sessions = active, rooms = json.array(room_ids) }
end

function CMD.queue_metrics()
    local queue = lock_stats()
    queue.outstanding = math.max(0, queue.outstanding - 1)
    local stats = CMD.stats()
    local room_queues = {}
    for _, room_id in ipairs(stats.rooms) do
        local room = rooms[room_id]
        if room then
            local ok, room_metrics = pcall(skynet.call, room, "lua", "queue_metrics")
            if ok and type(room_metrics) == "table" then
                room_queues[#room_queues + 1] = room_metrics
            else
                room_queues[#room_queues + 1] = { room_id = room_id, unavailable = true }
            end
        end
    end
    local family_queues = {}
    for root_room_id, family in pairs(families) do
        local ok, family_metrics = pcall(skynet.call, family, "lua", "queue_metrics")
        if ok and type(family_metrics) == "table" then
            family_queues[#family_queues + 1] = family_metrics
        else
            family_queues[#family_queues + 1] = { root_room_id = root_room_id, unavailable = true }
        end
    end
    table.sort(family_queues, function(a, b)
        return tostring(a.root_room_id) < tostring(b.root_room_id)
    end)
    return {
        queue = queue,
        active_sessions = stats.active_sessions,
        active_rooms = #stats.rooms,
        rooms = json.array(room_queues),
        families = json.array(family_queues),
    }
end

function CMD.maintain_families()
    for root_room_id in pairs(families) do
        local root_room = rooms[root_room_id]
        if root_room then
            local alive, identity = pcall(skynet.call, root_room, "lua", "info")
            if not alive or type(identity) ~= "table" or identity.room_id ~= root_room_id then
                room_for(root_room_id, root_room_id)
            end
        end
        family_for(root_room_id)
    end
    return true
end

function CMD.admin_room_info(room_id)
    local room = rooms[room_id]
    if not room then return nil, "room is not active" end
    return skynet.call(room, "lua", "admin_snapshot")
end

function CMD.admin_room_online_info(room_id, has_history)
    local room = rooms[room_id]
    if not room then return nil, "room is not active" end
    return skynet.call(room, "lua", "admin_online_info", has_history)
end

function CMD.admin_set_room_var(room_id, name, value)
    local room = rooms[room_id]
    if not room then return false, "room is not active" end
    return skynet.call(room, "lua", "admin_update_var", name, value)
end

function CMD.admin_update_room_end_at(room_id, end_at)
    local room = rooms[room_id]
    if not room then return false, "room is not active" end
    return skynet.call(room, "lua", "admin_update_end_at", end_at)
end

function CMD.admin_send_room_event(room_id, event)
    local room = rooms[room_id]
    if not room then return false, "room is not active" end
    return skynet.call(room, "lua", "admin_event", event)
end

function CMD.admin_room_replay(room_id, after_sequence, limit)
    -- Replay reads only durable metadata/events. Do not create a Room Actor or
    -- require one to stay alive after the class has ended.
    local store = skynet.uniqueservice("store")
    local loaded, load_err = skynet.call(store, "lua", "load_room", room_id)
    if not loaded then return nil, load_err or "replay query failed" end
    if not loaded.snapshot then return nil, "replay is not enabled for this room" end

    local decoded, snapshot = pcall(persist_json.decode, loaded.snapshot,
        tonumber(loaded.snapshot_schema_version) or 1)
    if not decoded or type(snapshot) ~= "table" or json.is_null(snapshot) then
        return nil, "stored room snapshot is invalid JSON"
    end
    if snapshot.hasRoomData ~= true then return nil, "replay is not enabled for this room" end
    local start_sequence = tonumber(snapshot.replay_start_sequence)
    if not start_sequence then return nil, "replay start sequence is unavailable" end
    after_sequence = math.max(start_sequence - 1, math.floor(tonumber(after_sequence) or start_sequence - 1))
    local events, err = skynet.call(store, "lua", "room_replay_events", room_id, after_sequence, limit)
    if not events then return nil, err or "replay query failed" end
    local result = {}
    for _, event in ipairs(events) do
        local ok, payload = pcall(persist_json.decode, event.payload_json,
            tonumber(event.schema_version) or 1)
        if not ok or type(payload) ~= "table" or json.is_null(payload) then
            return nil, "stored replay event is invalid JSON"
        end
        result[#result + 1] = {
            sequence = tonumber(event.sequence_no) or 0,
            schema_version = tonumber(event.schema_version) or 1,
            type = event.event_type,
            created_at = tonumber(event.created_ts) or 0,
            payload = payload,
        }
    end
    local next_after = after_sequence
    if #events > 0 then next_after = tonumber(events[#events].sequence_no) or after_sequence end
    return {
        room_id = room_id,
        start_sequence = start_sequence,
        after_sequence = after_sequence,
        next_after_sequence = next_after,
        events = json.array(result),
    }
end

function CMD.admin_close_room(room_id)
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 then
        return false, "invalid room id"
    end
    local store = skynet.uniqueservice("store")
    local saved, save_err = skynet.call(store, "lua", "set_room_closed", room_id, true)
    if not saved then return false, save_err or "room close state could not be saved" end
    local room = rooms[room_id]
    if room then
        local called, closed, close_err = pcall(skynet.call, room, "lua", "admin_close")
        if not called or not closed then
            skynet.error("room actor close failed after durable close", room_id, tostring(close_err or closed))
            return false, close_err or closed or "room actor close failed"
        end
    end
    return true
end

function CMD.admin_open_room(room_id)
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 then
        return false, "invalid room id"
    end
    local store = skynet.uniqueservice("store")
    local saved, save_err = skynet.call(store, "lua", "set_room_closed", room_id, false)
    if not saved then return false, save_err or "room open state could not be saved" end
    local room = rooms[room_id]
    if room then
        local called, opened, open_err = pcall(skynet.call, room, "lua", "admin_open")
        if not called or not opened then
            skynet.error("room actor open failed after durable open", room_id, tostring(open_err or opened))
            return false, open_err or opened or "room actor open failed"
        end
    end
    return true
end

skynet.start(function()
    metrics = skynet.uniqueservice("metrics")
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown directory command " .. tostring(command))
        local args = table.pack(...)
        local command_started = skynet.now()
        local result = table.pack(pcall(function()
            return lock(fn, table.unpack(args, 1, args.n))
        end))
        skynet.send(metrics, "lua", "command_latency", "directory", command, skynet.now() - command_started)
        if session ~= 0 then
            if result[1] then skynet.ret(skynet.pack(table.unpack(result, 2, result.n)))
            else skynet.ret(skynet.pack(false, tostring(result[2]))) end
        elseif not result[1] then
            skynet.error("room directory command failed", command, result[2])
        elseif result[2] == false and type(result[3]) == "string" and result[3]:match(" queue full$") then
            skynet.error("room directory command queue full", command)
        end
    end)
    skynet.fork(function()
        while true do
            skynet.sleep(500)
            local ok, err = pcall(skynet.call, skynet.self(), "lua", "maintain_families")
            if not ok then skynet.error("room family maintenance failed", tostring(err)) end
        end
    end)
end)
