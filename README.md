# Jiuqu Realtime Server

基于 Skynet v1.8.0 的实时课堂服务端新实现。旧仓库只作为客户端协议和业务行为的参考；新服务端使用独立的协议边界、Session、Room Actor 和 MySQL 持久化。

## 当前实现

- TCP 和 WebSocket 二进制监听器，使用原客户端 2 字节长度帧、消息名、压缩标志及 Protobuf 编码。
- accessToken 可选：字段缺失或为空时按旧客户端的 id、room、isMaster 兼容登录；字段非空时必须命中 MySQL 本地凭证，记录决定身份、房间和教师角色。
- 一个连接一个 Session Actor；同一身份单点登录，新连接会踢出旧连接。
- 房间变量、扩展变量、事件、白板页面/样式、投票和聊天消息路径；Room Actor 统一验证成员身份。
- 教师角色可管理回放元数据和投票生命周期；学生查询投票时不能读取其他人的投票明细。
- 聊天按成员频道授权，限制频道数、消息长度和发送频率；空 token 兼容模式可配置保留旧版任意频道行为。
- 聊天历史优先从 MySQL 读取；数据库读取暂时失败时使用按频道数有界的进程内回退缓存。
- MySQL/InnoDB 房间事件、状态快照、聊天历史、本地 token 授权和房间生命周期状态；事件与快照带 schema_version，Room Actor 启动时从快照恢复，并按连续序号重放快照之后的事件。持久化 schema v2 对非 UTF-8 的 Protobuf bytes 使用紧凑、可逆的 `\udcXX` 字节转义，同时兼容读取旧 schema v1；聊天正文以 BLOB 保存，二进制 SQL 参数通过 Base64 表达。
- 独立管理 API 默认关闭；启用后要求独立强 token，支持查看房间、在线时长与进出记录、更新变量/事件和课程结束时间、关闭/开放房间，以及分页读取回放事件。

原客户端登录请求始终带 accessToken 字段，但值可以为空：空值按旧兼容路径登录。非空值只接受本地 access_tokens 中未撤销、未过期且与身份和房间匹配的记录。旧平台 via API 不提供身份或角色授权信息；旧 token 需要经可信流程登记到本地表后使用。

原客户端 WebSocket 和冻结 v1 schema 的历史联调范围，以及本轮隔离 v1 帧运行核验见[验证记录](docs/verification.md)。本轮额外验证了空 token 登录、变量往返、管理端鉴权、在线统计、课程结束时 `kickOut`、MySQL 事件重放及过期课程拒绝登录；两个会话还验证了根/子房间变量传播和子房间查询。TCP v1 帧也完成了登录和变量往返核验。本地 HTTPS Provider 假服务已验证固定路径、Bearer token、可信 CA/IP 校验、响应房间 ID 匹配和 endAt 持久化。Family Coordinator/Room Actor 整进程重启、子房间落后快照补同步，以及 Coordinator 中断后的课堂事件按序补发、重复去重和空房间历史边界均已在隔离 MySQL 中验证。本地 token provisioning 路径已运行验证学生/教师角色由数据库决定，并拒绝无效、身份不匹配、过期和撤销凭证；另确认已登录的短期 token 会在到期时收到 kickOut 并断开。二进制安全持久化 schema v2 已通过临时 MySQL 的事件、快照和 Family 查询往返核验。v1 Protobuf 扩展流程和 codec 支持范围见[协议兼容文档](docs/protocol-compatibility.md)。仍未运行整套课程应用、原生 TCP 客户端或真实平台 Provider 联调。

客户端启用 skynetRecord 时会另发 saveRoomData_Request，其中包含 token 和 API 地址。新服务端忽略客户端 API 地址，保存版本及回放模式元数据；回放模式开启后，持久化房间事件可通过管理 API 分页读取。录制资料 Provider 默认关闭；启用后，内置 legacy_room_metadata 使用服务端固定 HTTPS 地址、Bearer token 与 room id 校验方式获取排课资料，并将返回的结束时间接入 K12 自动下课。配置说明见[录制资料 Provider](docs/providers/recording-provider.md)和[旧平台 via API 契约](docs/providers/legacy-via-api-contract.md)。新格式保留房间事件序号和秒级时间。Room Actor 从创建时持续收集房间变更、客户端标记 saveToReplay 的聊天及聚合光标；saveRoomData replayMode=1 开启导出，并从该房间事件序号 1 开始读取。光标默认每 250 毫秒最多写一批，每位成员每批保留最新位置。该格式不导入旧回放文件。`subRoomVar_Request` 只允许根房间成员发起；协议字段 `subRoom` 是 `int32`，当前服务将非零整数转为十进制别名，按 `<n>`、`r_<n>`、`rootRoom:<n>` 查找子房间。旧代码显示 0 值会广播，但非零整数到字节串 room id 没有可靠映射，且旧响应回调存在参数错位；真实数值映射和 0 的预期仍待客户端样本确认，当前客户端源码未调用该请求。根/子房间的本地 Family Coordinator 已实现：根房间变量、扩展变量、RichText/课堂事件和光标按房间顺序传播；每 5 秒及子房间登录前以根房间持久快照对账状态，并按根房间事件序号补发已有成员期间漏掉的持久课堂事件。共享状态水位和课堂事件水位分开记录，避免变量更新掩盖课堂事件缺口。子房间按课堂事件水位去重；客户端出站队列投递仍可能断开慢连接，光标等瞬时数据不补发。没有在线成员时推进课堂事件水位，整进程重启后新创建的子房间同步当前状态，不重放旧课堂事件。跨节点房间归属未实现。

无 token 的兼容登录会信任客户端提交的 id、room、isMaster 和 subRoom 列表，并默认保留旧版任意合法聊天频道/子房间查询行为；这些信息不能证明用户身份或教师权限。legacy_chat_channels_unrestricted 和 legacy_sub_rooms_unrestricted 默认开启以保持旧客户端兼容，确认客户端都使用登记授权后可分别改为 0。不要将未验证模式直接暴露在不受信任的公网环境。

`subRoomVar_Request` 的整数别名仅覆盖 `<n>`、`r_<n>` 和 `rootRoom:<n>` 命名；生产使用前需要真实请求样本确认非零值映射与零值行为。

## 构建和启动

需要 C 编译器、Make、zlib 和 OpenSSL 1.1.1 以上开发库，以及启用 mysql_native_password 的 MySQL/MariaDB。Skynet 构建会先从 `patches/skynet-v1.8.0-tls.patch` 应用 TLS 校验补丁，再生成带证书链和主机名验证的客户端模块；构建会校验子模块提交与 v1.8.0 锁定值一致。Skynet v1.8.0 自带驱动目前只实现该认证方式；MySQL 8.0 默认认证插件可能需要为应用账号显式配置。

~~~sh
git submodule update --init --recursive
make
mysql -uroot -p -e "CREATE DATABASE jiuqu_server CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE USER 'jiuqu_server'@'%' IDENTIFIED WITH mysql_native_password BY 'change-me'; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER ON jiuqu_server.* TO 'jiuqu_server'@'%';"
mysql -uroot -p jiuqu_server < sql/001_initial_schema.sql
~~~

先在 etc/config.lua 中填写 MySQL 主机、库名、账号和密码，再运行 make run。主服务会先连接 MySQL 并确认/创建所需表，然后才启动监听器；数据库不可用或账号权限不足时启动会失败，不会以半可用状态接收客户端连接。启动命令会直接把该文件交给 Skynet；监听地址、端口、MySQL 参数、auth_token_pepper 和其他运行参数都在此文件维护。配置文件包含密钥时不要提交密钥值。上面的账号创建命令适用于全新环境；已有账号时只需授予相同权限。服务默认启用原版 K12 的大消息压缩；将 is_k12 改为 "0" 可关闭。

非空 token 需要设置至少 32 字节的 auth_token_pepper，并为每个 (token, room) 写入可信 access_tokens 记录。生成授权 SQL 时，AUTH_TOKEN_PEPPER 环境变量必须与配置文件中的 pepper 相同；SQL 只保存 HMAC 摘要。身份、房间、教师角色和有效期必须来自可信授权来源。旧平台 via API 只回传课程状态和 beginAt，不能替代本地身份与角色凭证。token 原文不会写入数据库或日志。

~~~sh
AUTH_TOKEN_PEPPER='<server-secret>' python3 tools/provision_access_token.py \
  --identity-id '<client-id>' \
  --room-id 'r_<room-id>' \
  --root-room-id 'r_<room-id>' \
  --begin-at 0 \
  < token.txt > /tmp/authorize-token.sql
mysql -u jiuqu_server -p jiuqu_server < /tmp/authorize-token.sql
~~~

可选参数 --is-master 和 --expires-at 分别授予教师角色和设置过期时间；本地 token 到期时，已建立的会话也会收到 kickOut 并断开。--chat-channel 可重复传入额外的获准频道；不传时 token 仅能访问登录房间和根房间的频道别名。--sub-room 可重复传入允许查询的子房间 ID/别名（最多 128 个）。修改已有数据库时执行缺失的 sql/002_access_token_chat_channels.sql、sql/003_access_token_sub_rooms.sql、sql/004_event_schema_versions.sql、sql/005_room_lifecycle.sql 和 sql/006_binary_chat_text.sql；服务启动会自动补建缺失表/列，并将旧聊天正文列升级为 BLOB，因此已由服务自动升级的项目无需重复执行相应脚本。启用自动迁移的数据库账号需要 ALTER 权限。撤销凭证时设置 revoked_at。

默认 TCP 端口为 8001，WebSocket 端口为 9948（与原版客户端默认端口一致）。在 etc/config.lua 中修改 listen_host、tcp_port 和 ws_port；大房间快照可调高 mysql_max_packet_size。将 ws_port 设为 0 可关闭 WebSocket 监听；生产环境应在 TLS 终止代理后提供安全 WebSocket。

每连接默认限速为每秒 200 条、每 5 秒 500 条，超限关闭连接；在 etc/config.lua 中修改 oneSec_frequencyLimit 和 fiveSec_frequencyLimit。聊天另按每 10 秒最多 30 条限制，由 chat_messages_per_10s 设置。

聊天服务只保留当前有订阅者的频道路由，并将 MySQL 故障回退历史限制为最多 chat_history_cache_channels 个频道（默认 1024 个，每个频道最多 500 条）。

每连接出站队列默认最多 256 条或 1 MiB。慢客户端达到任一上限后会断开连接，可在 etc/config.lua 中调整 outbound_queue_max_packets 和 outbound_queue_max_bytes。Room、Directory、Family、Chat、Store 的串行命令队列也有默认 outstanding 上限（分别为 256、512、512、512、512）；房间或聊天入口过载时服务端关闭对应客户端连接，让调用方重连，不会无限积压。Family 发布队列过载时日志会记录丢弃，根房间 MySQL 事件和房间快照会在后续对账中修复持久状态与课堂事件；瞬时光标不重放。

管理 API 默认关闭（admin_port=0）。启用时设置至少 32 字节的 admin_token；默认监听 127.0.0.1。除在线统计和房间管理外，`GET /metrics` 可查看连接、登录、每类命令延迟、数据库提交、房间恢复、各 Actor 队列及慢客户端断开计数。指标在进程内累计，重启后清零；慢命令日志中的 subject 使用进程级 HMAC 脱敏。接口和请求格式见[管理 API 文档](docs/admin-api.md)。在线统计按活动房间内存采样，Room Actor 回收或服务重启后清空，与旧服务在线统计的内存生命周期一致。

房间无人在线默认 1 小时后回收内存中的 Room Actor；状态已保存在 MySQL，下次进入时恢复。在 etc/config.lua 中修改 room_idle_timeout（秒），设为 0 可关闭回收。`is_k12=1` 时，排课 Provider 返回的 `endAt` 会在 `room_end_grace_period` 后关闭房间；排课资料没有 `endAt` 时按房间启动时间计算。管理员通过 `/room/end-time` 手动设置或清除时间后，该值优先于 Provider（传 `0` 清除并停用启动时间回退）；默认宽限 30 分钟。

敏感词来自 etc/sensitive_words.txt，每行一项；可以在 etc/config.lua 中修改 sensitive_words_file 指定外部词表。

## 设计和协议文档

- [旧平台 via API 契约](docs/providers/legacy-via-api-contract.md)
- [Provider HTTPS 约定](docs/providers/http-provider.md)
- [管理 API](docs/admin-api.md)
- [录制资料 Provider 接口](docs/providers/recording-provider.md)
- [需求](docs/requirements.md)
- [总体设计](docs/design/server-architecture.md)
- [逐消息命令映射](docs/design/protocol-command-map.md)
- [新旧服务器设计对照](docs/design/old-server-comparison.md)
- [客户端协议边界](docs/protocol-compatibility.md)
- [Skynet 基线决策](docs/decisions/0001-skynet-baseline.md)
- [MySQL 决策](docs/decisions/0002-persistence-store.md)
