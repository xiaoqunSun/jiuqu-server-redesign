local skynet = require "skynet"
local socket = require "skynet.socket"

local mode = ... or "tcp"
assert(mode == "tcp" or mode == "ws", "listener mode must be tcp or ws")

skynet.start(function()
    local host = skynet.getenv("listen_host") or "0.0.0.0"
    local port_key = mode == "tcp" and "tcp_port" or "ws_port"
    local port = assert(tonumber(skynet.getenv(port_key)), "listener port is required")
    local listen_id = socket.listen(host, port, 256)
    skynet.error("listening", mode, host, port)
    socket.start(listen_id, function(fd, address)
        local session = skynet.newservice("session")
        skynet.send(session, "lua", "start", {
            fd = fd, transport = mode, address = address,
        })
    end)
end)
