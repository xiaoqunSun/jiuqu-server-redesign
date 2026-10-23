# 录制资料 Provider

该扩展点实现旧 saveRoomData_Request 触发的排课/录制资料查询。Provider 默认关闭；内置的 legacy_room_metadata 复现旧 API 契约，并且只使用服务端配置的 HTTPS 地址。

## 启用旧平台接口

在 etc/config.lua 设置：

~~~lua
recording_provider_module = "legacy_room_metadata"
recording_provider_host = "https://broadcast.97kid.com"
recording_provider_path = "/schedule-api/t/rooms/"
provider_http_timeout_ms = 2000
provider_http_max_response_bytes = 65536
recording_provider_attempts = 3
recording_provider_retry_delay_ms = 1000
~~~

该 host/path 来自旧仓库 etc/config.live 的 fetRoomdataApi。部署可按实际环境设置其他固定 HTTPS 服务地址。saveRoomData_Request.data.api 会被忽略，不会转发给插件，也不会发起任意 URL 请求。

当 replayMode 不等于 1 且请求带非空 token 时，Room Actor 异步调用 Provider。内置模块对 r_ 加数字或带旧后缀的房间 ID，请求 recording_provider_path 后附上去掉 r_ 的后缀，附带 Authorization: Bearer <token>，并只接受 metadata.id 与房间数字 ID 一致的 JSON 对象。429、5xx 和网络错误最多重试配置次数；其他非 2xx 响应、房间 ID 不匹配或无效响应不保存资料。token、完整请求和认证头不写入日志。

## 自定义插件

如平台接口与旧 API 不同，可配置其他 Lua 模块并放到 providers/。模块导出：

~~~lua
function fetch_room_metadata(request)
    -- request 包含 room_id、identity_id、token、replay_mode 和 versions。
    -- 成功时返回 JSON 可编码的 Lua table；没有资料时返回 nil。
end
~~~

模块由服务端部署和配置，客户端不能选择。HTTP Provider 使用 provider_http_timeout_ms 和 provider_http_max_response_bytes；响应上限最大为 64 KiB。返回资料会作为 roomData.provider_metadata 写入房间事件和快照，只能通过有 Bearer 鉴权的管理 API GET /room?room_id=... 查看。若返回 `endAt` 为有效的秒级 Unix 整数，它也会映射到 `roomData.endAt` 并驱动 K12 房间自动结束；资料没有 `endAt` 时沿用旧服务行为，以 Room Actor 启动时间作为结束时间基准。管理员通过 `/room/end-time` 手动设置或清除后具有优先权，后续 Provider 刷新不会覆盖管理员决定。无效 `endAt` 会被忽略并记录不含资料内容的错误。HTTP 请求异常、超时、过大响应或格式错误不会改变本地房间状态。


## 本地联调状态

本地 HTTPS 假服务已通过隔离运行验证固定 GET 路径、Bearer token、受信任 CA/IP SAN、元数据房间 ID 匹配和 `endAt` 持久化；错误 ID 响应不会修改房间资料，未受信任 CA 会在 HTTP 请求前失败。真实平台服务仍需在部署环境做联调。
