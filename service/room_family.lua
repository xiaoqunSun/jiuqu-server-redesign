local skynet = require "skynet"
local json = require "json"
local persist_json = require "persist_json"
local bounded_lock = require "bounded_lock"

local root_room_id = ...
assert(type(root_room_id) == "string" and root_room_id ~= "", "root room id is required")

local rooms = {}
local lock, lock_stats = bounded_lock.new("family_command_queue_max_outstanding", 512,
    "room family command queue full")
local CMD = {}
local replay_class_events
local publish_class_event_to_child
local RICHTEXT_EVENT_BEGIN = 9000
local RICHTEXT_EVENT_END = 9099

function CMD.identity()
    return root_room_id
end

function CMD.register_room(room_id, room)
    assert(type(room_id) == "string" and room_id ~= "", "room id is required")
    assert(room ~= nil, "room actor is required")
    rooms[room_id] = room
    return true
end

function CMD.unregister_room(room_id, room)
    if rooms[room_id] == room then rooms[room_id] = nil end
    local count = 0
    for _ in pairs(rooms) do count = count + 1 end
    return count
end

function CMD.resolve_sub_room(sub_room)
    local value = tostring(sub_room)
    local candidates = { value, "r_" .. value, root_room_id .. ":" .. value }
    for _, candidate in ipairs(candidates) do
        if candidate ~= root_room_id and rooms[candidate] then return candidate end
    end
    return root_room_id .. ":" .. value
end

function CMD.publish(origin_room_id, message, payload, sender_id, family_sequence)
    if origin_room_id ~= root_room_id then return false end
    local event_id = message == "event_Response" and type(payload) == "table" and tonumber(payload.id)
    local is_class_event = event_id ~= nil and
        (event_id < RICHTEXT_EVENT_BEGIN or event_id >= RICHTEXT_EVENT_END)
    for room_id, room in pairs(rooms) do
        if room_id ~= root_room_id then
            if is_class_event and tonumber(family_sequence) then
                publish_class_event_to_child(room_id, room, tonumber(family_sequence))
            else
                skynet.send(room, "lua", "family_delivery", message, payload, sender_id, family_sequence)
            end
        end
    end
    return true
end

function CMD.room_count()
    local count = 0
    for _ in pairs(rooms) do count = count + 1 end
    return count
end

function CMD.queue_metrics()
    local queue = lock_stats()
    queue.outstanding = math.max(0, queue.outstanding - 1)
    return { root_room_id = root_room_id, queue = queue }
end

replay_class_events = function(child_room_id, child, after_sequence, through_sequence)
    after_sequence = tonumber(after_sequence) or 0
    through_sequence = tonumber(through_sequence) or 0
    if after_sequence >= through_sequence then return true end

    local store = skynet.uniqueservice("store")
    local processed = 0
    while after_sequence < through_sequence do
        local called, events, query_err = pcall(skynet.call, store, "lua", "room_family_events",
            root_room_id, after_sequence, through_sequence, 500)
        if not called or type(events) ~= "table" then
            skynet.error("room family event query failed", child_room_id,
                tostring(query_err or events))
            return false
        end
        if #events == 0 then return true end

        local previous_sequence = after_sequence
        for _, event in ipairs(events) do
            local event_sequence = tonumber(event.sequence_no)
            if not event_sequence or event_sequence <= after_sequence or event_sequence > through_sequence then
                skynet.error("invalid room family event sequence", child_room_id,
                    tostring(event.sequence_no))
                return false
            end
            local decoded, payload = pcall(persist_json.decode, event.payload_json,
                tonumber(event.schema_version) or 1)
            if not decoded or type(payload) ~= "table" or json.is_null(payload) then
                skynet.error("invalid persisted room family event", child_room_id,
                    tostring(event_sequence))
                return false
            end
            if payload.broadcast ~= true then
                skynet.error("persisted room family event is not broadcastable", child_room_id,
                    tostring(event_sequence))
                return false
            end
            local delivered, result, delivery_err = pcall(skynet.call, child,
                "lua", "family_delivery", "event_Response", payload, nil, event_sequence)
            if not delivered or result ~= true then
                skynet.error("room family event delivery failed", child_room_id,
                    tostring(event_sequence), tostring(delivery_err or result))
                return false
            end
            after_sequence = event_sequence
            processed = processed + 1
            if processed >= 2000 and after_sequence < through_sequence then
                -- Resume from the child's durable watermark on the next
                -- reconciliation cycle so one old room cannot monopolize the
                -- coordinator indefinitely.
                return false
            end
        end
        if after_sequence <= previous_sequence then
            skynet.error("room family event query did not advance", child_room_id)
            return false
        end
        if #events < 500 then return true end
    end
    return true
end

local function checkpoint_event_watermark(child_room_id, child, family_event_sequence)
    local checkpoint_ok, checkpointed, checkpoint_err = pcall(skynet.call, child,
        "lua", "family_advance_event_sequence", family_event_sequence)
    if not checkpoint_ok or not checkpointed then
        skynet.error("room family event watermark checkpoint failed", child_room_id,
            tostring(checkpoint_err or checkpointed))
        return false
    end
    return true
end

publish_class_event_to_child = function(child_room_id, child, family_sequence)
    local status_ok, status = pcall(skynet.call, child, "lua", "family_sync_status")
    if not status_ok or type(status) ~= "table" then
        skynet.error("room family status query failed", child_room_id, tostring(status))
        return false
    end
    if (tonumber(status.member_count) or 0) == 0 then return true end

    local after_sequence = tonumber(status.family_event_sequence) or 0
    if after_sequence >= family_sequence then return true end
    if not replay_class_events(child_room_id, child, after_sequence, family_sequence) then
        return false
    end
    return checkpoint_event_watermark(child_room_id, child, family_sequence)
end

local function reconcile_child(snapshot, child_room_id, child)
    local status_ok, status = pcall(skynet.call, child, "lua", "family_sync_status")
    if not status_ok or type(status) ~= "table" then
        skynet.error("room family status query failed", child_room_id, tostring(status))
        return false
    end

    local target_sequence = tonumber(snapshot.sequence) or 0
    if status.initialized == true and (tonumber(status.member_count) or 0) > 0 and
       (tonumber(status.family_event_sequence) or 0) < target_sequence then
        if not replay_class_events(child_room_id, child, status.family_event_sequence, target_sequence) then
            return false
        end
        if not checkpoint_event_watermark(child_room_id, child, target_sequence) then return false end
    end

    local synced_ok, synced = pcall(skynet.call, child, "lua", "family_sync", snapshot)
    if not synced_ok or not synced then
        skynet.error("room family snapshot reconciliation failed", child_room_id,
            tostring(synced))
        return false
    end
    return true
end

local function reconcile_children()
    local root = rooms[root_room_id]
    if not root then return end

    local root_ok, snapshot = pcall(skynet.call, root, "lua", "family_snapshot")
    if not root_ok or type(snapshot) ~= "table" then return end

    -- Snapshot the handles before yielding so registration changes do not
    -- mutate the table being traversed while Room Actors are called.
    local children = {}
    for room_id, room in pairs(rooms) do
        if room_id ~= root_room_id then
            children[#children + 1] = { room_id = room_id, room = room }
        end
    end
    for _, child in ipairs(children) do
        if rooms[child.room_id] == child.room then
            reconcile_child(snapshot, child.room_id, child.room)
        end
    end
end

function CMD.reconcile_room(room_id)
    if room_id == root_room_id then return true end
    local root, child = rooms[root_room_id], rooms[room_id]
    if not root or not child then return false, "room is not registered with family" end
    local root_ok, snapshot = pcall(skynet.call, root, "lua", "family_snapshot")
    if not root_ok or type(snapshot) ~= "table" then
        return false, "root family snapshot unavailable"
    end
    return reconcile_child(snapshot, room_id, child)
end

function CMD.reconcile()
    reconcile_children()
    return true
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown family command " .. tostring(command))
        local args = table.pack(...)
        local result = table.pack(pcall(function()
            return lock(fn, table.unpack(args, 1, args.n))
        end))
        if session ~= 0 then
            if result[1] then skynet.ret(skynet.pack(table.unpack(result, 2, result.n)))
            else skynet.ret(skynet.pack(false, tostring(result[2]))) end
        elseif not result[1] then
            skynet.error("room family command failed", root_room_id, command, result[2])
        elseif result[2] == false and type(result[3]) == "string" and
               result[3]:match(" queue full$") then
            skynet.error("room family command queue full", root_room_id, command)
        end
    end)
    skynet.fork(function()
        while true do
            skynet.sleep(500)
            local ok, result = pcall(skynet.call, skynet.self(), "lua", "reconcile")
            if not ok or not result then
                skynet.error("room family reconciliation failed", root_room_id, tostring(result))
            end
        end
    end)
end)
