local skynet = require "skynet"
local protocol = require "compat_v1"

skynet.start(function()
    local schema_ok, schema_err = pcall(protocol.validate)
    assert(schema_ok, "Protobuf schema initialization failed: " .. tostring(schema_err))
    skynet.uniqueservice("metrics")
    local store = skynet.uniqueservice("store")
    local store_ready, store_err = skynet.call(store, "lua", "ready")
    assert(store_ready, "MySQL store initialization failed: " .. tostring(store_err))
    skynet.uniqueservice("auth")
    skynet.uniqueservice("room_directory")
    skynet.uniqueservice("chat")
    skynet.uniqueservice("recording_provider")

    skynet.newservice("listener", "tcp")
    if (tonumber(skynet.getenv("ws_port")) or 0) > 0 then
        skynet.newservice("listener", "ws")
    end
    if (tonumber(skynet.getenv("admin_port")) or 0) > 0 then
        local admin_token = skynet.getenv("admin_token") or ""
        assert(#admin_token >= 32, "admin_token must contain at least 32 bytes")
        skynet.newservice("admin")
    end
    skynet.error("Jiuqu realtime server started",
        "tcp", skynet.getenv("tcp_port"), "websocket", skynet.getenv("ws_port"))
end)
