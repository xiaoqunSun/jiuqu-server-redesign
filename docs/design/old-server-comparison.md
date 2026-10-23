# 新旧服务器设计对照

- 对照日期：2026-10-22
- 对照对象：旧仓库 `jiuqu-game-server` 的当前源码，以及本项目的新设计和当前实现
- 目的：说明哪些客户端能力和运行方式延续下来，哪些内部模型已经重新设计

本文是设计对照，不是迁移方案。旧服务器源码用于确认客户端行为和现有业务线索；新项目不继承旧服务器的数据模型、Redis key、服务名或部署拓扑。协议兼容也不代表旧服务器的数据可以直接由新服务器读取。

## 概览

两套服务都使用 Skynet/Lua 的 Actor 服务模型，以房间承载实时协作，并需要处理同一批客户端消息。新项目保留旧客户端的帧格式、消息名和 Protobuf 字段，但把内部边界改为 Session、Identity、Membership、Room Actor 和持久化适配器。最明显的变化是：旧服务主要依赖房间内存状态、Redis 协调及临时回放文件；新项目把 MySQL 事件日志和快照作为房间业务状态的恢复来源。

因此，新服务器可以兼容现有客户端的网络协议，但不能据此认为它与旧服务器共享状态、认证流程、回放数据或所有业务细节。

## 延续下来的部分

- **运行时基础相同**：两边都用 Skynet 服务和 Lua 模块组织接入、会话、房间及存储代码。
- **按连接隔离网络处理**：旧服务器由 Gate/Watchdog 将连接交给 Agent；新服务器由 TCP/WebSocket Listener 创建 Session。两者都让一个连接的读写和协议处理有独立服务上下文。
- **按房间组织实时状态**：两边都有 room manager/directory 动态取得或创建房间服务，并由房间服务维护成员、变量和协作状态。
- **客户端协议继续兼容**：新项目保留旧版传输帧、Protobuf schema 和消息名，通过兼容层映射到新的内部命令。
- **主要课堂能力仍有对应入口**：登录、成员进入/离开、普通和扩展变量、事件、白板、投票、聊天、心跳及服务端时间都有新旧路径。
- **配置文件启动**：旧项目以 `etc/config` 等 Skynet 配置文件选择运行参数；新项目由 `make run` 将 `etc/config.lua` 直接交给 Skynet。运行参数仍由配置文件维护。
- **MySQL 并非全新引入**：旧服务器已有 MySQL 聊天持久化服务；新项目把 MySQL 扩展为房间状态、聊天和本地 token 授权的主要持久化后端。

## 关键设计差异

| 关注点 | 旧服务器源码现状 | 新服务器设计与当前实现 |
| --- | --- | --- |
| **接入和服务划分** | `main.lua` 启动 Watchdog、Gate、Agent 管理器、Room Manager、聊天、在线状态和 Web 管理服务。 | Listener 接入 TCP/WebSocket，每条连接创建 Session；Room Directory 路由房间，Auth、Chat、Store 分开。仍是单个 Skynet 应用，不先拆成微服务集群。 |
| **Session 与身份** | Agent 保存连接上的 `id`、`room`、`rootRoom` 和 `isMaster`。房间内按玩家 ID 找到旧连接并踢出；该判断主要发生在当前房间。 | Session 表示一次连接，认证结果提供 Identity/角色声明，Room 维护 Membership。当前 Room Directory 按进程内的身份 ID 维护在线 Session，同一身份在另一个房间登录也会替换现有连接。 |
| **Token 验证** | accessToken 缺失时跳过 viaService。字段存在时调用配置的外部 viaApi；若未配置则放行。旧流程的 isMaster 来自登录消息。 | 缺失或空 token 走 legacy_unverified；非空 token 必须命中新 MySQL HMAC 凭证，身份和角色由记录决定。旧 via API 只返回课程状态和 beginAt，不能提供身份或角色，因此新服务器不把它作为登录凭证来源。 |
| **房间并发与扇出** | Room Manager 用队列锁避免重复创建房间；每个 Room 下还创建 Player Group Actor，每组最多 50 人，由各组执行广播和成员连接管理。Room Actor 通过普通 Skynet handler 接收命令，没有覆盖所有变更处理的显式串行队列；handler 中的 `skynet.call` 会让出执行权，因此不能仅凭同一个服务地址推断严格的变更顺序。 | 一个 Room Actor 管理房间状态和成员，直接向 Session 投递；Room Directory 负责房间创建与路由，Room handler 用串行队列保护状态命令。没有旧式 50 人 Player Group 分层，也没有已经量化的单房间容量承诺。 |
| **房间状态与恢复** | 变量等状态主要保存在 Room Actor 内存。Live 模式下，部分变量放入 Redis 缓存；源码没有统一的版本化房间事件日志加快照恢复流程。进程重启后的恢复能力取决于具体缓存或录制路径。 | MySQL/InnoDB 保存带序号的房间事件和快照。Room Actor 恢复时读取快照并重放后续事件；持久变更先提交，再广播成功结果。心跳和连接队列仍是瞬时状态；光标实时状态瞬时，但另以采样批次进入回放事件流。 |
| **性能诊断与过载** | 可选 `performance_monitor=1` 每秒采样 Room 消息队列，统计压力阈值，并在 Room 退出时写 JSON 报告。 | 有界串行队列限制 Room、Directory、Chat、Store 的待处理命令；受保护的 `GET /metrics` 提供当前各队列深度、命令延迟分布、数据库提交与房间恢复耗时、连接登录计数和慢客户端断开数。指标仅在本进程内累计，没有兼容旧格式的每房间历史报告；具体容量目标待业务数据确认。 |
| **数据库用途** | Redis 用于在线状态、服务心跳；Live 模式还用于根/子房间 Pub/Sub 和变量缓存。聊天消息另由 MySQL 服务异步保存。MongoDB 的音量统计路径仍在代码中，但 `volumestatistics` handler 当前没有调用它。 | MySQL 是房间事件、快照、聊天记录和本地 token 凭证的持久化来源。当前实现不依赖 Redis 或 MongoDB，也不会读取旧 Redis key 或旧数据库 schema。 |
| **根房间和子房间** | Live 模式通过 Redis channel 在根房间和子房间之间转发部分命令和广播；`subRoomVar_Request` 由根房间发起。 | 单节点 Room Family Coordinator 维护根/子 Room Actor 注册关系；根房间的变量、扩展变量、事件和光标向已注册子房间传播。每 5 秒及子房间登录前用根房间持久快照对账状态，并按独立的课堂事件水位从 MySQL 补发已有成员期间漏掉的持久课堂事件。慢客户端仍可能因出站队列满而断开，瞬时光标不补发。无成员时推进事件水位；全进程重启后新建子房间只同步当前状态，不重放旧课堂事件。新服务仅允许根房间成员发起子房间变量查询；非空 token 的子房间查询按本地凭证授权，空 token 兼容范围可配置；未知且无持久化状态的子房间返回空值，不创建 Actor。跨节点传播未实现；非零 `int32 subRoom` 到真实 `room_id` 的线上映射仍待样本核对，旧源码中的零值广播也没有可用客户端样本确认。 |
| **聊天** | Chat Service 在内存保留最多 500 条近期历史，广播后异步通知 MySQL 持久化服务。客户端可传入频道名；当前代码没有统一的频道授权策略，disableWordsFilter 也由客户端直接控制。 | Chat 服务将消息写入 MySQL 后再广播，并从 MySQL 查询历史；数据库读取故障时使用最多 1024 个频道、每频道最多 500 条的本地回退缓存。频道路由只保留仍有订阅者的频道。token 用户按本地授权频道表和房间别名校验；空 token 默认保留任意合法频道的旧行为，可配置关闭。disableWordsFilter 和教师命令仍依赖 legacy 登录中不可信的 isMaster。 |
| **录制与回放** | Room 将变量、事件、光标、白板、投票和聊天等写入 newReplay/tmp_* 本地临时文件；配置允许在特定模式下将部分文件放入 Redis。saveRoomData 可能请求外部课堂资料。 | 新服务端将房间状态事件持久化到 MySQL；saveRoomData 开启 replayMode 后可经受保护管理 API 分页读取新格式事件。可选 legacy_room_metadata 复用旧固定 HTTPS endpoint，并校验返回房间 ID；客户端提供的 URL 始终忽略。客户端置 saveToReplay 的聊天和房间光标从 Room Actor 创建时进入持久化事件流；saveRoomData replayMode 控制是否开放读取。光标按房间聚合，默认每 250 毫秒最多保存一批，每位成员保留最新位置。新格式不导入旧回放文件。 |
| **在线统计** | 每个 Room Actor 内存累计身份在线时长、上课时长、首次进入时间及进出历史；每 5 秒统计一次，并由 `/onlineInfo` 查询。Actor 关闭或进程重启后统计消失。 | Room Actor 内存以 5 秒周期采样，成员离开或查询时结算；受保护的 `GET /room/online` 提供摘要和可选进出历史。Actor 回收/重启后统计消失，房间业务状态仍由 MySQL 保留。 |
| **在线状态外部通知** | `realtimeSystem` 对 `s_`、`t_`、`m_` 身份更新 Redis 在线 Hash/Set，并发布 `skynet:login`、`skynet:logout`；另为服务维护带 TTL 的存活 key。 | Room Directory 在进程内维护在线身份；管理 API 可读取在线房间和成员。当前没有 Redis Presence 发布器或服务存活 TTL，依赖旧 Redis key/channel 的外部消费者需要单独接入。 |
| **管理和扩展** | main.lua 会启动同进程的 simpleweb 管理/查询服务，提供房间查询、在线统计、变量/事件操作、stopRoom 和 updateEndAt；`stopRoom` 设置 Room 内存 stop 标记，由监控循环完成回放收尾、清理 Player Group 并退出 Actor，不持久化关房状态。源码也保留 Cluster 入口和 Redis 跨房间通信路径。 | 新项目提供独立管理端口，默认关闭并要求强 Bearer token，可查看房间与在线统计、更新变量/事件/结束时间和关闭/开放房间；管理关闭状态写入 MySQL 并在进程重启后保留，活动房间关闭会立即踢出成员并拒绝新登录。K12 房间使用 Provider 返回的 `endAt`，缺少时沿用 Room 启动时间回退；管理员手动设置或清除后优先。跨节点所有权和多节点故障处理仍未实现。 |
| **运行配置** | 旧仓库包含 `etc/config`、`config.local`、`config.live` 等不同配置文件。 | 新项目使用 `etc/config.lua` 作为直接启动配置，Skynet 基线固定为上游 v1.8.0。 |

## 需要区分的“设计目标”和“已实现”

新架构要求服务端掌握身份与角色，并在每条命令上执行明确的房间授权。当前代码验证 token 来源和房间成员身份、防止伪造 sender；保存回放元数据、投票生命周期需要教师角色，学生查询投票时不能读取他人明细。legacy 登录按旧客户端 isMaster 行为兼容，仍不具备可信角色证明。token 用户的聊天频道由服务端登记；空 token 默认允许旧客户端使用任意合法频道。

旧仓库另有 `login/logind.lua` 和 `login/gated.lua`，其中使用 `snax.loginserver` 并关闭多点登录；但 `game_server/main.lua` 的常规启动路径没有启动它们。本对照按该常规启动路径描述旧服务行为，若实际部署另外启用了这条登录链路，单点登录范围需要据部署配置复核。

以下目标组件或能力当前尚未交付：

- 跨节点 Family 路由、持久化房间目录和多节点共享状态。
- 跨节点房间所有权和多节点故障处理。
- 其他身份系统的凭证签发/同步、旧平台 token 到本地授权表的可信导入，以及旧回放文件和 Redis 数据的读取转换。旧 via API 契约已核对，但不提供新服务所需的身份与角色授权。
- 旧 `realtimeSystem` 的 Redis 在线 Hash/Set、登录/登出 Pub/Sub 和服务存活 TTL 尚未接入；旧消费者若仍依赖这些内部信号，需要提供对应接口和部署约定。

当前新代码已经完成的实现范围、协议联调证据和未验证项见 [README](../../README.md)、[实现验证记录](../verification.md) 与[总体设计](server-architecture.md)。

## 对客户端兼容的实际含义

当前兼容目标是网络边界：旧客户端可使用原帧格式和消息 schema 与新服务交互。以下行为不由“协议一致”自动保证：

- 非空 token 必须命中新 MySQL 凭证；旧平台 token 需经可信授权流程写入本地表。空 token 仍走未验证兼容路径。
- 旧房间变量、聊天历史、Redis 在线数据及回放文件不会自动出现在新服务器中。
- 新房间的持久化、Room Actor 回收和恢复语义与旧服务器不同。
- saveRoomData 的旧平台资料读取由可选 Provider 按固定服务器端 HTTPS endpoint 实现，尚未做真实服务联调；子房间路由还需真实客户端数据确认。
- 新服务器目前按单节点运行设计，不能与旧服务器的 Redis Pub/Sub/Cluster 部署互换。

若将来决定切换实际流量，需要另行制定数据处理、认证凭证准备、客户端版本覆盖、回滚和并行运行方案；这些工作不属于本设计对照，也不应被误解为新项目当前已具备的迁移能力。

## 源码依据

旧仓库的主要依据：

- 启动与接入：`game_server/main.lua`、`game_server/watchdog.lua`、`game_server/agent/agent.lua`、`game_server/agent/agent_handler.lua`
- 房间和成员：`game_server/gameplay/room_mgr.lua`、`game_server/gameplay/room.lua`、`game_server/gameplay/player_group.lua`
- Redis/在线状态：`game_server/gameplay/live.lua`、`game_server/realtimeSystem.lua`、`game_server/db/redisd.lua`
- 认证和聊天：`game_server/viaService.lua`、`game_server/chatService.lua`、`game_server/chatPersistService.lua`
- 启动配置：`etc/config`、`etc/config.live`、`etc/config.local`

新项目的主要依据：`service/session.lua`、`service/room_directory.lua`、`service/room.lua`、`service/auth.lua`、`service/chat.lua`、`service/store.lua`、`etc/config.lua`。
