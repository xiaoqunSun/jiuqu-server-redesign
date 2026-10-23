local skynet = require "skynet"
local protobuf = require "protobuf"

local M = {}
local codec
local MAX_INNER_FRAME = 4 * 1024 * 1024

local function get_codec()
    if not codec then
        local directory = skynet.getenv("proto_dir") or "compat/v1/proto"
        codec = protobuf.load(directory)
    end
    return codec
end

function M.validate()
    get_codec()
    return true
end

local function zlib_module()
    local ok, module = pcall(require, "zlib")
    if not ok then error("zlib module is required for compressed protocol frames") end
    return module
end

function M.decode_packet(packet)
    if type(packet) ~= "string" or #packet < 2 then error("invalid outer protocol frame") end
    local frame, next_pos = string.unpack(">s2", packet)
    if next_pos ~= #packet + 1 then error("outer protocol frame length mismatch") end
    if #frame < 9 then error("truncated protocol frame") end

    local name_size = string.unpack(">I4", frame)
    if name_size < 1 or name_size > 128 or #frame < name_size + 9 then
        error("invalid protocol message name length")
    end
    local name = frame:sub(5, name_size + 4)
    local compressed = frame:byte(name_size + 5)
    if compressed ~= 0 and compressed ~= 1 then error("invalid compression flag") end
    local message_size = string.unpack(">I4", frame, name_size + 6)
    if message_size > MAX_INNER_FRAME then error("protobuf message exceeds limit") end
    local payload = frame:sub(name_size + 10)
    if compressed == 1 then
        local inflater = zlib_module().inflate()
        local chunks, total, ended, consumed = {}, 0, false, 0
        for offset = 1, #payload, 256 do
            if ended then error("trailing data after compressed protobuf stream") end
            local ok, inflated, stream_end, total_in = pcall(inflater, payload:sub(offset, offset + 255))
            if not ok or type(inflated) ~= "string" then
                error("invalid compressed protobuf payload")
            end
            total = total + #inflated
            if total > message_size then error("compressed protobuf exceeds declared length") end
            chunks[#chunks + 1] = inflated
            ended = stream_end == true
            consumed = tonumber(total_in) or consumed
        end
        if not ended or total ~= message_size or consumed ~= #payload then
            error("compressed protobuf length mismatch")
        end
        payload = table.concat(chunks)
    elseif #payload ~= message_size then
        error("protobuf payload length mismatch")
    end
    return name, get_codec():decode(name, payload)
end

function M.encode_packet(name, message)
    assert(type(name) == "string" and #name > 0 and #name <= 128, "invalid protocol message name")
    local plain = get_codec():encode(name, message)
    local payload, compressed = plain, 0
    if #plain > 20 * 1024 and skynet.getenv("is_k12") == "1" then
        local ok, deflate = pcall(function() return zlib_module().deflate() end)
        if ok then
            local compressed_ok, result = pcall(deflate, plain, "finish")
            if compressed_ok and type(result) == "string" and #result < #plain then
                payload, compressed = result, 1
            end
        end
    end
    local frame = string.pack(">I4", #name) .. name .. string.char(compressed) ..
        string.pack(">I4", #plain) .. payload
    assert(#frame <= 0xffff, "protocol frame exceeds 16-bit client limit")
    return string.pack(">s2", frame)
end

return M
