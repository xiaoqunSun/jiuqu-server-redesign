local skynet = require "skynet"
local http_json = require "http_json"
local json = require "json"

local host = skynet.getenv("recording_provider_host") or ""
local path_prefix = skynet.getenv("recording_provider_path") or ""
assert(path_prefix:sub(-1) == "/", "recording_provider_path must end with '/'")
local valid, endpoint_error = http_json.validate_endpoint(host, path_prefix)
assert(valid, endpoint_error)

local M = {}

local function room_suffix_and_id(room_id)
    if type(room_id) ~= "string" or #room_id > 191 then return nil end
    local suffix = room_id:match("^r_([A-Za-z0-9_%-]+)$")
    if not suffix then return nil end
    local digits = suffix:match("^(%d+)")
    if not digits or #digits > 18 then return nil end
    local expected_id = tonumber(digits)
    if not expected_id or expected_id == math.huge or expected_id < 1 then return nil end
    return suffix, expected_id
end

local function fetch_once(request, suffix, expected_id)
    local token = request.token
    if not http_json.valid_header_value(token, 8192) then return nil end

    local status, metadata = http_json.request_json("GET", host, path_prefix .. suffix, {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. token,
        ["Connection"] = "close",
    })

    if status == 429 or status >= 500 then error("temporary recording metadata API failure") end
    if status < 200 or status >= 300 or type(metadata) ~= "table" or json.is_null(metadata) then
        return nil
    end
    local response_id = tonumber(metadata.id)
    if not response_id or response_id == math.huge or response_id == -math.huge or
       math.floor(response_id) ~= expected_id then return nil end
    return metadata
end

function M.fetch_room_metadata(request)
    if type(request) ~= "table" or type(request.token) ~= "string" or request.token == "" then
        return nil
    end
    local suffix, expected_id = room_suffix_and_id(request.room_id)
    if not suffix or not expected_id then return nil end

    local attempts = math.floor(tonumber(skynet.getenv("recording_provider_attempts")) or 3)
    attempts = math.max(1, math.min(attempts, 5))
    local retry_delay_ms = tonumber(skynet.getenv("recording_provider_retry_delay_ms")) or 1000
    retry_delay_ms = math.max(0, math.min(retry_delay_ms, 5000))

    for attempt = 1, attempts do
        local ok, result = pcall(fetch_once, request, suffix, expected_id)
        if ok then return result end
        if attempt == attempts then error("recording metadata request failed", 0) end
        skynet.sleep(math.ceil(retry_delay_ms / 10) * attempt)
    end
    return nil
end

return M
