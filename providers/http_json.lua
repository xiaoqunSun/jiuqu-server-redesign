local skynet = require "skynet"
local httpc = require "http.httpc"
local json = require "json"

local M = {}

local function timeout_ticks()
    local timeout_ms = tonumber(skynet.getenv("provider_http_timeout_ms")) or 2000
    assert(timeout_ms >= 100 and timeout_ms <= 30000, "provider_http_timeout_ms must be between 100 and 30000")
    return math.ceil(timeout_ms / 10)
end

function M.validate_endpoint(host, path)
    if type(host) ~= "string" or host == "" then
        return nil, "provider HTTPS host is not configured"
    end
    local hostname, port = host:match("^https://([%w%.%-]+):(%d+)$")
    if not hostname then hostname = host:match("^https://([%w%.%-]+)$") end
    if not hostname or #hostname > 253 then
        return nil, "provider host must be a fixed HTTPS hostname"
    end
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then
        return nil, "provider HTTPS port is invalid"
    end
    if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" or
       not path:match("^/[A-Za-z0-9_./%-]*$") then
        return nil, "provider path must be a fixed absolute path"
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "provider path cannot contain dot segments"
        end
    end
    return true
end

function M.valid_header_value(value, max_bytes)
    if type(value) ~= "string" or value == "" or #value > max_bytes then return false end
    return value:find("[%z\1-\31\127]") == nil
end

local function read_chunked_bounded(response, max_body_bytes)
    -- These stream fields are provided by the pinned Skynet v1.8.0
    -- http.internal response_stream implementation.
    local interface = response._interface
    local buffer = response._body or ""
    assert(type(interface) == "table" and type(interface.read) == "function",
        "Skynet response stream is missing its reader")

    local function read_exact(size)
        while #buffer < size do
            local part = interface.read(size - #buffer)
            if type(part) ~= "string" or part == "" then error("truncated provider response") end
            buffer = buffer .. part
        end
        local result = buffer:sub(1, size)
        buffer = buffer:sub(size + 1)
        return result
    end

    local function read_line(max_line_bytes)
        while true do
            local ending = buffer:find("\r\n", 1, true)
            if ending then
                if ending - 1 > max_line_bytes then error("provider response line is too long") end
                local result = buffer:sub(1, ending - 1)
                buffer = buffer:sub(ending + 2)
                return result
            end
            if #buffer > max_line_bytes then error("provider response line is too long") end
            local part = interface.read()
            if type(part) ~= "string" or part == "" then error("truncated provider response") end
            buffer = buffer .. part
        end
    end

    local chunks, total = {}, 0
    while true do
        local size_line = read_line(128)
        if not size_line:match("^%x+$") then error("invalid provider chunk size") end
        local size = tonumber(size_line, 16)
        if not size or size < 0 or size % 1 ~= 0 then error("invalid provider chunk size") end
        if size == 0 then
            local trailer_bytes = 0
            while true do
                local trailer = read_line(8192)
                if trailer == "" then break end
                trailer_bytes = trailer_bytes + #trailer + 2
                if trailer_bytes > 8192 then error("provider response trailers are too large") end
            end
            return table.concat(chunks)
        end

        total = total + size
        if total > max_body_bytes then error("provider response exceeds configured limit") end
        local remaining = size
        while remaining > 0 do
            local part = read_exact(math.min(remaining, 8192))
            chunks[#chunks + 1] = part
            remaining = remaining - #part
        end
        if read_exact(2) ~= "\r\n" then error("invalid provider chunk delimiter") end
    end
end

function M.request_json(method, host, path, headers, content, max_body_bytes)
    local valid, endpoint_error = M.validate_endpoint(host, path)
    assert(valid, endpoint_error)
    assert(method == "GET" or method == "POST", "unsupported provider HTTP method")
    max_body_bytes = tonumber(max_body_bytes) or
        tonumber(skynet.getenv("provider_http_max_response_bytes")) or 65536
    assert(max_body_bytes >= 1 and max_body_bytes <= 65536,
        "provider response limit must be between 1 and 65536 bytes")

    local ticks = timeout_ticks()
    -- Each provider runs in its own Skynet service; this setting is stable for
    -- all concurrent requests handled by that service.
    httpc.timeout = ticks
    local request_started = skynet.now()

    local response
    local body_timed_out = false
    local completed = false
    local ok, status, value = pcall(function()
        response = httpc.request_stream(method, host, path, {}, headers, content)
        local code = response.status
        if code < 200 or code >= 300 then return code, nil end

        local transfer_encoding = response.header["transfer-encoding"]
        if transfer_encoding ~= nil and type(transfer_encoding) ~= "string" then
            error("duplicate provider transfer-encoding")
        end
        if transfer_encoding then
            transfer_encoding = transfer_encoding:lower()
            if transfer_encoding ~= "chunked" and transfer_encoding ~= "identity" then
                error("unsupported provider response encoding")
            end
        end
        local content_length = response.header["content-length"]
        if type(content_length) == "table" then
            error("duplicate provider content-length")
        end
        if transfer_encoding == "chunked" and content_length ~= nil then
            error("ambiguous provider response framing")
        end
        if content_length ~= nil then
            if type(content_length) ~= "string" or not content_length:match("^%d+$") then
                error("invalid provider content-length")
            end
            if tonumber(content_length) > max_body_bytes then
                error("provider response exceeds configured limit")
            end
        end

        -- Skynet's request_stream timeout covers connect and response headers.
        -- Add a separate deadline for reading the response body.
        local body_timeout_ticks = ticks - (skynet.now() - request_started)
        if body_timeout_ticks <= 0 then error("provider request timed out") end
        skynet.timeout(body_timeout_ticks, function()
            if not completed then
                body_timed_out = true
                if response then pcall(response.close, response) end
            end
        end)

        local body
        if transfer_encoding == "chunked" then
            body = read_chunked_bounded(response, max_body_bytes)
        else
            local chunks, total = {}, 0
            for chunk in response do
                if not chunk or chunk == "" then break end
                if type(chunk) ~= "string" then error("invalid provider response chunk") end
                total = total + #chunk
                if total > max_body_bytes then error("provider response exceeds configured limit") end
                chunks[#chunks + 1] = chunk
            end
            body = table.concat(chunks)
        end
        if body_timed_out then error("provider response body timed out") end
        return code, body
    end)

    completed = true
    if response then pcall(response.close, response) end
    if not ok then error(status, 0) end
    if body_timed_out then error("provider response body timed out", 0) end

    if value == nil then return status, nil end
    local decoded_ok, decoded = pcall(json.decode, value)
    if not decoded_ok then error("provider returned invalid JSON", 0) end
    return status, decoded
end

return M
