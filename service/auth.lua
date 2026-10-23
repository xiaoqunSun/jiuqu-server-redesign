local skynet = require "skynet"
local crypt = require "skynet.crypt"

local CMD = {}
local store

local function legacy_sub_rooms(message)
    local result = {}
    if type(message.subRoom) == "table" then
        for index, value in ipairs(message.subRoom) do
            if index > 128 then break end
            if type(value) == "string" and value ~= "" and #value <= 191 then
                result[#result + 1] = value
            end
        end
    end
    return result
end

local function legacy_claims(message)
    local room_id = message.room or ""
    local root_room_id = message.rootRoom
    if not root_room_id or root_room_id == "" then root_room_id = room_id end
    return {
        id = message.id,
        room_id = room_id,
        root_room_id = root_room_id,
        is_master = message.isMaster == true,
        source = "legacy_unverified",
        sub_rooms = legacy_sub_rooms(message),
        allowed_chat_channels = {},
    }
end

local function local_token_claims(message, token_hash, record)
    if record.identity_id ~= message.id then return nil, "token identity mismatch" end

    local channel_ok, allowed_chat_channels, channel_err = pcall(skynet.call,
        store, "lua", "access_token_chat_channels", token_hash, message.room)
    if not channel_ok or type(allowed_chat_channels) ~= "table" then
        skynet.error("local access token channel lookup failed", tostring(channel_err or allowed_chat_channels))
        return nil, "token channel lookup failed"
    end

    local sub_room_ok, allowed_sub_rooms, sub_room_err = pcall(skynet.call,
        store, "lua", "access_token_sub_rooms", token_hash, message.room)
    if not sub_room_ok or type(allowed_sub_rooms) ~= "table" then
        skynet.error("local access token sub-room lookup failed", tostring(sub_room_err or allowed_sub_rooms))
        return nil, "token sub-room lookup failed"
    end

    local root_room_id = record.root_room_id
    if message.rootRoom and message.rootRoom ~= "" and message.rootRoom ~= root_room_id then
        return nil, "token root room mismatch"
    end
    return {
        id = record.identity_id,
        room_id = record.room_id,
        root_room_id = root_room_id,
        is_master = tonumber(record.is_master) == 1,
        expires_at = tonumber(record.expires_at),
        source = "local_token",
        sub_rooms = allowed_sub_rooms,
        allowed_chat_channels = allowed_chat_channels,
    }, nil
end

function CMD.check(message)
    if type(message) ~= "table" or type(message.id) ~= "string" or message.id == "" then
        return false, 0, "missing id"
    end
    if #message.id > 255 then return false, 0, "identity id is too long" end
    if message.room ~= nil and (type(message.room) ~= "string" or #message.room > 191) then
        return false, 0, "room id is invalid"
    end
    if message.rootRoom ~= nil and (type(message.rootRoom) ~= "string" or #message.rootRoom > 191) then
        return false, 0, "root room id is invalid"
    end

    -- The original client may serialize an explicitly empty optional bytes
    -- field when no token is available. Treat that exactly like omission.
    if message.accessToken == nil or message.accessToken == "" then
        return true, 0, legacy_claims(message)
    end
    if type(message.accessToken) ~= "string" then
        return false, 0, "invalid access token field"
    end
    local room_id = message.room or ""
    if room_id == "" then return false, 0, "missing room" end

    local pepper = skynet.getenv("auth_token_pepper") or ""
    if #pepper < 32 then
        return false, 0, "AUTH_TOKEN_PEPPER must contain at least 32 bytes"
    end
    local token_hash = crypt.hexencode(crypt.hmac_sha1(pepper, message.accessToken))
    local ok, record, lookup_err = pcall(skynet.call,
        store, "lua", "validate_access_token", token_hash, room_id)
    if not ok then
        skynet.error("local access token lookup failed", tostring(record))
        return false, 0, "token lookup failed"
    end
    if record then
        local claims, claims_err = local_token_claims(message, token_hash, record)
        if not claims then return false, 0, claims_err end
        return true, tonumber(record.begin_at) or 0, claims
    end
    if lookup_err then
        skynet.error("local access token unavailable", tostring(lookup_err))
        return false, 0, lookup_err
    end
    return false, 0, "invalid access token"
end

skynet.start(function()
    store = skynet.uniqueservice("store")
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown auth command " .. tostring(command))
        local ok, accepted, begin_at, claims = pcall(fn, ...)
        if session ~= 0 then
            if ok then skynet.ret(skynet.pack(accepted, begin_at, claims))
            else skynet.ret(skynet.pack(false, 0, tostring(accepted))) end
        elseif not ok then
            skynet.error("auth command failed", command, accepted)
        end
    end)
end)
