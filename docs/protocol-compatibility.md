# 客户端协议兼容边界

协议是当前的接入约束，不是领域模型。实现中由边缘适配层维护旧协议与内部命令/事件的映射。逐消息的请求、响应和新领域映射见[协议命令映射](design/protocol-command-map.md)。

## 当前线格式

根据旧服务端实现记录：

1. 外层为 2 字节大端长度前缀（Lua `string.pack(">s2", payload)`）。
2. 内层为 4 字节大端消息名长度、消息名、1 字节压缩标志、4 字节大端未压缩长度、protobuf 数据。
3. TCP 使用该应用帧；WebSocket 使用二进制帧，消息体中仍包含同一 2 字节长度前缀。
4. Protobuf 字段来自固定在 `compat/v1/proto/` 的原始 schema；新项目用自带的 Lua wire codec 编解码，不依赖旧仓库生成的 `.proto.pb` 文件。
5. 压缩标志为 1 时按 zlib 分块解压；分块累计长度不能超过声明长度，流结束时必须与声明长度和压缩输入长度一致。旧服务端在 `is_k12` 配置下仅对大于 20 KiB 且压缩后更小的出站数据压缩。

协议实现参考旧仓库 `game_server/agent/agent.lua` 的 `core:send`、客户端解包和 WebSocket 消息处理。

## 兼容规则

- 在兼容阶段保留消息名、字段编号、字段类型、required/optional/repeated 语义和现有帧格式。
- 不复用已发布字段编号，不把旧 protobuf 类型渗透到领域服务。
- 保持旧客户端依赖的响应字段、错误表现、广播顺序和心跳行为；逐项通过真实客户端验证。
- 协议缺陷先在适配层隔离。改变客户端线格式时，定义新版本和升级/并行策略，不静默改变旧协议。

## 扩展 v1 Protobuf

`compat/v1/proto/` 是 v1 的 schema 源文件；运行时由 `lualib/protobuf.lua` 直接解析，不需要生成 `.proto.pb` 文件。修改后服务器启动会先加载全部 schema，格式错误或 codec 不支持的声明会阻止启动。

新增字段时，为兼容已发布客户端，只在原消息中使用未占用的字段编号并添加 `optional` 或 `repeated` 字段。保留已有字段的编号、名字、类型和 required/optional/repeated 标签；不要给已有消息追加 `required` 字段，也不要复用删除字段的编号。Protobuf 解码器会跳过未知编号，因此旧客户端可忽略新响应字段；新服务端仍必须兼容字段缺失的旧客户端。

新增消息时，把定义放进已有 `.proto` 文件即可自动加载。新增 `.proto` 文件时，还要把文件名加入 `lualib/protobuf.lua` 的 `files` 列表。新增入站消息必须在 `service/session.lua` 中增加路由，再调用 Room、Chat、Directory 或其他领域服务；响应消息需要在 schema 中定义并从协议边界编码。协议表只在适配层出现，不传入领域服务。完成后更新[逐消息命令映射](design/protocol-command-map.md)，并用客户端生成的 Protobuf 类核对消息名、字段和值的往返编码。

当前 Lua codec 支持 proto2 的嵌套 message、`required`/`optional`/`repeated`，以及 `bytes`、`string`、`int32`、`int64`、`uint32`、`uint64`、`bool`、`float`、`double` 字段。它不支持 `enum`、`map`、`oneof`、`group`、`sint*`、`fixed*` 或 package 声明，显式 proto3 也会被拒绝；发现这些声明时会明确报错。字段选项目前不会应用 proto2 默认值；不要依赖 `[default=...]`。若需要这些特性，先扩展 codec 并用客户端 wire 样本验证，再提交对应 schema。

若改动破坏已有客户端的字段语义或帧格式，应新增 `compat/v2` schema 与适配器，保留 v1 到不再支持旧客户端为止；不要把破坏性变更覆盖到 v1。

## 当前实现边界

- TCP 和 WebSocket 二进制入口、消息白名单、旧 Protobuf schema、帧编解码和可选 zlib 压缩已实现；输入解压受声明长度上限约束。
- 客户端 v1 线格式不变。MySQL 持久化使用独立 schema version：历史 v1 JSON 继续读取，新写入 v2 用低代理项 `\udcXX` 转义非 UTF-8 字节，再由专用解码器还原原始 bytes；有效 UTF-8 字符串和普通 JSON 结构保持原样。这不会修改客户端帧或 Protobuf schema。
- 聊天正文按 Protobuf `bytes` 保存在 MySQL `BLOB` 中；频道、sender 和 room id 通过 Base64 SQL 字面量写入 `VARBINARY` 列，避免依赖数据库连接字符集。旧 `TEXT` 聊天列启动时自动转换为 `BLOB`。
- Protobuf 解码器限制 varint 为 64 位，并在读取 bytes、message、未知字段和 packed 字段前验证长度不超过当前消息余量；不合法字段号、定长 packed 数据长度和跨字段 varint 会被拒绝。
- accessToken 字段缺失或为空时保留旧登录语义；字段非空时只接受未撤销、未过期且与 id/room 匹配的本地 MySQL 凭证，用户身份和角色以凭证记录为准。凭证过期时，现有本地 token 会话也收到 kickOut 并断开。旧 via API 只返回课程状态和 beginAt，不作为登录身份或角色授权来源。客户端总会设置字段，但 token 值允许为空。
- 本地凭证用户的聊天频道和子房间查询范围来自本地授权表；空 token 用户按可配置 legacy 兼容策略使用客户端字段。
- 房间变量、扩展变量、一般事件、光标、白板、投票、聊天、心跳和服务端时间已有对应处理；RichText 操作 9000–9011 复用客户端共享模型，并沿用旧服务端定义的 `[9000, 9099)` 事件区间；事件 9099 按普通课堂事件处理。
- saveRoomData_Request 在本地保存版本与回放元数据，不访问客户端提供的 API URL；启用 legacy_room_metadata 后，只向服务端配置的旧平台 HTTPS endpoint 发送 token 和房间标识，并校验返回 id。subRoomVar_Request 只允许根房间成员发起；其 `int32 subRoom` 的数值路由尚无线上样本，旧实现的 Live 命令注册为空，当前客户端源码没有调用该请求。
- 已用原客户端的 `src/skynet/skynetWS.js` 和原 Web Protobuf 类完成 WebSocket 协议联调，覆盖登录、变量、聊天、白板写入/查询、样式、游标、RichText 9009/9006、计数变量、时间、重复登录、心跳保持和可选 token 认证；投票使用相同冻结 schema 验证。MySQL 快照回退后的变量、白板、RichText、元数据和投票恢复也已验证。完整测试范围与未覆盖项见[验证记录](verification.md)。
- TCP v1 帧已用最小客户端验证登录和变量往返，但尚未用原生 TCP 客户端验收；完整课程应用流程和真实数据下的 `subRoomVar_Request` 仍未验收。旧服务端本身为 no-op 的 `volumestatistics` 不作为课堂功能验收项。`saveRoomData_Request` 的网络输入和安全元数据处理已验证；录制资料 Provider 已根据旧源码实现；旧 via API 契约仅作源码核对，但尚未连接真实外部服务验证；本地 HTTPS 假服务已验证录制 Provider 的 TLS 与请求契约，客户端传入的 API URL 不会被请求。

## 后续替换

可以新增版本化适配器。旧协议适配器和新协议适配器都映射到同一内部命令/事件接口；删除旧适配器须等旧客户端退出支持范围。
