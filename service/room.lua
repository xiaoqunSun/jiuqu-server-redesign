local skynet = require "skynet"
local bounded_lock = require "bounded_lock"
local json = require "json"
local persist_json = require "persist_json"
local permissions = require "permissions"

local room_id, root_room_id, initial_family_service = ...
assert(room_id and room_id ~= "", "room id is required")
root_room_id = root_room_id or room_id
local family_service = initial_family_service
local room_actor_started_at = os.time()

local CMD = {}
local lock, lock_stats = bounded_lock.new("room_command_queue_max_outstanding", 256, "room command queue full")
local metrics
local store
local sequence = 0
local membership_sequence = 0
local storage_ready = false
local room_closed = false
local members = {}
local session_members = {}
local online_stats = {}
local ONLINE_STATS_INTERVAL = 500
local CURSOR_REPLAY_FLUSH_INTERVAL_MS = math.max(100, math.min(5000,
    tonumber(skynet.getenv("replay_cursor_flush_interval_ms")) or 250))
local CURSOR_REPLAY_FLUSH_INTERVAL_TICKS = math.max(1, math.floor(CURSOR_REPLAY_FLUSH_INTERVAL_MS / 10))
local pending_cursor_replay = {}
local RICHTEXT_EVENT_BEGIN = 9000
local RICHTEXT_EVENT_END = 9099
local end_time_close_applied
local end_time_grace_period = math.max(0, tonumber(skynet.getenv("room_end_grace_period")) or 1800)
local function empty_state()
    return {
        vars = {}, extVars = {}, pages = {}, styles = {}, votes = {},
        next_vote_id = 1, hasRoomData = false, roomData = nil, richtext_docs = {},
        replay_start_sequence = nil, family_sequence = 0, family_event_sequence = 0,
        admin_end_at_override = false, provider_end_at = false,
        family_private_vars = {}, family_synced_vars = {},
        family_private_extvars = {}, family_shared_extvars = {}, family_synced_extvars = {},
    }
end
local state = empty_state()
local richtext_manager
local family_initialized = false
local apply_persisted_event
local MAX_UNIX_TIMESTAMP = 4102444800

local function copy(value)
    if type(value) ~= "table" then return value end
    if json.is_null(value) then return json.null end
    local out = {}
    for key, item in pairs(value) do out[copy(key)] = copy(item) end
    if json.is_array(value) then return json.array(out) end
    return out
end

local function ensure_room_data()
    if type(state.roomData) ~= "table" or json.is_null(state.roomData) then
        state.roomData = { id = room_id }
    end
    state.hasRoomData = true
    return state.roomData
end

local function apply_provider_metadata(metadata)
    local room_data = ensure_room_data()
    room_data.provider_metadata = copy(metadata)

    -- The management API is the authoritative source once it has explicitly
    -- set or cleared a room's end time. Provider refreshes still update their
    -- raw metadata, but cannot undo that operator decision.
    if state.admin_end_at_override then return end

    local raw_end_at = metadata.endAt
    if raw_end_at == nil or json.is_null(raw_end_at) then
        if state.provider_end_at then room_data.endAt = nil end
        state.provider_end_at = false
        return
    end

    local end_at = tonumber(raw_end_at)
    if not end_at or end_at ~= end_at or end_at == math.huge or end_at == -math.huge or
       end_at % 1 ~= 0 or end_at < 0 or end_at > MAX_UNIX_TIMESTAMP then
        skynet.error("recording provider returned invalid endAt", room_id)
        return
    end
    room_data.endAt = end_at
    state.provider_end_at = true
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function record_online_enter(id, begin_at, now)
    local stat = online_stats[id]
    if not stat then
        stat = {
            first_enter_time = now,
            active_time = now,
            enter_history = { now },
            leave_history = {},
            online_duration = 0,
            class_duration = 0,
        }
        online_stats[id] = stat
    else
        stat.enter_history[#stat.enter_history + 1] = now
        stat.active_time = now
    end
    return { begin_at = tonumber(begin_at) or 0, last_stats_at = now }
end

local function accrue_online_time(id, member, now)
    local stat = online_stats[id]
    if not stat then return end
    local previous = tonumber(member.last_stats_at) or now
    local elapsed = math.max(0, now - previous)
    stat.online_duration = stat.online_duration + elapsed
    local class_start = math.max(previous, tonumber(member.begin_at) or 0)
    if now > class_start then
        stat.class_duration = stat.class_duration + now - class_start
    end
    stat.active_time = now
    member.last_stats_at = now
end

local function leave_online_history(id, now)
    local stat = online_stats[id]
    if stat then stat.leave_history[#stat.leave_history + 1] = now end
end

local function scheduled_end_time_if_expired(now)
    if skynet.getenv("is_k12") ~= "1" or type(state.roomData) ~= "table" or
       json.is_null(state.roomData) then return nil end
    local end_at = tonumber(state.roomData.endAt)
    if end_at == nil and state.admin_end_at_override then return nil end
    -- The old server used its Room startup time when provider metadata had no
    -- endAt. Persist that origin on saveRoomData so actor recycling does not
    -- restart the K12 grace window.
    if end_at == nil then
        end_at = tonumber(state.room_started_at) or room_actor_started_at
    end
    if end_at >= 0 and now >= end_at + end_time_grace_period then
        return end_at
    end
end

local function close_after_scheduled_end(end_at)
    if room_closed or end_time_close_applied == end_at then return false end
    end_time_close_applied = end_at
    skynet.error("closing room after scheduled end time", room_id, end_at)
    CMD.admin_close()
    return true
end

local function online_stats_loop()
    while true do
        skynet.sleep(ONLINE_STATS_INTERVAL)
        local ok, err = lock(function()
            local now = os.time()
            for id, member in pairs(members) do accrue_online_time(id, member, now) end
            local end_at = scheduled_end_time_if_expired(now)
            if end_at then close_after_scheduled_end(end_at) end
            return true
        end)
        if not ok then skynet.error("room maintenance skipped", room_id, tostring(err)) end
    end
end

local function send_to(member_id, message, payload)
    local member = members[member_id]
    if member and member.session then
        skynet.send(member.session, "lua", "send", message, payload)
        return true
    end
    return false
end

local function send_session(session, message, payload)
    if session then skynet.send(session, "lua", "send", message, payload); return true end
    return false
end

local function broadcast(message, payload, only_master, sender_id)
    for id, member in pairs(members) do
        if not only_master or member.isMaster or id == sender_id then
            send_to(id, message, payload)
        end
    end
end

local function room_info()
    local info = { studentID = {}, vars = {} }
    for _, id in ipairs(sorted_keys(members)) do info.studentID[#info.studentID + 1] = id end
    for _, name in ipairs(sorted_keys(state.vars)) do
        info.vars[#info.vars + 1] = { name = name, var = tostring(state.vars[name]) }
    end
    return info
end

local function commit(event_type, event_payload)
    if not storage_ready then return false, "room storage unavailable" end
    local next_sequence = sequence + 1
    local ok, saved, err = pcall(skynet.call, store, "lua", "commit_room",
        room_id, next_sequence, event_type, persist_json.encode(event_payload), persist_json.encode(state))
    if not ok then return false, saved end
    if not saved then return false, err or "mysql commit failed" end
    sequence = next_sequence
    return true
end

local function load_state()
    local recovery_started = skynet.now()
    local ok, loaded, load_err = pcall(skynet.call, store, "lua", "load_room", room_id)
    if ok and loaded then
        local old_state, old_sequence = state, sequence
        local base_sequence = tonumber(loaded.sequence) or 0
        local restored = empty_state()
        local restore_ok, restore_err = pcall(function()
            if loaded.snapshot ~= nil then
                local snapshot_version = tonumber(loaded.snapshot_schema_version) or 1
                assert(snapshot_version == 1 or snapshot_version == persist_json.version,
                    "unsupported room snapshot schema version")
                local decoded = persist_json.decode(loaded.snapshot, snapshot_version)
                assert(type(decoded) == "table" and not json.is_null(decoded), "snapshot is not a JSON object")
                restored = decoded
            elseif base_sequence ~= 0 then
                error("snapshot is missing for nonzero sequence")
            end
            local function object_or_empty(value)
                if type(value) == "table" and not json.is_null(value) then return value end
                return {}
            end
            restored.vars = object_or_empty(restored.vars)
            restored.extVars = object_or_empty(restored.extVars)
            restored.pages = object_or_empty(restored.pages)
            restored.styles = object_or_empty(restored.styles)
            restored.votes = object_or_empty(restored.votes)
            restored.next_vote_id = tonumber(restored.next_vote_id) or 1
            if type(restored.roomData) ~= "table" or json.is_null(restored.roomData) then
                restored.roomData = nil
            end
            restored.hasRoomData = restored.roomData ~= nil
            if restored.admin_end_at_override == nil then
                local legacy_end_at = restored.roomData and tonumber(restored.roomData.endAt)
                restored.admin_end_at_override = legacy_end_at ~= nil and legacy_end_at > 0 or false
            else
                restored.admin_end_at_override = restored.admin_end_at_override == true
            end
            restored.provider_end_at = restored.provider_end_at == true and not restored.admin_end_at_override
            restored.room_started_at = tonumber(restored.room_started_at)
            if restored.roomData and not restored.room_started_at then
                restored.room_started_at = room_actor_started_at
            end
            restored.replay_start_sequence = tonumber(restored.replay_start_sequence)
            restored.richtext_docs = object_or_empty(restored.richtext_docs)
            restored.family_sequence = tonumber(restored.family_sequence) or 0
            restored.family_event_sequence = tonumber(restored.family_event_sequence) or 0
            restored.family_private_vars = object_or_empty(restored.family_private_vars)
            restored.family_synced_vars = object_or_empty(restored.family_synced_vars)
            restored.family_private_extvars = object_or_empty(restored.family_private_extvars)
            restored.family_shared_extvars = object_or_empty(restored.family_shared_extvars)
            restored.family_synced_extvars = object_or_empty(restored.family_synced_extvars)

            state, sequence = restored, base_sequence
            richtext_manager = nil
            assert(type(loaded.events or {}) == "table" and not json.is_null(loaded.events), "room event tail is invalid")
            for _, event in ipairs(loaded.events or {}) do
                local event_sequence = tonumber(event.sequence_no)
                assert(event_sequence == sequence + 1, "room event sequence gap")
                local event_version = tonumber(event.schema_version) or 1
                assert(event_version == 1 or event_version == persist_json.version,
                    "unsupported room event schema version")
                local payload = persist_json.decode(event.payload_json, event_version)
                assert(type(payload) == "table" and not json.is_null(payload), "room event payload is not an object")
                assert(apply_persisted_event, "room event reducer is unavailable")
                apply_persisted_event(event.event_type, payload)
                sequence = event_sequence
            end
        end)
        if restore_ok then
            richtext_manager = nil
            storage_ready = true
        else
            state, sequence = old_state, old_sequence
            richtext_manager = nil
            skynet.error("room state recovery failed", room_id, tostring(restore_err))
            storage_ready = false
        end
    elseif ok and loaded == nil and load_err == nil then
        state = empty_state()
        sequence = 0
        richtext_manager = nil
        storage_ready = true
    else
        skynet.error("room storage unavailable", room_id, load_err or loaded)
        storage_ready = false
    end
    if metrics then
        skynet.send(metrics, "lua", "room_recovery", room_id, storage_ready, skynet.now() - recovery_started)
    end
    return storage_ready
end

local function mutate(event_type, event_payload, fn)
    local before = copy(state)
    local result = table.pack(pcall(fn))
    if not result[1] then
        state = before
        richtext_manager = nil
        return false, result[2]
    end

    -- Serialization can fail before Store sees the command (for example, an
    -- invalid value introduced by a future command handler). Treat that like
    -- a failed write so the in-memory aggregate never gets ahead of MySQL.
    local commit_called, ok, err = pcall(commit, event_type, event_payload)
    if not commit_called then
        state = before
        richtext_manager = nil
        skynet.error("room event serialization failed", room_id, event_type, tostring(ok))
        return false, ok
    end
    if not ok then
        local recovery_called, recovered = pcall(load_state)
        if not recovery_called or not recovered then
            state = before
            richtext_manager = nil
        end
        skynet.error("room state commit failed", room_id, event_type, err)
        return false, err
    end
    return true, table.unpack(result, 2, result.n)
end

local function remove_matching_paths(map, name, separator)
    for path in pairs(map) do
        if path == name or path:sub(1, #name + #separator) == name .. separator then
            map[path] = nil
        end
    end
end

local function record_var_family_scope(name, value, family_shared, family_sequence)
    if value == "null" then
        remove_matching_paths(state.family_private_vars, name, ".")
        remove_matching_paths(state.family_synced_vars, name, ".")
        return
    end
    if family_sequence then
        state.family_private_vars[name] = nil
        state.family_synced_vars[name] = true
    elseif family_shared == false then
        state.family_private_vars[name] = true
        state.family_synced_vars[name] = nil
    elseif family_shared == true then
        state.family_private_vars[name] = nil
    end
end

local function record_extvar_family_scope(name, value, is_merge, family_shared, family_sequence)
    if value == "null" then
        remove_matching_paths(state.family_private_extvars, name, "@")
        remove_matching_paths(state.family_shared_extvars, name, "@")
        remove_matching_paths(state.family_synced_extvars, name, "@")
        return
    end
    if family_sequence then
        state.family_private_extvars[name] = nil
        state.family_synced_extvars[name] = true
    elseif family_shared == false then
        state.family_private_extvars[name] = true
        remove_matching_paths(state.family_shared_extvars, name, "@")
        state.family_synced_extvars[name] = nil
    elseif family_shared == true then
        if not is_merge then
            remove_matching_paths(state.family_private_extvars, name, "@")
        end
        state.family_shared_extvars[name] = true
    end
end

local function family_path_overlaps(map, name, separator)
    for path in pairs(map) do
        if path == name or path:sub(1, #name + #separator) == name .. separator or
           name:sub(1, #path + #separator) == path .. separator then
            return true
        end
    end
    return false
end

local function advance_family_sequence(family_sequence, family_event_sequence)
    family_sequence = tonumber(family_sequence)
    family_event_sequence = tonumber(family_event_sequence)
    local advance_state = family_sequence and family_sequence > (state.family_sequence or 0)
    local advance_events = family_event_sequence and
        family_event_sequence > (state.family_event_sequence or 0)
    if not advance_state and not advance_events then return true end
    return mutate("family_checkpoint", {
        family_sequence = family_sequence,
        family_event_sequence = family_event_sequence,
    }, function()
        if family_sequence then
            state.family_sequence = math.max(state.family_sequence or 0, family_sequence)
        end
        if family_event_sequence then
            state.family_event_sequence = math.max(state.family_event_sequence or 0, family_event_sequence)
        end
    end)
end

local function update_var(name, value, only_master, sender_id, family_sequence)
    if type(name) ~= "string" or name == "" then return false end
    value = tostring(value or "")
    local ok = mutate("room_var", { name = name, value = value, family_shared = not only_master, family_sequence = family_sequence }, function()
        if family_sequence then state.family_sequence = family_sequence end
        record_var_family_scope(name, value, not only_master, family_sequence)
        if value == "null" then
            for key in pairs(state.vars) do
                if key == name or key:sub(1, #name + 1) == name .. "." then state.vars[key] = nil end
            end
        else
            state.vars[name] = value
        end
    end)
    if not ok then return false end
    local response = { name = name, var = value }
    broadcast("updateVar_Response", response, only_master, sender_id)
    if room_id == root_room_id and not only_master and family_service then
        skynet.send(family_service, "lua", "publish", room_id, "updateVar_Response", response, sender_id, sequence)
    end
    return true
end

local function merge_tables(target, patch)
    for key, value in pairs(patch) do
        if json.is_null(value) then
            target[key] = json.null
        elseif type(value) == "table" and type(target[key]) == "table" and not json.is_null(target[key]) then
            merge_tables(target[key], value)
        elseif value == "null" then
            target[key] = nil
        else
            target[key] = copy(value)
        end
    end
end

local function get_path(value, path)
    local current = value
    local parts = {}
    if type(path) == "table" then
        for _, part in ipairs(path) do parts[#parts + 1] = part end
    elseif type(path) == "string" then
        for part in path:gmatch("[^@]+") do parts[#parts + 1] = part end
    else
        return nil
    end
    for _, part in ipairs(parts) do
        if type(current) ~= "table" or json.is_null(current) then return nil end
        current = current[part]
    end
    return current
end

local function set_path(value, path, next_value, merge)
    local parts = {}
    for part in path:gmatch("[^@]+") do parts[#parts + 1] = part end
    if #parts == 0 then return end
    local current = value
    for i = 1, #parts - 1 do
        local key = parts[i]
        if type(current[key]) ~= "table" or json.is_null(current[key]) then current[key] = {} end
        current = current[key]
    end
    local key = parts[#parts]
    if next_value == nil then
        current[key] = nil
    elseif merge and type(current[key]) == "table" and type(next_value) == "table" then
        merge_tables(current[key], next_value)
    else
        current[key] = copy(next_value)
    end
end

local function ext_response(name, value, is_table, is_merge, sender)
    local encoded
    if type(value) == "table" then encoded = json.encode(value)
    elseif value == nil then encoded = ""
    else encoded = tostring(value) end
    return {
        name = name, var = encoded, varIsTable = is_table or false,
        isMerge = is_merge or false, sender = sender,
    }
end

local function page_nodes(page_id)
    local page = state.pages[tostring(page_id)]
    local out = { nodes = {} }
    if page and page.nodes then
        for _, id in ipairs(sorted_keys(page.nodes)) do
            out.nodes[#out.nodes + 1] = copy(page.nodes[id])
        end
    end
    return out
end

local function vote_info(vote, player_id, include_detail)
    if not vote then return nil, {} end
    local result = copy(vote.result)
    local selected = {}
    if result then
        if not include_detail then result.detail_results = {} end
        for _, detail in ipairs(vote.result.detail_results or {}) do
            if detail.player_id == player_id then
                selected = copy(detail.option_ids)
                break
            end
        end
    end
    return {
        id = vote.id, allow_multiple = vote.allow_multiple,
        state = vote.state, title = vote.title, creator_id = vote.creator_id,
        student_count = vote.student_count, options = copy(vote.options), result = result,
    }, selected
end

local function check_login_eligibility()
    if not storage_ready and not load_state() then
        return false, "storage unavailable"
    end
    if room_closed then return false, "room is closed" end
    local expired_end_at = scheduled_end_time_if_expired(os.time())
    if expired_end_at and end_time_close_applied ~= expired_end_at then
        close_after_scheduled_end(expired_end_at)
        return false, "room end time has passed"
    end
    return true
end

function CMD.can_enter()
    return check_login_eligibility()
end

function CMD.enter(session, id, is_master, begin_at, auth_source)
    local eligible, eligibility_err = check_login_eligibility()
    if not eligible then return false, eligibility_err end
    local now = os.time()
    local previous = members[id]
    local stats_member
    if previous then
        accrue_online_time(id, previous, now)
        session_members[previous.session] = nil
        stats_member = { begin_at = tonumber(begin_at) or 0, last_stats_at = now }
    else
        stats_member = record_online_enter(id, begin_at, now)
    end
    membership_sequence = membership_sequence + 1
    local membership_version = membership_sequence
    members[id] = {
        session = session,
        membership_version = membership_version,
        isMaster = is_master == true,
        auth_source = auth_source or "legacy_unverified",
        begin_at = stats_member.begin_at,
        last_stats_at = stats_member.last_stats_at,
    }
    session_members[session] = id
    local response = {
        error = 0,
        roominfo = room_info(),
        hasRoomData = state.hasRoomData == true,
        replay_start_sequence = state.replay_start_sequence,
    }
    skynet.send(session, "lua", "send", "loginResponse", response)
    broadcast("onMemEnterRoom", { id = id })
    return true, begin_at or 0, membership_version
end

function CMD.exit(session, id, membership_version)
    local member = members[id]
    if not member or member.session ~= session or
       (membership_version ~= nil and member.membership_version ~= membership_version) then
        return false
    end
    local now = os.time()
    accrue_online_time(id, member, now)
    leave_online_history(id, now)
    members[id] = nil
    session_members[session] = nil
    broadcast("onMemLeaveRoom", { id = id })
    return true
end

function CMD.ready()
    if not storage_ready and not load_state() then
        return false, "storage unavailable"
    end
    return true
end

function CMD.update_var(name, value, only_master, sender_id)
    return update_var(name, value, only_master, sender_id)
end

function CMD.add_var(sender_id, name, count, clamp_min, clamp_max)
    local current = tonumber(state.vars[name]) or 0
    local minimum = clamp_min or 0
    local maximum = clamp_max or 0xffffffff
    local value = math.max(math.min(current + count, maximum), minimum)
    local text = tostring(value)
    if not update_var(name, text, false, sender_id) then return false end
    send_to(sender_id, "addVar_Response", { name = name, value = value })
    return true
end

function CMD.update_ext_var(name, value, var_is_table, is_merge, only_master, sender_id, family_sequence)
    if type(name) ~= "string" or name == "" then return false end
    local parsed = value
    if value == "null" then
        parsed = nil
    elseif var_is_table then
        local ok, decoded = pcall(json.decode, value)
        if not ok then return false end
        parsed = decoded
    end
    local ok = mutate("extended_var", { name = name, value = value, varIsTable = var_is_table, isMerge = is_merge, family_shared = not only_master, family_sequence = family_sequence }, function()
        if family_sequence then state.family_sequence = family_sequence end
        record_extvar_family_scope(name, value, is_merge == true, not only_master, family_sequence)
        set_path(state.extVars, name, parsed, is_merge == true)
    end)
    if not ok then return false end
    local response = ext_response(name, value, var_is_table, is_merge, sender_id)
    broadcast("updateExtVar_Response", response, only_master, sender_id)
    if room_id == root_room_id and not only_master and family_service then
        skynet.send(family_service, "lua", "publish", room_id, "updateExtVar_Response", response, sender_id, sequence)
    end
    return true
end

function CMD.query_ext_var(session, name)
    local value = get_path(state.extVars, name)
    local encoded
    if value == nil then encoded = ""
    elseif type(value) == "table" then encoded = json.encode(value)
    else encoded = tostring(value) end
    send_session(session, "queryExtVar_Response", {
        name = name, var = encoded,
    })
    return true
end

function CMD.event(message, sender_id)
    local response, broadcast_event
    if message.id >= RICHTEXT_EVENT_BEGIN and message.id < RICHTEXT_EVENT_END then
        local richtext = require "richtext_manager"
        richtext_manager = richtext_manager or richtext.new(state.richtext_docs)
        response, broadcast_event = richtext_manager:process(message, sender_id)
        if not response then return true end
        local docs = richtext_manager:snapshot()
        local replay_payload = copy(response)
        replay_payload.broadcast = broadcast_event == true
        local ok = mutate("richtext_event", replay_payload, function()
            state.richtext_docs = docs
        end)
        if not ok then
            richtext_manager = richtext.new(state.richtext_docs)
            return false
        end
    else
        response = { id = message.id, var = message.var }
        broadcast_event = true
        local replay_payload = copy(response)
        replay_payload.broadcast = true
        local ok = mutate("class_event", replay_payload, function() end)
        if not ok then return false end
    end
    if broadcast_event then
        broadcast("event_Response", response)
        if room_id == root_room_id and family_service then
            skynet.send(family_service, "lua", "publish", room_id, "event_Response", response, sender_id, sequence)
        end
    else
        send_to(sender_id, "event_Response", response)
    end
    return true
end

function CMD.update_cursor(message, sender_id)
    local response = copy(message)
    response.sender = sender_id
    broadcast("updateCursorPosition_Response", response)
    if room_id == root_room_id and family_service then
        skynet.send(family_service, "lua", "publish", room_id,
            "updateCursorPosition_Response", response, sender_id)
    end
    -- Record cursors throughout the Room Actor lifetime, like the old server's
    -- rolling replay files. Enabling replay later controls export, not capture.
    -- Keep only the latest position per identity until the room-wide flush.
    pending_cursor_replay[sender_id] = { sender = sender_id, cursor = copy(response) }
    return true
end

function CMD.flush_cursor_replay()
    local identities = sorted_keys(pending_cursor_replay)
    if #identities == 0 then return true end

    local updates = json.array()
    local batch = pending_cursor_replay
    for _, id in ipairs(identities) do updates[#updates + 1] = batch[id] end
    pending_cursor_replay = {}

    local saved, err = mutate("cursor_presence_batch", { updates = updates }, function() end)
    if not saved then
        -- Room commands are serialized, so no newer batch can overtake this one.
        pending_cursor_replay = batch
        return false, err
    end
    return true
end

function CMD.save_room_data(message, sender_id)
    local ok, data = pcall(json.decode, message.data or "")
    if not ok or type(data) ~= "table" then return false end
    local replay_start_sequence = state.replay_start_sequence
    if data.replayMode == 1 and not replay_start_sequence then
        -- The old server captured replay streams from Room startup and only
        -- decided whether to retain/export them when saveRoomData arrived.
        replay_start_sequence = 1
    end
    local room_started_at = tonumber(state.room_started_at) or room_actor_started_at
    local saved = mutate("room_metadata", {
        replayMode = data.replayMode,
        versions = data.versions,
        replay_start_sequence = replay_start_sequence,
        room_started_at = room_started_at,
    }, function()
        state.room_started_at = room_started_at
        if type(data.versions) == "table" and not json.is_null(data.versions) then
            state.versions = copy(data.versions)
        end
        if data.replayMode == 1 then
            local replay_id = room_id:match("^r_(%d+)")
            state.roomData = state.roomData or {
                replayMode = 1,
                id = replay_id and tonumber(replay_id) or room_id,
            }
            state.roomData.replayMode = 1
            state.hasRoomData = true
            state.replay_start_sequence = replay_start_sequence
        end
    end)
    if not saved then return false end

    -- Only a server-configured provider may interpret this opaque token.
    -- The client-supplied data.api is intentionally never forwarded.
    if data.replayMode ~= 1 and type(data.token) == "string" and data.token ~= "" then
        local provider = skynet.uniqueservice("recording_provider")
        skynet.send(provider, "lua", "fetch", skynet.self(), {
            room_id = room_id,
            identity_id = sender_id,
            token = data.token,
            replay_mode = data.replayMode,
            versions = type(data.versions) == "table" and copy(data.versions) or {},
        })
    end
    return true
end

function CMD.provider_result(metadata)
    if type(metadata) ~= "table" or json.is_null(metadata) then return false end
    for key in pairs(metadata) do
        if type(key) ~= "string" then return false end
    end
    local ok, encoded = pcall(json.encode, metadata)
    if not ok or type(encoded) ~= "string" or #encoded > 65536 then return false end
    return mutate("provider_metadata", { metadata = metadata }, function()
        if type(state.roomData) ~= "table" or json.is_null(state.roomData) then
            state.roomData = { id = room_id }
        end
        apply_provider_metadata(metadata)
    end)
end

function CMD.chat_replay(sender_id, message)
    if type(message) ~= "table" or
       type(message.text) ~= "string" or type(message.channels) ~= "table" then
        return false
    end
    local ok = commit("chat_replay", { sender = sender_id, text = message.text, channels = message.channels })
    return ok
end

function CMD.get_var_path(path)
    local parts = path
    if type(path) == "string" then
        local ok, decoded = pcall(json.decode, path)
        if ok and type(decoded) == "table" then parts = decoded
        else
            parts = {}
            for part in path:gmatch("[^%.]+") do parts[#parts + 1] = part end
        end
    end
    local current = state.vars
    for _, key in ipairs(parts or {}) do
        if type(current) == "string" then
            local ok, decoded = pcall(json.decode, current)
            if ok then current = decoded end
        end
        if type(current) ~= "table" then return nil end
        current = current[key]
    end
    return current
end

function CMD.sub_room_var(session, message)
    local value = get_path(state.vars, message.keys)
    local encoded
    if value == nil then encoded = ""
    elseif type(value) == "table" then encoded = json.encode(value)
    else encoded = tostring(value) end
    send_session(session, "subRoomVar_Response", {
        subRoom = message.subRoom, keys = message.keys, var = encoded,
    })
end

function CMD.page_update(sender_id, message)
    local key = tostring(message.pageId)
    local ok = mutate("whiteboard_update", message, function()
        local page = state.pages[key] or { nodes = {} }
        state.pages[key] = page
        for _, patch in ipairs(message.nodes or {}) do
            local node_key = tostring(patch.id)
            local node = page.nodes[node_key]
            if not node then
                page.nodes[node_key] = copy(patch)
            else
                for field, value in pairs(patch) do
                    if field == "userPoints" then
                        node.userPoints = node.userPoints or {}
                        for _, point in ipairs(value) do node.userPoints[#node.userPoints + 1] = copy(point) end
                    elseif field == "simplifyPoints" then
                        node.simplifyPoints = copy(value)
                        node.userPoints = {}
                    else
                        node[field] = copy(value)
                    end
                end
            end
        end
        for _, node_id in ipairs(message.nodesDeleted or {}) do page.nodes[tostring(node_id)] = nil end
    end)
    if not ok then return false end
    broadcast("pageUpdate_Response", {
        senderId = sender_id, pageId = message.pageId,
        nodes = message.nodes or {}, nodesDeleted = message.nodesDeleted or {},
    })
    return true
end

function CMD.page_copy(sender_id, from, to)
    local ok = mutate("whiteboard_copy", { from = from, to = to }, function()
        local original = state.pages[tostring(from)]
        state.pages[tostring(to)] = original and copy(original) or nil
    end)
    if not ok then return false end
    broadcast("pageCopy_Response", { from = from, to = to, senderId = sender_id })
    return true
end

function CMD.page_query(session, page_id)
    -- The legacy whiteboard query returns an empty page for an unknown id.
    send_session(session, "pageQuery_Response", { pageId = page_id, page = page_nodes(page_id) })
    return true
end

function CMD.style_add(sender_id, message)
    local style = message.style
    local ok = mutate("whiteboard_style", style, function()
        state.styles[tostring(style.id)] = copy(style)
    end)
    if not ok then return false end
    broadcast("styleAdd_Response", { style = copy(style) })
    return true
end

function CMD.style_query(session)
    local styles = {}
    for _, id in ipairs(sorted_keys(state.styles)) do styles[#styles + 1] = copy(state.styles[id]) end
    send_session(session, "styleQuery_Response", { styles = styles })
end

function CMD.create_vote(sender_id, message)
    local id = state.next_vote_id
    local vote = {
        id = id, allow_multiple = message.allow_multiple,
        state = "active", title = message.title, creator_id = sender_id,
        student_count = message.student_count, options = copy(message.options or {}),
        result = { id = id, total_votes = 0, option_results = {}, detail_results = {} },
    }
    for _, option in ipairs(vote.options) do
        vote.result.option_results[#vote.result.option_results + 1] = { id = option.id, vote_count = 0, percentage = 0 }
    end
    local ok = mutate("vote_created", vote, function()
        state.votes[tostring(id)] = vote
        state.next_vote_id = id + 1
    end)
    if not ok then return false end
    broadcast("createVote_Response", { id = id, info = vote_info(vote, sender_id, true) })
    return true
end

local function change_vote_state(sender_id, message, target, response_name)
    local vote = state.votes[tostring(message.id)]
    if vote then
        local ok = mutate("vote_state", { id = message.id, state = target }, function()
            vote.state = target
        end)
        if not ok then return false end
    end
    broadcast(response_name, { id = message.id })
    return true
end

function CMD.end_vote(sender_id, message)
    return change_vote_state(sender_id, message, "ended", "endVote_Response")
end

function CMD.close_vote(sender_id, message)
    return change_vote_state(sender_id, message, "closed", "closeVote_Response")
end

function CMD.submit_vote(session, sender_id, message)
    local vote = state.votes[tostring(message.id)]
    local failure
    if not vote then failure = "投票不存在"
    elseif vote.state ~= "active" then failure = "投票已结束"
    elseif not vote.allow_multiple and #(message.option_ids or {}) > 1 then failure = "此投票不支持多选"
    else
        for _, option_id in ipairs(message.option_ids or {}) do
            local found = false
            for _, option in ipairs(vote.options) do if option.id == option_id then found = true; break end end
            if not found then failure = "无效的选项ID: " .. tostring(option_id); break end
        end
        for _, detail in ipairs(vote.result.detail_results or {}) do
            if detail.player_id == sender_id then failure = "玩家已经投过票"; break end
        end
    end
    if failure then
        send_session(session, "submitVote_Response", { success = false, error_msg = failure })
        return false
    end
    local selected = copy(message.option_ids or {})
    local ok = mutate("vote_submitted", { id = message.id, player_id = sender_id, option_ids = selected }, function()
        vote.result.detail_results[#vote.result.detail_results + 1] = { player_id = sender_id, option_ids = selected }
        vote.result.total_votes = vote.result.total_votes + #selected
        for _, option_id in ipairs(selected) do
            for _, item in ipairs(vote.result.option_results) do
                if item.id == option_id then item.vote_count = item.vote_count + 1; break end
            end
        end
        for _, item in ipairs(vote.result.option_results) do
            item.percentage = vote.result.total_votes > 0 and (item.vote_count / vote.result.total_votes * 100) or 0
        end
    end)
    local response = { success = ok }
    if not ok then response.error_msg = "存储失败" end
    send_session(session, "submitVote_Response", response)
    return ok
end

function CMD.query_vote(session, sender_id, message)
    local id = message.id
    if id == 0 then id = state.next_vote_id - 1 end
    local info, selected = vote_info(state.votes[tostring(id)], sender_id, message.include_detail)
    send_session(session, "queryVote_Response", { info = info, option_ids = selected })
end

apply_persisted_event = function(event_type, payload)
    if event_type == "family_sync" then
        state.vars = type(payload.vars) == "table" and copy(payload.vars) or {}
        state.extVars = type(payload.extVars) == "table" and copy(payload.extVars) or {}
        state.richtext_docs = type(payload.richtext_docs) == "table" and copy(payload.richtext_docs) or {}
        state.family_sequence = tonumber(payload.family_sequence) or state.family_sequence or 0
        state.family_event_sequence = tonumber(payload.family_event_sequence) or
            state.family_event_sequence or 0
        state.family_private_vars = type(payload.family_private_vars) == "table" and copy(payload.family_private_vars) or {}
        state.family_synced_vars = type(payload.family_synced_vars) == "table" and copy(payload.family_synced_vars) or {}
        state.family_private_extvars = type(payload.family_private_extvars) == "table" and copy(payload.family_private_extvars) or {}
        state.family_shared_extvars = type(payload.family_shared_extvars) == "table" and copy(payload.family_shared_extvars) or {}
        state.family_synced_extvars = type(payload.family_synced_extvars) == "table" and copy(payload.family_synced_extvars) or {}
    elseif event_type == "room_var" then
        local name = assert(payload.name, "room variable event has no name")
        local value = tostring(payload.value or "")
        if value == "null" then
            for key in pairs(state.vars) do
                if key == name or key:sub(1, #name + 1) == name .. "." then state.vars[key] = nil end
            end
        else
            state.vars[name] = value
        end
        if payload.family_sequence then state.family_sequence = tonumber(payload.family_sequence) or state.family_sequence end
        record_var_family_scope(name, value, payload.family_shared, payload.family_sequence)
    elseif event_type == "extended_var" then
        local value = payload.value
        if value == "null" then
            value = nil
        elseif payload.varIsTable then
            value = json.decode(value)
        end
        set_path(state.extVars, assert(payload.name, "extended variable event has no name"), value, payload.isMerge == true)
        if payload.family_sequence then state.family_sequence = tonumber(payload.family_sequence) or state.family_sequence end
        record_extvar_family_scope(payload.name, payload.value, payload.isMerge == true,
            payload.family_shared, payload.family_sequence)
    elseif event_type == "richtext_event" then
        local message = { id = tonumber(payload.id), var = payload.var }
        assert(message.id and message.var, "invalid RichText event")
        local event_data = json.decode(message.var)
        local uid = type(event_data) == "table" and event_data.uid or ""
        local richtext = require "richtext_manager"
        richtext_manager = richtext_manager or richtext.new(state.richtext_docs)
        local response = richtext_manager:process(message, uid)
        assert(response, "unsupported RichText event")
        state.richtext_docs = richtext_manager:snapshot()
        if payload.family_sequence then state.family_sequence = tonumber(payload.family_sequence) or state.family_sequence end
    elseif event_type == "class_event" then
        local family_sequence = tonumber(payload.family_sequence)
        if family_sequence then
            state.family_sequence = math.max(state.family_sequence or 0, family_sequence)
            state.family_event_sequence = math.max(state.family_event_sequence or 0, family_sequence)
        end
        -- Class events are replayed to active family members from the root log.
    elseif event_type == "chat_replay" or
           event_type == "cursor_presence_batch" then
        if payload.family_sequence then
            state.family_sequence = math.max(state.family_sequence or 0,
                tonumber(payload.family_sequence) or 0)
        end
        -- These records are retained for audit/replay consumers, not room state.
    elseif event_type == "family_checkpoint" then
        state.family_sequence = math.max(state.family_sequence or 0, tonumber(payload.family_sequence) or 0)
        state.family_event_sequence = math.max(state.family_event_sequence or 0,
            tonumber(payload.family_event_sequence) or 0)
    elseif event_type == "provider_metadata" then
        assert(type(payload.metadata) == "table" and not json.is_null(payload.metadata),
            "provider metadata event is invalid")
        apply_provider_metadata(payload.metadata)
    elseif event_type == "room_end_time" then
        ensure_room_data()
        local end_at = tonumber(payload.endAt) or 0
        state.roomData.endAt = end_at > 0 and end_at or nil
        state.admin_end_at_override = true
        state.provider_end_at = false
    elseif event_type == "room_metadata" then
        state.room_started_at = tonumber(payload.room_started_at) or
            state.room_started_at or room_actor_started_at
        if type(payload.versions) == "table" and not json.is_null(payload.versions) then
            state.versions = copy(payload.versions)
        end
        if payload.replayMode == 1 then
            local replay_id = room_id:match("^r_(%d+)")
            if type(state.roomData) ~= "table" or json.is_null(state.roomData) then
                state.roomData = {}
            end
            state.roomData.replayMode = 1
            state.roomData.id = replay_id and tonumber(replay_id) or room_id
            state.hasRoomData = true
            state.replay_start_sequence = tonumber(payload.replay_start_sequence) or state.replay_start_sequence or (sequence + 1)
        end
    elseif event_type == "whiteboard_update" then
        local key = tostring(payload.pageId)
        local page = state.pages[key] or { nodes = {} }
        state.pages[key] = page
        for _, patch in ipairs(payload.nodes or {}) do
            local node_key = tostring(patch.id)
            local node = page.nodes[node_key]
            if not node then
                page.nodes[node_key] = copy(patch)
            else
                for field, value in pairs(patch) do
                    if field == "userPoints" then
                        node.userPoints = node.userPoints or {}
                        for _, point in ipairs(value) do node.userPoints[#node.userPoints + 1] = copy(point) end
                    elseif field == "simplifyPoints" then
                        node.simplifyPoints = copy(value)
                        node.userPoints = {}
                    else
                        node[field] = copy(value)
                    end
                end
            end
        end
        for _, node_id in ipairs(payload.nodesDeleted or {}) do page.nodes[tostring(node_id)] = nil end
    elseif event_type == "whiteboard_copy" then
        local original = state.pages[tostring(payload.from)]
        state.pages[tostring(payload.to)] = original and copy(original) or nil
    elseif event_type == "whiteboard_style" then
        state.styles[tostring(payload.id)] = copy(payload)
    elseif event_type == "vote_created" then
        local vote = copy(payload)
        local id = tonumber(vote.id)
        assert(id, "vote-created event has no id")
        state.votes[tostring(id)] = vote
        state.next_vote_id = math.max(state.next_vote_id, id + 1)
    elseif event_type == "vote_state" then
        local vote = state.votes[tostring(payload.id)]
        if vote then vote.state = payload.state end
    elseif event_type == "vote_submitted" then
        local vote = assert(state.votes[tostring(payload.id)], "vote submission references missing vote")
        local selected = copy(payload.option_ids or {})
        local result = assert(vote.result, "vote has no result")
        result.detail_results = result.detail_results or {}
        result.option_results = result.option_results or {}
        result.detail_results[#result.detail_results + 1] = {
            player_id = payload.player_id, option_ids = selected,
        }
        result.total_votes = (tonumber(result.total_votes) or 0) + #selected
        for _, option_id in ipairs(selected) do
            for _, item in ipairs(result.option_results) do
                if item.id == option_id then item.vote_count = (tonumber(item.vote_count) or 0) + 1; break end
            end
        end
        for _, item in ipairs(result.option_results) do
            item.percentage = result.total_votes > 0 and (item.vote_count / result.total_votes * 100) or 0
        end
    else
        error("unknown room event type " .. tostring(event_type))
    end
end

function CMD.info()
    return { room_id = room_id, root_room_id = root_room_id, sequence = sequence, member_count = #sorted_keys(members) }
end

function CMD.queue_metrics()
    local queue = lock_stats()
    queue.outstanding = math.max(0, queue.outstanding - 1)
    return {
        room_id = room_id,
        member_count = #sorted_keys(members),
        queue = queue,
    }
end

local function deep_equal(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if json.is_null(left) or json.is_null(right) then return false end
    for key, value in pairs(left) do
        if not deep_equal(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function changed_keys(left, right)
    local keys = {}
    for key in pairs(left) do keys[key] = true end
    for key in pairs(right) do keys[key] = true end
    return sorted_keys(keys)
end

local function notify_family_sync(previous)
    for _, name in ipairs(changed_keys(previous.vars, state.vars)) do
        local old_value, new_value = previous.vars[name], state.vars[name]
        if not deep_equal(old_value, new_value) then
            broadcast("updateVar_Response", {
                name = name,
                var = new_value == nil and "null" or tostring(new_value),
            })
        end
    end

    local ext_paths = {}
    for path in pairs(previous.family_synced_extvars) do ext_paths[path] = true end
    for path in pairs(state.family_synced_extvars) do ext_paths[path] = true end
    for _, path in ipairs(sorted_keys(ext_paths)) do
        local old_value = get_path(previous.extVars, path)
        local new_value = get_path(state.extVars, path)
        if not deep_equal(old_value, new_value) then
            local encoded, is_table
            if new_value == nil or json.is_null(new_value) then
                encoded, is_table = "null", false
            elseif type(new_value) == "table" then
                encoded, is_table = json.encode(new_value), true
            else
                encoded, is_table = tostring(new_value), false
            end
            broadcast("updateExtVar_Response", {
                name = path, var = encoded, varIsTable = is_table, isMerge = false,
            })
        end
    end

    local changed_docs = changed_keys(previous.richtext_docs, state.richtext_docs)
    local manager = require("richtext_manager").new(state.richtext_docs)
    for _, doc_id in ipairs(changed_docs) do
        local old_doc, new_doc = previous.richtext_docs[doc_id], state.richtext_docs[doc_id]
        if not deep_equal(old_doc, new_doc) then
            if new_doc == nil then
                broadcast("event_Response", { id = 9007, var = json.encode({ id = doc_id }) })
            else
                for member_id in pairs(members) do
                    local response = manager:process({ id = 9006, var = json.encode({ id = doc_id }) }, member_id)
                    if response then send_to(member_id, "event_Response", response) end
                end
            end
        end
    end
end

function CMD.set_family_service(service)
    family_service = service
    return true
end

function CMD.family_snapshot()
    local vars = {}
    for name, value in pairs(state.vars) do
        local private = false
        for path in pairs(state.family_private_vars) do
            if name == path or name:sub(1, #path + 1) == path .. "." then
                private = true
                break
            end
        end
        if not private then vars[name] = copy(value) end
    end
    local ext_vars = copy(state.extVars)
    for path in pairs(state.family_private_extvars) do set_path(ext_vars, path, nil, false) end
    return {
        vars = vars,
        extVars = ext_vars,
        richtext_docs = copy(state.richtext_docs),
        family_shared_extvars = copy(state.family_shared_extvars),
        sequence = sequence,
    }
end

function CMD.family_sync(snapshot)
    if room_id == root_room_id or type(snapshot) ~= "table" then return true end
    local family_sequence = tonumber(snapshot.sequence) or 0
    if family_sequence < (state.family_sequence or 0) then return true end
    local vars = type(snapshot.vars) == "table" and copy(snapshot.vars) or {}
    local ext_vars = type(snapshot.extVars) == "table" and copy(snapshot.extVars) or {}
    local richtext_docs = type(snapshot.richtext_docs) == "table" and copy(snapshot.richtext_docs) or {}
    local synced_vars = {}
    for name in pairs(vars) do synced_vars[name] = true end
    local synced_extvars = type(snapshot.family_shared_extvars) == "table" and copy(snapshot.family_shared_extvars) or {}
    if sequence > 0 then
        local merged_vars, merged_ext_vars = copy(state.vars), copy(state.extVars)
        for name in pairs(state.family_synced_vars) do
            if not synced_vars[name] and not state.family_private_vars[name] then merged_vars[name] = nil end
        end
        for path in pairs(state.family_synced_extvars) do
            if not synced_extvars[path] and
               not family_path_overlaps(state.family_private_extvars, path, "@") then
                set_path(merged_ext_vars, path, nil, false)
            end
        end
        for name, value in pairs(vars) do
            -- A child room may have a master-only value with the same key as
            -- a root-room value. Keep that local value while still tracking
            -- the root key so a later root deletion does not erase it.
            if not state.family_private_vars[name] then merged_vars[name] = copy(value) end
        end
        for path in pairs(synced_extvars) do
            if not family_path_overlaps(state.family_private_extvars, path, "@") then
                set_path(merged_ext_vars, path, get_path(ext_vars, path), false)
            end
        end
        vars, ext_vars = merged_vars, merged_ext_vars
    else
        local shared_ext_vars = {}
        for path in pairs(synced_extvars) do
            set_path(shared_ext_vars, path, get_path(ext_vars, path), false)
        end
        ext_vars = shared_ext_vars
    end
    if deep_equal(state.vars, vars) and deep_equal(state.extVars, ext_vars) and
       deep_equal(state.richtext_docs, richtext_docs) and
       deep_equal(state.family_synced_vars, synced_vars) and
       deep_equal(state.family_synced_extvars, synced_extvars) then
        -- Reconcile the in-memory delivery watermark without writing a
        -- no-op snapshot. This also makes late duplicate deliveries harmless.
        state.family_sequence = math.max(state.family_sequence or 0, family_sequence)
        if not family_initialized or next(members) == nil then
            state.family_event_sequence = math.max(state.family_event_sequence or 0, family_sequence)
        end
        family_initialized = true
        return true
    end
    local previous = {
        vars = copy(state.vars),
        extVars = copy(state.extVars),
        richtext_docs = copy(state.richtext_docs),
        family_synced_extvars = copy(state.family_synced_extvars),
    }
    local family_event_sequence = state.family_event_sequence or 0
    if not family_initialized or next(members) == nil then
        -- With no live members, old classroom events are not replayed to the
        -- next login; establish the event watermark at the current root view.
        family_event_sequence = math.max(family_event_sequence, family_sequence)
    end
    local ok, err = mutate("family_sync", {
        vars = vars, extVars = ext_vars, richtext_docs = richtext_docs,
        family_sequence = family_sequence,
        family_event_sequence = family_event_sequence,
        family_private_vars = copy(state.family_private_vars),
        family_synced_vars = synced_vars,
        family_private_extvars = copy(state.family_private_extvars),
        family_shared_extvars = synced_extvars,
        family_synced_extvars = synced_extvars,
    }, function()
        state.vars = vars
        state.extVars = ext_vars
        state.richtext_docs = richtext_docs
        state.family_private_vars = copy(state.family_private_vars)
        state.family_synced_vars = synced_vars
        state.family_private_extvars = copy(state.family_private_extvars)
        state.family_shared_extvars = copy(synced_extvars)
        state.family_synced_extvars = copy(synced_extvars)
        richtext_manager = nil
        state.family_sequence = math.max(state.family_sequence or 0, family_sequence)
        state.family_event_sequence = family_event_sequence
    end)
    if not ok then return false, err end
    family_initialized = true
    local notified, notify_err = pcall(notify_family_sync, previous)
    if not notified then skynet.error("room family state notification failed", room_id, tostring(notify_err)) end
    return true
end

function CMD.family_sync_status()
    return {
        sequence = sequence,
        family_sequence = state.family_sequence or 0,
        family_event_sequence = state.family_event_sequence or 0,
        member_count = #sorted_keys(members),
        initialized = family_initialized,
    }
end

function CMD.family_advance_event_sequence(family_event_sequence)
    if room_id == root_room_id then return false end
    return advance_family_sequence(state.family_sequence, family_event_sequence)
end

function CMD.family_delivery(message, payload, sender_id, family_sequence)
    if room_id == root_room_id then return false end
    if message == "updateCursorPosition_Response" then
        return CMD.update_cursor(payload, sender_id)
    end
    family_sequence = tonumber(family_sequence)
    local event_id = message == "event_Response" and type(payload) == "table" and tonumber(payload.id)
    local replayable_class_event = message == "event_Response" and event_id ~= nil and
        (event_id < RICHTEXT_EVENT_BEGIN or event_id >= RICHTEXT_EVENT_END)
    if family_sequence then
        local watermark = replayable_class_event and (state.family_event_sequence or 0) or
            (state.family_sequence or 0)
        if family_sequence <= watermark then return true end
    end
    if message == "updateVar_Response" then
        if type(payload) == "table" and type(payload.name) == "string" then
            local exact_private = state.family_private_vars[payload.name] == true
            local deleting_private_descendants = payload.var == "null" and
                family_path_overlaps(state.family_private_vars, payload.name, ".")
            if exact_private or deleting_private_descendants then
                return advance_family_sequence(family_sequence)
            end
        end
        return update_var(payload.name, payload.var, false, sender_id, family_sequence)
    elseif message == "updateExtVar_Response" then
        if type(payload) == "table" and type(payload.name) == "string" and
           family_path_overlaps(state.family_private_extvars, payload.name, "@") then
            return advance_family_sequence(family_sequence)
        end
        return CMD.update_ext_var(payload.name, payload.var, payload.varIsTable,
            payload.isMerge, false, payload.sender or sender_id, family_sequence)
    elseif message == "event_Response" then
        local event_payload = copy(payload)
        event_payload.broadcast = true
        event_payload.family_sequence = family_sequence
        local event_id = tonumber(payload.id)
        local event_type = event_id and event_id >= RICHTEXT_EVENT_BEGIN and event_id < RICHTEXT_EVENT_END and
            "richtext_event" or "class_event"
        local ok = mutate(event_type, event_payload, function()
            if event_type == "richtext_event" then
                apply_persisted_event(event_type, event_payload)
            elseif family_sequence then
                state.family_sequence = math.max(state.family_sequence or 0, family_sequence)
                state.family_event_sequence = math.max(state.family_event_sequence or 0, family_sequence)
            end
        end)
        if not ok then
            local richtext = require "richtext_manager"
            richtext_manager = richtext.new(state.richtext_docs)
            return false
        end
        broadcast("event_Response", { id = payload.id, var = payload.var })
        return true
    end
    return false
end

function CMD.admin_snapshot()
    local member_ids = {}
    for _, id in ipairs(sorted_keys(members)) do member_ids[#member_ids + 1] = id end
    local page_count, vote_count = 0, 0
    for _ in pairs(state.pages) do page_count = page_count + 1 end
    for _ in pairs(state.votes) do vote_count = vote_count + 1 end
    return {
        room_id = room_id,
        root_room_id = root_room_id,
        sequence = sequence,
        member_count = #member_ids,
        members = json.array(member_ids),
        vars = copy(state.vars),
        extVars = copy(state.extVars),
        page_count = page_count,
        vote_count = vote_count,
        hasRoomData = state.hasRoomData == true,
        replay_start_sequence = state.replay_start_sequence,
        roomData = copy(state.roomData),
    }
end

function CMD.admin_online_info(has_history)
    local now = os.time()
    for id, member in pairs(members) do accrue_online_time(id, member, now) end

    local include_history = has_history == true or has_history == 1 or
        has_history == "1" or has_history == "true"
    local result = {}
    for id, stat in pairs(online_stats) do
        if include_history then
            local full = copy(stat)
            full.enter_history = json.array(copy(stat.enter_history))
            full.leave_history = json.array(copy(stat.leave_history))
            result[id] = full
        else
            result[id] = {
                online_duration = stat.online_duration,
                class_duration = stat.class_duration,
                active_time = stat.active_time,
                first_enter_time = stat.first_enter_time,
            }
        end
    end
    return result
end

function CMD.admin_update_var(name, value)
    if type(name) ~= "string" or name == "" or type(value) ~= "string" then
        return false, "invalid room variable"
    end
    return update_var(name, value, false, nil)
end

function CMD.admin_update_end_at(end_at)
    end_at = tonumber(end_at)
    if not end_at or end_at % 1 ~= 0 or end_at < 0 or end_at > MAX_UNIX_TIMESTAMP then
        return false, "end_at must be an integer Unix timestamp between 0 and 4102444800"
    end
    return mutate("room_end_time", { endAt = end_at }, function()
        local room_data = ensure_room_data()
        room_data.endAt = end_at > 0 and end_at or nil
        state.admin_end_at_override = true
        state.provider_end_at = false
    end)
end

function CMD.admin_event(message)
    if type(message) ~= "table" or type(message.id) ~= "number" or type(message.var) ~= "string" then
        return false, "invalid room event"
    end
    return CMD.event(message, "admin")
end

function CMD.admin_close()
    room_closed = true
    for id, member in pairs(members) do
        send_to(id, "kickOut", {})
        if member.session then skynet.send(member.session, "lua", "close_after_flush") end
    end
    return true
end

function CMD.admin_open()
    room_closed = false
    return true
end

skynet.start(function()
    metrics = skynet.uniqueservice("metrics")
    local member_commands = {
        update_var = true, add_var = true, update_ext_var = true, query_ext_var = true,
        event = true, update_cursor = true, save_room_data = true, chat_replay = true,
        sub_room_var = true, page_update = true, page_copy = true, page_query = true,
        style_add = true, style_query = true, create_vote = true, end_vote = true,
        close_vote = true, submit_vote = true, query_vote = true,
    }
    local sender_argument = {
        update_var = 4, add_var = 1, update_ext_var = 6, event = 2,
        update_cursor = 2, save_room_data = 2, chat_replay = 1, page_update = 1, page_copy = 1,
        style_add = 1, create_vote = 1, end_vote = 1, close_vote = 1,
        submit_vote = 2, query_vote = 2,
    }
    local recipient_argument = {
        query_ext_var = 1, sub_room_var = 1, page_query = 1,
        style_query = 1, submit_vote = 1, query_vote = 1,
    }
    store = skynet.uniqueservice("store")
    load_state()
    skynet.fork(online_stats_loop)
    skynet.fork(function()
        while true do
            skynet.sleep(CURSOR_REPLAY_FLUSH_INTERVAL_TICKS)
            if next(pending_cursor_replay) then
                local called, saved, err = pcall(skynet.call, skynet.self(), "lua", "flush_cursor_replay")
                if not called or not saved then
                    skynet.error("cursor replay flush failed", room_id, tostring(err or saved))
                end
            end
        end
    end)

    skynet.dispatch("lua", function(session, source, command, ...)
        local fn = assert(CMD[command], "unknown room command " .. tostring(command))
        local args = table.pack(...)
        local command_started = skynet.now()
        local result = table.pack(pcall(function()
            return lock(function()
                if member_commands[command] then
                    local id = session_members[source]
                    local member = id and members[id]
                    if not member or member.session ~= source then
                        return false, "session is not an active room member"
                    end
                    if room_closed then return false, "room is closed" end
                    local allowed, reason = permissions.check(member, command)
                    if not allowed then
                        skynet.error("room command denied", room_id, command, member.auth_source, reason)
                        return false, reason
                    end
                    local sender_index = sender_argument[command]
                    if sender_index then args[sender_index] = id end
                    local recipient_index = recipient_argument[command]
                    if recipient_index then args[recipient_index] = source end
                    if command == "query_vote" and type(args[3]) == "table" then
                        local query = copy(args[3])
                        query.include_detail = query.include_detail == true and permissions.can_view_vote_details(member)
                        args[3] = query
                    end
                end
                return fn(table.unpack(args, 1, args.n))
            end)
        end))
        skynet.send(metrics, "lua", "command_latency", "room", command, skynet.now() - command_started)
        if session ~= 0 then
            if result[1] then skynet.ret(skynet.pack(table.unpack(result, 2, result.n)))
            else skynet.ret(skynet.pack(nil, tostring(result[2]))) end
        elseif not result[1] then
            skynet.error("room command failed", room_id, command, result[2])
        elseif result[2] == false and result[3] == "room command queue full" then
            skynet.error("room command queue full", room_id, command)
        end
    end)
    skynet.error("Room Actor ready", room_id, "sequence", sequence)
end)
