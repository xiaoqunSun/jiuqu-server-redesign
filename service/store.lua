local skynet = require "skynet"
local bounded_lock = require "bounded_lock"
local mysql = require "skynet.db.mysql"
local persist_json = require "persist_json"

local CMD = {}
local lock, lock_stats = bounded_lock.new("store_command_queue_max_outstanding", 512, "store command queue full")
local db
local metrics
local schema_ready = false
local config

local function reset_db()
    if db then pcall(db.disconnect, db) end
    db = nil
    schema_ready = false
end

local function connect()
    if db then return true end
    local ok, client = pcall(mysql.connect, config)
    if not ok then
        skynet.error("mysql connect failed", client)
        return false, client
    end
    db = client
    return true
end

local function query(sql)
    local ok, err = connect()
    if not ok then return nil, err end
    local called, result = pcall(db.query, db, sql)
    if not called then
        reset_db()
        return nil, result
    end
    if result and result.badresult then
        local message = result.err or "mysql query failed"
        reset_db()
        return nil, message
    end
    return result
end

local function transaction_query(sql)
    local is_commit = sql == "COMMIT"
    local started = is_commit and skynet.now() or nil
    local function finish(result, err)
        if is_commit then
            skynet.send(metrics, "lua", "database_commit",
                result ~= nil and result ~= false, skynet.now() - started)
        end
        return result, err
    end
    local ok, err = connect()
    if not ok then return finish(nil, err) end
    local called, result = pcall(db.query, db, sql)
    if not called then
        reset_db()
        return finish(nil, result)
    end
    if result and result.badresult then
        return finish(nil, result.err or "mysql transaction query failed")
    end
    return finish(result)
end

local function committed_query(sql)
    local started = skynet.now()
    local result, err = query(sql)
    skynet.send(metrics, "lua", "database_commit",
        result ~= nil and result ~= false, skynet.now() - started)
    return result, err
end

local function rollback_transaction()
    if not db then return end
    local called, result = pcall(db.query, db, "ROLLBACK")
    if not called or (result and result.badresult) then reset_db() end
end

local function quote(value)
    return mysql.quote_sql_str(tostring(value or ""))
end

local function quote_binary(value)
    return "FROM_BASE64(" .. quote(persist_json.base64_encode(tostring(value or ""))) .. ")"
end

local function ensure_column(table_name, column_name, definition)
    local rows, err = query(string.format(
        "SELECT COUNT(*) AS present FROM information_schema.columns " ..
        "WHERE table_schema=DATABASE() AND table_name=%s AND column_name=%s",
        quote(table_name), quote(column_name)))
    if not rows then return false, err end
    if rows[1] and tonumber(rows[1].present) > 0 then return true end
    local result, alter_err = query(string.format(
        "ALTER TABLE `%s` ADD COLUMN `%s` %s", table_name, column_name, definition))
    return result ~= nil, alter_err
end

local function ensure_binary_column(table_name, column_name)
    local rows, err = query(string.format(
        "SELECT DATA_TYPE AS data_type FROM information_schema.columns " ..
        "WHERE table_schema=DATABASE() AND table_name=%s AND column_name=%s LIMIT 1",
        quote(table_name), quote(column_name)))
    if not rows then return false, err end
    if not rows[1] then return false, "required binary column is missing" end
    if tostring(rows[1].data_type):lower() == "blob" then return true end
    local result, alter_err = query(string.format(
        "ALTER TABLE `%s` MODIFY COLUMN `%s` BLOB NOT NULL", table_name, column_name))
    return result ~= nil, alter_err
end

local function ensure_schema()
    if schema_ready then return true end
    local statements = {
        [[CREATE TABLE IF NOT EXISTS room_events (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            room_id VARBINARY(191) NOT NULL,
            sequence_no BIGINT UNSIGNED NOT NULL,
            event_type VARCHAR(64) NOT NULL,
            schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            payload_json LONGTEXT NOT NULL,
            created_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (id), UNIQUE KEY uq_room_sequence (room_id, sequence_no),
            KEY idx_room_created (room_id, created_ts)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        [[CREATE TABLE IF NOT EXISTS room_snapshots (
            room_id VARBINARY(191) NOT NULL,
            sequence_no BIGINT UNSIGNED NOT NULL,
            schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            snapshot_json LONGTEXT NOT NULL,
            updated_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (room_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        [[CREATE TABLE IF NOT EXISTS chat_messages (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            channel VARBINARY(128) NOT NULL,
            sender VARBINARY(255) NOT NULL,
            message_text BLOB NOT NULL,
            created_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (id), KEY idx_channel_id (channel, id),
            KEY idx_channel_created (channel, created_ts)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        [[CREATE TABLE IF NOT EXISTS access_tokens (
            token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            identity_id VARBINARY(255) NOT NULL,
            room_id VARBINARY(191) NOT NULL,
            root_room_id VARBINARY(191) NOT NULL,
            is_master TINYINT UNSIGNED NOT NULL DEFAULT 0,
            begin_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
            expires_at BIGINT UNSIGNED NULL,
            revoked_at BIGINT UNSIGNED NULL,
            created_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (token_hash, room_id),
            KEY idx_access_identity (identity_id, room_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        [[CREATE TABLE IF NOT EXISTS access_token_chat_channels (
            token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            room_id VARBINARY(191) NOT NULL,
            channel VARBINARY(128) NOT NULL,
            created_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (token_hash, room_id, channel),
            KEY idx_access_channel (room_id, channel)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        [[CREATE TABLE IF NOT EXISTS access_token_sub_rooms (
            token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            room_id VARBINARY(191) NOT NULL,
            sub_room VARBINARY(191) NOT NULL,
            created_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (token_hash, room_id, sub_room),
            KEY idx_access_sub_room (room_id, sub_room)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
        [[CREATE TABLE IF NOT EXISTS room_lifecycle (
            room_id VARBINARY(191) NOT NULL,
            is_closed TINYINT UNSIGNED NOT NULL DEFAULT 0,
            updated_ts BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (room_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]],
    }
    for _, statement in ipairs(statements) do
        local result, err = query(statement)
        if not result then return false, err end
    end
    for _, column in ipairs({
        { "room_events", "schema_version", "SMALLINT UNSIGNED NOT NULL DEFAULT 1" },
        { "room_snapshots", "schema_version", "SMALLINT UNSIGNED NOT NULL DEFAULT 1" },
    }) do
        local ensured, err = ensure_column(column[1], column[2], column[3])
        if not ensured then return false, err end
    end
    local binary_column_ready, binary_column_err = ensure_binary_column("chat_messages", "message_text")
    if not binary_column_ready then return false, binary_column_err end
    schema_ready = true
    return true
end

function CMD.ready()
    return ensure_schema()
end

function CMD.queue_metrics()
    local queue = lock_stats()
    queue.outstanding = math.max(0, queue.outstanding - 1)
    return queue
end

function CMD.load_room(room_id)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    local rows, query_err = query("SELECT sequence_no, schema_version, snapshot_json FROM room_snapshots WHERE room_id=" .. quote_binary(room_id) .. " LIMIT 1")
    if not rows then return nil, query_err end
    local row = rows[1]
    local sequence = row and (tonumber(row.sequence_no) or 0) or 0
    local snapshot = row and row.snapshot_json or nil
    local events, events_err = query(string.format(
        "SELECT sequence_no, schema_version, event_type, payload_json FROM room_events WHERE room_id=%s AND sequence_no > %d ORDER BY sequence_no ASC",
        quote_binary(room_id), sequence))
    if not events then return nil, events_err end
    return {
        sequence = sequence,
        snapshot_schema_version = row and tonumber(row.schema_version) or 1,
        snapshot = snapshot,
        events = events,
    }
end

function CMD.room_has_state(room_id)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    local rows, query_err = query("SELECT room_id FROM room_snapshots WHERE room_id=" .. quote_binary(room_id) .. " LIMIT 1")
    if not rows then return nil, query_err end
    return rows[1] ~= nil
end

function CMD.room_is_closed(room_id)
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 then
        return nil, "invalid room id"
    end
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    local rows, query_err = query("SELECT is_closed FROM room_lifecycle WHERE room_id=" .. quote_binary(room_id) .. " LIMIT 1")
    if not rows then return nil, query_err end
    return rows[1] ~= nil and tonumber(rows[1].is_closed) == 1 or false
end

function CMD.set_room_closed(room_id, is_closed)
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 or type(is_closed) ~= "boolean" then
        return false, "invalid room lifecycle state"
    end
    local ok, err = ensure_schema()
    if not ok then return false, err end
    local result, query_err = committed_query(string.format(
        "INSERT INTO room_lifecycle (room_id, is_closed, updated_ts) VALUES (%s, %d, %d) " ..
        "ON DUPLICATE KEY UPDATE is_closed=VALUES(is_closed), updated_ts=VALUES(updated_ts)",
        quote_binary(room_id), is_closed and 1 or 0, os.time()))
    return result ~= nil, query_err
end

function CMD.commit_room(room_id, sequence, event_type, payload_json, snapshot_json)
    local ok, err = ensure_schema()
    if not ok then return false, err end
    local now = os.time()
    local statements = {
        string.format("INSERT INTO room_events (room_id, sequence_no, event_type, schema_version, payload_json, created_ts) VALUES (%s, %d, %s, %d, %s, %d)",
            quote_binary(room_id), sequence, quote(event_type), persist_json.version, quote(payload_json), now),
        string.format("INSERT INTO room_snapshots (room_id, sequence_no, schema_version, snapshot_json, updated_ts) VALUES (%s, %d, %d, %s, %d) ON DUPLICATE KEY UPDATE sequence_no=VALUES(sequence_no), schema_version=VALUES(schema_version), snapshot_json=VALUES(snapshot_json), updated_ts=VALUES(updated_ts)",
            quote_binary(room_id), sequence, persist_json.version, quote(snapshot_json), now),
    }
    local started, start_err = transaction_query("START TRANSACTION")
    if not started then return false, start_err end
    for _, statement in ipairs(statements) do
        local result, query_err = transaction_query(statement)
        if not result then
            rollback_transaction()
            return false, query_err
        end
    end
    local committed, commit_err = transaction_query("COMMIT")
    if committed then return true end

    -- A lost response to COMMIT leaves its outcome unknown. Reconnect and
    -- compare the atomically committed snapshot before deciding to reject;
    -- this keeps the Room Actor sequence aligned with MySQL.
    rollback_transaction()
    reset_db()
    local recovered, load_err = CMD.load_room(room_id)
    if recovered and tonumber(recovered.sequence) == sequence and recovered.snapshot == snapshot_json then
        return true
    end
    return false, commit_err or load_err or "mysql commit outcome is unknown"
end

function CMD.room_replay_events(room_id, after_sequence, limit)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    after_sequence = math.max(0, math.floor(tonumber(after_sequence) or 0))
    limit = math.max(1, math.min(math.floor(tonumber(limit) or 500), 500))
    local rows, query_err = query(string.format(
        "SELECT sequence_no, schema_version, event_type, payload_json, created_ts FROM room_events " ..
        "WHERE room_id=%s AND sequence_no > %d ORDER BY sequence_no ASC LIMIT %d",
        quote_binary(room_id), after_sequence, limit))
    if not rows then return nil, query_err end
    return rows
end

function CMD.room_family_events(room_id, after_sequence, through_sequence, limit)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    after_sequence = math.max(0, math.floor(tonumber(after_sequence) or 0))
    through_sequence = math.max(after_sequence, math.floor(tonumber(through_sequence) or after_sequence))
    limit = math.max(1, math.min(math.floor(tonumber(limit) or 500), 500))
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 then
        return nil, "invalid room id"
    end
    local rows, query_err = query(string.format(
        "SELECT sequence_no, schema_version, event_type, payload_json, created_ts FROM room_events " ..
        "WHERE room_id=%s AND event_type='class_event' AND sequence_no > %d AND sequence_no <= %d " ..
        "ORDER BY sequence_no ASC LIMIT %d",
        quote_binary(room_id), after_sequence, through_sequence, limit))
    if not rows then return nil, query_err end
    return rows
end

function CMD.save_chat_batch(channels, sender, text, timestamp)
    local ok, err = ensure_schema()
    if not ok then return false, err end
    if type(channels) ~= "table" or #channels == 0 then return false, "chat channels are required" end
    local now = tonumber(timestamp) or os.time()
    local started, start_err = transaction_query("START TRANSACTION")
    if not started then return false, start_err end
    for _, channel in ipairs(channels) do
        local result, query_err = transaction_query(string.format(
            "INSERT INTO chat_messages (channel, sender, message_text, created_ts) VALUES (%s, %s, FROM_BASE64(%s), %d)",
            quote_binary(channel), quote_binary(sender), quote(persist_json.base64_encode(text)), now))
        if not result then
            rollback_transaction()
            return false, query_err
        end
    end
    local committed, commit_err = transaction_query("COMMIT")
    if committed then return true end
    rollback_transaction()
    return false, commit_err or "chat commit outcome is unknown"
end

function CMD.save_chat(channel, sender, text, timestamp)
    local ok, err = ensure_schema()
    if not ok then return false, err end
    local result, query_err = committed_query(string.format(
        "INSERT INTO chat_messages (channel, sender, message_text, created_ts) VALUES (%s, %s, FROM_BASE64(%s), %d)",
        quote_binary(channel), quote_binary(sender), quote(persist_json.base64_encode(text)), tonumber(timestamp) or os.time()))
    return result ~= nil, query_err
end

function CMD.chat_history(channel, count)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    count = math.max(0, math.min(math.floor(tonumber(count) or 500), 500))
    local rows, query_err = query(string.format(
        "SELECT created_ts AS chat_timestamp, sender, message_text AS text FROM chat_messages WHERE channel=%s ORDER BY id DESC LIMIT %d",
        quote_binary(channel), count))
    if not rows then return nil, query_err end
    local result = {}
    for i = #rows, 1, -1 do
        local row = rows[i]
        result[#result + 1] = {
            timestamp = tonumber(row.chat_timestamp) or 0,
            sender = row.sender,
            text = row.text,
        }
    end
    return result
end

function CMD.access_token_chat_channels(token_hash, room_id)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    local rows, query_err = query(string.format(
        "SELECT channel FROM access_token_chat_channels WHERE token_hash=%s AND room_id=%s ORDER BY channel",
        quote(token_hash), quote_binary(room_id)))
    if not rows then return nil, query_err end
    local result = {}
    for _, row in ipairs(rows) do result[#result + 1] = row.channel end
    return result
end

function CMD.access_token_sub_rooms(token_hash, room_id)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    local rows, query_err = query(string.format(
        "SELECT sub_room FROM access_token_sub_rooms WHERE token_hash=%s AND room_id=%s ORDER BY sub_room LIMIT 128",
        quote(token_hash), quote_binary(room_id)))
    if not rows then return nil, query_err end
    local result = {}
    for _, row in ipairs(rows) do result[#result + 1] = row.sub_room end
    return result
end

function CMD.validate_access_token(token_hash, room_id)
    local ok, err = ensure_schema()
    if not ok then return nil, err end
    local now = os.time()
    local rows, query_err = query(string.format(
        "SELECT identity_id, room_id, root_room_id, is_master, begin_at, expires_at, " ..
        "(revoked_at IS NOT NULL) AS is_revoked, " ..
        "(expires_at IS NOT NULL AND expires_at <= %d) AS is_expired " ..
        "FROM access_tokens WHERE token_hash=%s AND room_id=%s LIMIT 1",
        now, quote(token_hash), quote_binary(room_id)))
    if not rows then return nil, query_err end
    local record = rows[1]
    if not record then return nil end
    if tonumber(record.is_revoked) == 1 then return nil, "access token revoked" end
    if tonumber(record.is_expired) == 1 then return nil, "access token expired" end
    return record
end

local database_write_commands = {
    commit_room = true, save_chat = true, save_chat_batch = true, set_room_closed = true,
}

skynet.start(function()
    metrics = skynet.uniqueservice("metrics")
    config = {
        host = skynet.getenv("mysql_host") or "127.0.0.1",
        port = tonumber(skynet.getenv("mysql_port")) or 3306,
        database = skynet.getenv("mysql_database") or "jiuqu_server",
        user = skynet.getenv("mysql_user") or "jiuqu_server",
        password = skynet.getenv("mysql_password") or "",
        charset = "utf8mb4",
        max_packet_size = tonumber(skynet.getenv("mysql_max_packet_size")) or 16 * 1024 * 1024,
    }
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown store command " .. tostring(command))
        local args = table.pack(...)
        local command_started = skynet.now()
        local result = table.pack(pcall(function()
            return lock(fn, table.unpack(args, 1, args.n))
        end))
        local elapsed = skynet.now() - command_started
        skynet.send(metrics, "lua", "command_latency", "store", command, elapsed)
        local queue_full = result[1] and result[2] == false and type(result[3]) == "string" and
            result[3]:match(" queue full$")
        if database_write_commands[command] and not queue_full and
           (not result[1] or result[2] ~= true) then
            skynet.send(metrics, "lua", "database_write_failure")
        end
        if session ~= 0 then
            if result[1] then skynet.ret(skynet.pack(table.unpack(result, 2, result.n)))
            else skynet.ret(skynet.pack(nil, tostring(result[2]))) end
        elseif not result[1] then
            skynet.error("store command failed", command, result[2])
        elseif result[2] == false and type(result[3]) == "string" and result[3]:match(" queue full$") then
            skynet.error("store command queue full", command)
        end
    end)
    skynet.error("MySQL store configured", config.host, config.port, config.database)
end)
