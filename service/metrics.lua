local skynet = require "skynet"
local crypt = require "skynet.crypt"

local CMD = {}
local counters = {
    connections_opened = 0,
    connections_closed = 0,
    login_success = 0,
    login_denied = 0,
    slow_client_disconnects = 0,
}
local sessions = {}
local outbound_packets = 0
local outbound_bytes = 0
local client_command_latency = {}
local database_commit = { count = 0, failures = 0, total_ticks = 0, max_ticks = 0 }
local room_recovery = { count = 0, failures = 0, total_ticks = 0, max_ticks = 0 }
local database_write_failures = 0
local latency_bounds_ms = { 10, 50, 100, 250, 500, 1000, 2500, 5000 }
local subject_hmac_key = crypt.randomkey() .. crypt.randomkey() .. crypt.randomkey() .. crypt.randomkey()

local function nonnegative_ticks(value)
    value = tonumber(value) or 0
    if value ~= value or value < 0 then return 0 end
    return math.floor(value)
end

local function safe_log_value(value)
    return tostring(value):gsub("[%z\1-\31\127]", "?"):sub(1, 191)
end

local function observe_latency(summary, ticks)
    ticks = nonnegative_ticks(ticks)
    summary.count = summary.count + 1
    summary.total_ticks = summary.total_ticks + ticks
    if ticks > summary.max_ticks then summary.max_ticks = ticks end
    summary.buckets = summary.buckets or {}
    local milliseconds = ticks * 10
    for _, bound in ipairs(latency_bounds_ms) do
        if milliseconds <= bound then
            local key = "le_" .. bound .. "ms"
            summary.buckets[key] = (summary.buckets[key] or 0) + 1
        end
    end
    if milliseconds > latency_bounds_ms[#latency_bounds_ms] then
        summary.buckets.gt_5000ms = (summary.buckets.gt_5000ms or 0) + 1
    end
end

local function snapshot_latency(summary)
    local buckets = {}
    for _, bound in ipairs(latency_bounds_ms) do
        local key = "le_" .. bound .. "ms"
        buckets[key] = summary.buckets and summary.buckets[key] or 0
    end
    buckets.gt_5000ms = summary.buckets and summary.buckets.gt_5000ms or 0
    return {
        count = summary.count,
        failures_total = summary.failures or 0,
        total_ms = summary.total_ticks * 10,
        average_ms = summary.count > 0 and summary.total_ticks * 10 / summary.count or 0,
        max_ms = summary.max_ticks * 10,
        cumulative_buckets = buckets,
    }
end

local function get_command_summary(service, command)
    local by_service = client_command_latency[service]
    if not by_service then
        by_service = {}
        client_command_latency[service] = by_service
    end
    local summary = by_service[command]
    if not summary then
        summary = { count = 0, total_ticks = 0, max_ticks = 0, buckets = {} }
        by_service[command] = summary
    end
    return summary
end

function CMD.increment(_, name, amount)
    if counters[name] == nil then return false end
    amount = math.floor(tonumber(amount) or 1)
    counters[name] = math.max(0, counters[name] + amount)
    return true
end

function CMD.session_open(source)
    if sessions[source] then return true end
    sessions[source] = { packets = 0, bytes = 0 }
    counters.connections_opened = counters.connections_opened + 1
    return true
end

function CMD.session_close(source)
    local session = sessions[source]
    if not session then return false end
    outbound_packets = math.max(0, outbound_packets - session.packets)
    outbound_bytes = math.max(0, outbound_bytes - session.bytes)
    sessions[source] = nil
    counters.connections_closed = counters.connections_closed + 1
    return true
end

function CMD.session_queue(source, packets, bytes)
    local session = sessions[source]
    if not session then return false end
    packets = math.max(0, math.floor(tonumber(packets) or 0))
    bytes = math.max(0, math.floor(tonumber(bytes) or 0))
    outbound_packets = math.max(0, outbound_packets + packets - session.packets)
    outbound_bytes = math.max(0, outbound_bytes + bytes - session.bytes)
    session.packets, session.bytes = packets, bytes
    return true
end

function CMD.command_latency(source, service, command, ticks, room_id, subject)
    if type(service) ~= "string" or #service > 64 or type(command) ~= "string" or #command > 128 then
        return false
    end
    observe_latency(get_command_summary(service, command), ticks)
    local latency_ms = nonnegative_ticks(ticks) * 10
    local slow_threshold_ms = tonumber(skynet.getenv("metrics_slow_command_ms")) or 1000
    if service == "client" and latency_ms >= slow_threshold_ms then
        local fields = { "slow client command", command, latency_ms .. "ms", "session_id", tostring(source) }
        if type(room_id) == "string" and room_id ~= "" then
            fields[#fields + 1] = "room_id"
            fields[#fields + 1] = safe_log_value(room_id)
        end
        if type(subject) == "string" and subject ~= "" then
            local pseudonym = crypt.hexencode(crypt.hmac_sha1(subject_hmac_key, subject)):sub(1, 16)
            fields[#fields + 1] = "subject"
            fields[#fields + 1] = pseudonym
        end
        skynet.error(table.unpack(fields))
    end
    return true
end

function CMD.database_commit(_, succeeded, ticks)
    database_commit.count = database_commit.count + 1
    if not succeeded then database_commit.failures = database_commit.failures + 1 end
    observe_latency(database_commit, ticks)
    return true
end

function CMD.database_write_failure()
    database_write_failures = database_write_failures + 1
    return true
end

function CMD.room_recovery(_, room_id, succeeded, ticks)
    if type(room_id) ~= "string" or #room_id > 191 then return false end
    room_recovery.count = room_recovery.count + 1
    if not succeeded then room_recovery.failures = room_recovery.failures + 1 end
    observe_latency(room_recovery, ticks)
    local latency_ms = nonnegative_ticks(ticks) * 10
    local slow_threshold_ms = tonumber(skynet.getenv("metrics_slow_recovery_ms")) or 1000
    if latency_ms >= slow_threshold_ms then
        skynet.error("slow room recovery", "room_id=" .. safe_log_value(room_id), "latency_ms=" .. latency_ms,
            "succeeded=" .. tostring(succeeded == true))
    end
    return true
end

function CMD.snapshot()
    local command_latency = {}
    for service, commands in pairs(client_command_latency) do
        command_latency[service] = {}
        for command, summary in pairs(commands) do
            command_latency[service][command] = snapshot_latency(summary)
        end
    end
    return {
        generated_at = os.time(),
        connections = {
            active = (function() local count = 0; for _ in pairs(sessions) do count = count + 1 end; return count end)(),
            opened_total = counters.connections_opened,
            closed_total = counters.connections_closed,
        },
        logins = {
            success_total = counters.login_success,
            denied_total = counters.login_denied,
        },
        outbound_queue = {
            packets = outbound_packets,
            bytes = outbound_bytes,
            slow_client_disconnects_total = counters.slow_client_disconnects,
        },
        command_latency = command_latency,
        database_commits = snapshot_latency(database_commit),
        database_write_failures_total = database_write_failures,
        room_recoveries = snapshot_latency(room_recovery),
    }
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, command, ...)
        local fn = assert(CMD[command], "unknown metrics command " .. tostring(command))
        local ok, result = pcall(fn, source, ...)
        if session ~= 0 then
            if ok then skynet.ret(skynet.pack(result))
            else skynet.ret(skynet.pack(false, tostring(result))) end
        elseif not ok then
            skynet.error("metrics update failed", command, tostring(result))
        end
    end)
end)
