local skynet = require "skynet"
local queue = require "skynet.queue"

local M = {}

function M.new(config_key, default_limit, queue_full_reason)
    local serialize = queue()
    local configured = tonumber(skynet.getenv(config_key))
    local limit = math.max(1, math.min(65536, math.floor(configured or default_limit or 256)))
    local outstanding = 0
    queue_full_reason = queue_full_reason or "command queue full"

    local function run(fn, ...)
        if outstanding >= limit then return false, queue_full_reason end
        outstanding = outstanding + 1
        local result = table.pack(pcall(serialize, fn, ...))
        outstanding = outstanding - 1
        if not result[1] then error(result[2]) end
        return table.unpack(result, 2, result.n)
    end

    local function stats()
        return { outstanding = outstanding, limit = limit }
    end

    return run, stats
end

return M
