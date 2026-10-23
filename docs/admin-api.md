# 管理 API

管理 API 与 TCP/WebSocket 客户端入口分开监听，默认关闭。它只提供单节点运维操作，不是旧版 simpleweb 的兼容替代品。

## 启用

在 etc/config.lua 设置：

~~~lua
admin_host = "127.0.0.1"
admin_port = 9080
admin_token = "至少 32 字节的随机秘密"
~~~

端口大于 0 时，服务启动会检查 admin_token 至少有 32 字节。默认绑定回环地址；需要远程访问时应通过内网代理或防火墙限制来源。不要把管理端口直接暴露到公网。每个请求都必须携带：

~~~http
Authorization: Bearer <admin_token>
~~~

请求体和响应体均为 UTF-8 JSON。管理 API 不记录 token 或聊天正文。变更操作会写入服务日志。

## 接口

| 方法与路径 | 用途 |
| --- | --- |
| GET /health | 返回服务健康状态 |
| GET /metrics | 返回单节点连接、登录、命令延迟、MySQL 提交、房间恢复和队列指标 |
| GET /rooms | 返回活动连接数和当前 Room Actor 列表 |
| GET /room?room_id=<id> | 查看活动房间成员、变量、扩展变量、序号、白板/投票数量；已配置 Provider 时也包含其录制资料元数据 |
| GET /room/var?room_id=<id>&name=<key>&extended=1 | 读取活动房间单个普通/扩展变量；省略 `name` 可读取整类变量。单项响应包含 `found` 与 `value`，不存在时 `value` 为 JSON `null` |
| GET /room/online?room_id=<id>&history=1 | 查询活动房间按身份统计的在线时长、上课时长、最近活跃时间和首次进入时间；`history=1` 时附带进入/离开时间数组 |
| GET /room/replay?room_id=<id>&after=<seq>&limit=<n> | 从 MySQL 分页读取已开启回放的房间事件；房间无需处于活动状态；limit 最大 500 |
| POST /room/var | 更新活动房间变量并广播 updateVar_Response |
| POST /room/end-time | 设置或清除活动房间的 Unix 秒级课程结束时间 |
| POST /room/event | 在活动房间广播 event_Response |
| POST /room/close | 将关闭状态写入 MySQL、发送 kickOut、阻止新登录和当前会话继续提交房间命令 |
| POST /room/open | 清除 MySQL 中的关闭状态并允许房间重新登录 |

POST 请求示例：

~~~json
{"room_id":"r_123","name":"round","value":"2"}
~~~

变量 value 若不是字符串，会先编码成 JSON；字符串 null 沿用客户端变量删除语义。事件请求使用 room_id、id 和 var 字段；var 若不是字符串也会先编码为 JSON。

读取变量时 `extended` 可设为 `1` 或 `true` 选择扩展变量；普通变量为默认值。单项查询也接受旧管理字段名 `key` 和 `ext`。省略 `name`/`key` 时返回 `values` 对象。

设置结束时间的请求为 `{"room_id":"r_123","end_at":1790000000}`。`end_at` 是秒级 Unix 时间戳；传 `0` 清除结束时间。时间写入 MySQL 房间事件并可在 Actor 恢复后继续使用。当 `is_k12=1` 且房间有排课资料时，Provider 的 `endAt` 会作为课程结束时间；资料没有 `endAt` 时按 Room Actor 启动时间计算。服务在该时间加 `room_end_grace_period` 后踢出在线成员并拒绝新登录，默认宽限 1800 秒。管理员手动设置或清除时间后会覆盖 Provider，清除时也会停用启动时间回退。手动关闭与到期关闭都可以通过 `/room/open` 重新开放；如需取消已到期的关闭时间，先将 `end_at` 清零再开放。

关闭房间不会删除 MySQL 状态或事件记录。关闭/开放开关存储在 `room_lifecycle` 表中，Skynet 重启后仍生效；首次登录时 Directory 读取该状态，避免为未活动子房间创建 Actor 并改变其根房间映射。若房间 Actor 当前活动，关闭操作会发送 `kickOut` 并阻止其继续处理客户端命令。重新开放后，下一次登录会按持久化快照恢复状态。查询、变量、事件和结束时间接口只操作本进程已加载的房间。

在线统计以秒为单位，每五秒采样并在成员离开或查询时结算当前区间。默认返回每个身份的 `online_duration`、`class_duration`、`active_time`、`first_enter_time`；传 `history=1` 会增加 `enter_history` 和 `leave_history`。这些统计保存在活动 Room Actor 内存中，房间 Actor 回收或服务重启后会清空；MySQL 中的房间状态和回放数据不受影响。

管理 API 不提供 SQL 通道、原始 token 查询或任意 URL 请求。部署为多节点后，需要为每个管理操作增加节点路由和审计身份；当前服务不包含多节点调度。

`GET /metrics` 返回当前进程的累计计数和延迟直方图，以及采样时刻的连接数、活动房间数和 Directory、Room、Family、Chat、Store 的待处理命令数。Room 项包含房间 ID、成员数、队列长度和上限；Family 项按根房间 ID 返回队列长度和上限；Session 出站队列包含包数与字节数。连接计数包含尚未登录的网络连接，`active_sessions` 只计算已加入房间的会话。指标保存在内存中，进程重启后清零；Room 队列列表只列出当前活动 Actor。

命令延迟按服务和命令聚合，延迟超过 `metrics_slow_command_ms`（默认 1000 ms）的客户端命令会写日志，包含 room_id、Session Actor 地址和进程运行期间生成的 subject HMAC 脱敏值。原始身份不会写入这类慢命令日志。慢房间恢复使用 `metrics_slow_recovery_ms`（默认 1000 ms）记录 room_id 和恢复时长。数据库提交延迟测量实际 MySQL COMMIT 或 autocommit 写请求；提交与房间恢复统计都包含 `failures_total`，`database_write_failures_total` 另统计未能成功完成的持久化写命令。

回放接口只对 saveRoomData_Request 已启用 replayMode 的房间开放；Room Actor 空闲回收后仍可读取 MySQL 中的回放。Room Actor 从创建时持续收集持久化房间变更、客户端标记 saveToReplay 的聊天和聚合光标；启用 replayMode 后可从序号 1 导出。响应按 sequence 排序，包含事件 schema_version、类型、JSON payload 和秒级 created_at；课堂/RichText 事件 payload 保留旧回放中的 broadcast 标记。使用 next_after_sequence 读取下一页。它提供新事件格式，不兼容旧 newReplay 文件格式。光标默认每 250 毫秒最多写一批，每位成员每批只保留最新位置。可通过 `replay_cursor_flush_interval_ms` 调整为 100 到 5000 毫秒。

管理响应始终是 UTF-8 JSON。若响应包含不能表示为 UTF-8 的 Protobuf bytes（包括 JSON 对象键），响应根对象会改为 `{"$jiuqu_binary_json":2,"data":...}`。`data` 使用有类型节点：`["s",text]` 字符串、`["b",base64]` 原始 bytes、`["n",number]` 数字、`["t",boolean]` 布尔值、`["z"]` null、`["a",nodes]` 数组、`["o",[[keyNode,valueNode],...]]` 对象。没有非 UTF-8 字符串时，管理响应保持普通 JSON 结构。数据库的 schema_version 2 与该管理 API envelope 分开：持久化 JSON 仅对非 UTF-8 字节使用 `\udcXX` 转义，以保留普通快照和事件的可读性与体积。

聊天正文以 BLOB 原样保存；旧版数据库的 UTF-8 `TEXT` 列会在 Store 启动时自动升级，要求应用账号拥有 ALTER 权限，也可手动执行 `sql/006_binary_chat_text.sql`。
