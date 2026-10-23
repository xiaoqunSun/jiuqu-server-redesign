local skynet = require "skynet"
local json = require "json"

local CMD = {}
local provider
local in_flight = {}

local function is_json_object(value)
    for key in pairs(value) do
        if type(key) ~= "string" then return false end
    end
    return true
end

function CMD.fetch(room_actor, request)
    if not provider then return false, "recording provider is disabled" end
    if type(room_actor) ~= "number" or type(request) ~= "table" then
        return false, "invalid recording provider request"
    end
    local room_id = request.room_id
    if type(room_id) ~= "string" or room_id == "" or #room_id > 191 then
        return false, "invalid room id"
    end
    if in_flight[room_id] then return false, "recording provider request is already in flight" end
    in_flight[room_id] = true

    skynet.fork(function()
        local ok, result = pcall(provider.fetch_room_metadata, request)
        in_flight[room_id] = nil
        if not ok then
            skynet.error("recording provider request failed", room_id)
            return
        end
        if result == nil then return end
        if type(result) ~= "table" or json.is_null(result) or not is_json_object(result) then
            skynet.error("recording provider returned invalid metadata", room_id)
            return
        end
        local encoded_ok, encoded = pcall(json.encode, result)
        if not encoded_ok or type(encoded) ~= "string" or #encoded > 65536 then
            skynet.error("recording provider metadata rejected", room_id)
            return
        end
        skynet.send(room_actor, "lua", "provider_result", result)
    end)
    return true
end

skynet.start(function()
    local module_name = skynet.getenv("recording_provider_module") or ""
    if module_name ~= "" then
        provider = require(module_name)
        assert(type(provider) == "table" and type(provider.fetch_room_metadata) == "function",
            "recording provider module must export fetch_room_metadata(request)")
        skynet.error("recording provider enabled", module_name)
    else
        skynet.error("recording provider disabled")
    end
    skynet.dispatch("lua", function(session, _, command, ...)
        local fn = assert(CMD[command], "unknown recording provider command " .. tostring(command))
        local ok, result, err = pcall(fn, ...)
        if session ~= 0 then
            if ok then skynet.ret(skynet.pack(result, err))
            else skynet.ret(skynet.pack(false, tostring(result))) end
        elseif not ok then
            skynet.error("recording provider command failed", command)
        end
    end)
end)
