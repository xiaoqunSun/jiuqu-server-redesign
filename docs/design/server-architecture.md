# 实时服务端总体设计

- 版本：v0.1
- 状态：单节点 v0.1 核心实现已落地；容量、保留期和外部授权契约仍待产品确认
- 日期：2026-10-21
- 运行时基线：Skynet v1.8.0

本文定义新服务端的第一版目标架构。旧服务端仅作为消息行为和产品功能的证据，不作为新系统的模块模板。本文对未知业务采用明确的暂定假设，确认前不视为不可变需求。

新旧服务器的接入、身份、房间、存储、回放和运行方式对照见[新旧服务器设计对照](old-server-comparison.md)。

本文描述目标边界；当前代码已经实现单节点 Session、Room Directory、Room、Chat、MySQL Store、v1 协议适配、每连接有界出站队列、空闲 Room Actor 回收、单进程 Room Family 状态同步，以及受保护的管理与运行指标 API。指标覆盖连接和登录计数、命令延迟、数据库提交、房间恢复、各 Actor 队列和慢客户端断开。Family Coordinator 目前覆盖同一 Skynet 节点的房间关系和根到子的变量、事件、光标传播；每 5 秒及子房间登录前以根房间持久快照对账状态，并按独立的课堂事件水位补发已有成员期间漏掉的持久课堂事件。子房间无成员时会越过旧事件，避免把历史课堂事件发给后续登录用户；客户端出站队列失败仍会断开慢连接。录制资料 API 有可选的固定地址适配器，但尚未做真实外部服务联调。旧平台 via API 不提供身份与角色 claims，因此非空 accessToken 仍以本地凭证表为唯一来源。跨节点能力和身份凭证同步尚未实现。当前实现限制见项目 [README](../../README.md)。

## 1. 目标与边界

### 目标

- 在保留现有客户端消息名、Protobuf 字段和传输帧的前提下，重新定义服务端内部边界。
- 让每个房间的业务状态只有一个权威写入者，并给出可恢复、可审计的持久化路径。
- 将客户端连接、用户身份、房间成员和业务角色分开管理。
- 让 TCP/WebSocket、Protobuf、数据库和身份系统都位于边界层，领域逻辑不依赖这些实现。
- 首期用单个 Skynet 应用承载模块化服务；只有测量结果或产品需求支持时才增加分布式组件。

### 暂不作为首期目标

- 不承诺多节点下同一房间的并发写入或跨房间全局顺序。
- 不把现有 Redis key、Mongo 文档、本地回放文件或 Skynet 服务名当作新系统的兼容接口。
- 不在领域服务中直接使用 Protobuf 生成对象或旧消息名。
- 不在缺少量化容量目标时预设每房间人数上限或部署节点数。

## 2. 设计摘要

1. **Skynet 模块化单体**：首期一个 Skynet 节点；网络入口、会话、房间路由、领域 Actor、存储适配器以清晰模块组织。
2. **每个 Room 一个单写者 Actor**：房间内命令在一个有序队列中执行。Actor 是房间内存状态的唯一权威。
3. **连接与成员关系分离**：Session 表示一次连接；Membership 表示用户在某个房间中的成员身份和权限。断线不等同于业务上的离开。
4. **根房间和子房间显式建模**：根 Room Actor 是家族共享状态的权威写者；Room Family Coordinator 维护根/子房间注册、路由和恢复对账；子 Room Actor 保存家族状态副本及本房间状态。
5. **边缘协议适配**：旧 TCP/WebSocket 帧和 Protobuf 映射为内部命令；响应从领域事件映射回旧消息。
6. **MySQL/InnoDB 作为首期持久化基线**：业务事件日志和状态快照构成可恢复来源；聊天记录单独按频道顺序存储。心跳和在线连接不写入事件日志；光标只以批量采样事件保存，用于兼容回放。
7. **不使用 Redis Pub/Sub 作为一致性通道**：首期同节点 Actor 间直接路由；未来跨节点时再引入明确的房间归属和可靠传递方案。

## 3. 从旧实现得到的行为证据

| 客户端可见能力 | 旧协议/旧行为线索 | 新设计的归属 |
| --- | --- | --- |
| 登录、心跳、踢出 | loginRequest、loginResponse、kickOut、heartbeat、ping/pong | 协议适配器、Session 管理、身份与成员授权 |
| 房间成员 | onMemEnterRoom、onMemLeaveRoom，登录响应含 studentID | Room Actor 管理 Membership；连接断开另作 Presence 状态 |
| 普通变量、扩展变量、增量变量 | updateVar_*、updateExtVar_*、queryExtVar_*、addVar_* | 房间状态命令；验证、合并和广播由 Room Actor 决定 |
| 房间事件与富文本 | event_*，事件 ID 9000–9011 对应富文本操作 | Room Actor 中的事件/富文本子域；内部事件不依赖 Protobuf |
| 白板页面与样式 | pageUpdate_*、pageCopy_*、pageQuery_*、style* | Room Actor 管理页面状态；持久变更写入事件日志 |
| 投票 | create/end/close/submit/queryVote_* | Room Actor 管理投票状态、选项校验与投票权限 |
| 聊天 | chatListen/Unlisten/Send/History | Chat Service 串行处理频道订阅、持久化和广播；历史记录进入持久化存储 |
| 根/子房间交互 | rootRoom、subRoom、subRoomVar_*，旧实现通过 Redis Pub/Sub | 根 Room Actor 持有共享状态；Room Family Coordinator 管理子房间路由、对账和事件补发 |
| 回放和课堂上下文 | saveRoomData_Request、旧实现写临时文件并可转存 Redis | 由服务端房间策略决定记录内容与保留期；客户端字段仅作兼容输入 |
| 服务端时间、统计 | servertime_*、volumestatistics | 接入层或独立统计管道，不进入 Room 状态机 |

完整线格式和当前兼容规则见 [protocol-compatibility.md](../protocol-compatibility.md)，逐消息行为见 [协议命令映射](protocol-command-map.md)。旧实现允许缺少 accessToken，并使用客户端提交的 id、房间信息和 isMaster。当前实现无 token 或空 token 时按旧语义登录并标记为未验证；有非空 token 时只能通过 MySQL 本地权威凭证表验证身份、房间和角色。旧 via API 只校验课程状态并返回 beginAt，不用于登录鉴权。客户端提供的 API URL 不参与请求构造。

## 4. 运行时组件

~~~mermaid
flowchart LR
    C[TCP / WebSocket 客户端] --> G[Gate 与帧解码]
    G --> S[Session Actor<br/>协议适配器]
    S --> I[身份验证与授权适配器]
    I --> A[可信身份 / 课堂授权服务]
    S --> D[Room Directory]
    D --> R[Room Actor<br/>每个房间一个]
    D --> F[Room Family Coordinator<br/>每个根房间一个]
    R --> P[Persistence Adapter]
    F --> P
    P --> DB[(MySQL / InnoDB)]
    R --> Q[Delivery Router]
    F --> Q
    Q --> S
    S --> H[Chat Service]
    H --> P
    H --> Q
    M[私有管理接口] --> U[应用服务入口]
    U --> D
~~~

这些是逻辑边界，不要求每个方框都是单独进程。首期 Skynet service 的划分如下：

- 每个网络连接一个 Session Actor，独占 socket 读写、心跳计时和协议编解码上下文。
- 一个 Room Directory 管理本节点 Room Actor 的单飞创建、查询和关闭；同一房间并发首次登录只创建一个 Actor。
- 每个活动房间一个 Room Actor，拥有该房间状态和命令队列。
- 每个根房间一个 Room Family Coordinator，维护根/子房间关系、家族消息路由和漏投递恢复；根 Room Actor 持有可恢复的家族共享状态。
- Delivery Router 管理 Session 地址并通过有界队列投递；慢客户端不能阻塞房间状态机。
- Persistence Adapter 管理 SQL 连接、事务和快照；领域 Actor 不拼接 SQL。
- Chat Service 用一个串行队列处理频道订阅、历史查询、限流、消息持久化和广播；多频道消息因此按同一顺序完成。只有测量表明它成为瓶颈后，才考虑按频道分片。
- 管理接口在独立的监听面，默认关闭并要求独立 Bearer token；公共客户端协议不能调用管理命令。

## 5. 领域状态所有权

### Identity

Identity Resolver 提供两条兼容路径：
- accessToken 非空时必须匹配由权威来源写入的本地凭证记录；未命中、过期或撤销时拒绝登录。旧 via API 不提供身份和角色，不作为授权来源。
- accessToken 缺失或为空时进入 legacy 兼容路径，按旧协议使用客户端 id、room、rootRoom、subRoom 和 isMaster 建立 legacy identity 与成员上下文，不能仅因字段缺失或为空拒绝登录。该身份明确标记为 legacy_unverified，保留旧客户端能工作的语义，但不把它误认为强身份认证。

legacy 路径的 id 和 isMaster 由客户端声明，服务器无法仅凭这些字段证明用户身份。无 token 路径保留该行为。上线前应通过受信任入口或房间策略缩小暴露面。非空但未登记或无效的 accessToken 一律拒绝，不允许利用 token 错误降级到空 token 路径。

### Session

一次网络连接对应一个 Session Actor，包含 sessionId、身份上下文、最后活动时间、连接状态和出站队列。Agent/Session 按连接创建，不按用户创建。旧协议没有通用 roomId 字段，因此 Session 绑定主房间上下文；只有带专门子房间字段的命令才能路由到子房间。实际客户端的 subRoom 使用方式需核对。Session 不拥有白板、投票或房间变量。

### Membership

表示一个身份在一个 Room 中的业务成员关系，记录角色、能力及其来源。带 token 的路径使用服务端验证的角色；无 token 的 legacy 路径保留客户端 isMaster 的旧语义并标记为未验证。角色检查集中在命令授权处；onlyToMaster 只影响消息路由，sender 由 Session 身份生成。disableWordsFilter 按当前客户端兼容规则处理，legacy 路径对应的未验证权限风险需单独监控。

### Room

Room Actor 管理：

- 本房间成员与 Presence；
- 普通变量和扩展变量；
- 白板页面、节点和样式；
- 投票及投票详情；
- 富文本文档和通用课堂事件；
- 房间生命周期和顺序号。

实时光标位置、心跳和连接队列是瞬时数据；光标回放另通过低频批次保存。普通变量与扩展变量映射为内部 Value（标量或对象）和明确的 Set、Delete、Merge、Increment 操作；不假设普通变量原始 bytes 一定是 JSON。旧协议中的字符串 "null"、扩展变量的 varIsTable、路径分隔和旧字段名由适配器解释，不进入领域层。

### Room Family

根房间及子房间构成一个 Room Family：

- 每个子房间保有自己的 Room Actor 和本地顺序号。
- 根 Room Actor 持有家族共享变量、扩展变量及 RichText 状态，并以根房间事件序号排序；Family Coordinator 维护子房间目录并把根房间变更路由到已注册子房间。
- 持久课堂事件按根事件序号补发，子房间维护独立课堂事件水位；快照对账恢复变量和 RichText 当前状态。瞬时光标不补发。
- 跨房间操作使用明确的命令类型，不通过任意 Redis channel 名传播。
- 房间顺序号只保证单房间顺序；根房间序号定义家族广播顺序。不同子房间之间不承诺全局总顺序。
- 子房间查询只接受根房间成员发起，并由 Directory/Family 校验目标后路由到对应 Room Actor；v1 的整数目标映射仍需真实客户端样本确认。

## 6. 命令处理与顺序保证

所有会改变房间状态的输入先成为内部 Command，至少带有：

~~~text
commandType, roomId, actorSubject, sessionId, receivedAt, payload
~~~

处理顺序：

1. Session Actor 校验帧长度、消息名、压缩标志并解码旧 Protobuf。
2. 协议适配器构造内部命令；sender 等逐消息字段不能覆盖 Session 身份。
3. Identity Resolver 对带 token 的连接验证令牌、课堂范围和房间权限；缺少 token 时按明确启用的 legacy 策略建立未验证身份上下文。
4. Room Directory 将命令路由到唯一 Room Actor；需要子房间目标解析时由 Directory/Family 选择目标 Room，家族共享状态仍由根 Room Actor 写入。
5. Actor 在有界 FIFO 命令队列中校验当前状态和角色，生成下一个领域事件。
6. 对持久化命令，Persistence Adapter 在 MySQL/InnoDB 事务中追加带版本的事件并更新聚合序号。事务成功后 Actor 应用事件到内存状态。
7. 成功后才生成旧协议响应/广播，并经 Delivery Router 投递。实时光标响应不等待数据库；Room Actor 按固定间隔合并并持久化回放采样。

Skynet service handler 可能因 skynet.call 让出执行权，因此“一个 Lua service”本身不自动等于单写者。实现必须通过单一命令消费者或明确的串行队列保证状态变更和持久化确认期间不会并发处理另一个变更。任何数据库等待都要有超时和背压；不能在房间 Actor 中等待外部 HTTP 服务。

旧协议没有通用请求 ID、房间事件序号或客户端确认位。因此当前版本只能保证服务端按单连接写出顺序，不能对断线前最后一条消息提供端到端 exactly-once。新协议版本应增加 requestId、eventSeq 和可恢复游标。

## 7. 生命周期、重连和过载

Room 生命周期建议为：

~~~text
Absent -> Loading -> Active -> IdleGrace -> Closing -> Closed
~~~

- 首次访问时 Directory 单飞创建 Room Actor；Actor 先恢复快照和后续事件，再接受命令。
- 房间无人在线后进入可配置的 IdleGrace；关闭条件由课堂服务/房间策略决定，不沿用旧代码中的固定两小时规则。
- 关闭前完成持久化、生成最终快照并记录关闭原因。活动中的白板/投票不会仅因 Skynet Actor 回收而丢失。
- 当前实现中，Session 断开或心跳超时会移除房间成员并广播 onMemLeaveRoom，清理房间和聊天索引后退出该连接的 Session Actor；Room 命令队列满时会保留 Directory 索引并重试清理。切换房间或替换同身份连接时，Room 成员代次会阻止延迟退出命令误删新加入的成员。没有 30 秒 Presence 重连宽限。若产品需要重连宽限，应先确认客户端成员列表与课堂统计对延迟离开的预期，再作为明确行为变更实现。
- 旧登录服务采用单点登录，新 Session 取代该身份的旧 Session 并发送现有 kickOut；新设计首期保留一个 Identity 同时只有一个有效 Session。实现上仍是每个连接一个 Agent/Session Actor，Identity 到当前 Session 的索引负责替换旧连接。
- Session 出站队列有上限。光标/Presence 更新可合并；不可合并的队列持续满时断开慢客户端，让其重新登录并查询状态。一个慢客户端不能拖慢同房间其他成员。
- Room、Directory、Chat 和 Store 串行命令队列均以 outstanding 上限限制（Room 256，其余默认 512）。Room/Chat 客户端命令超过上限时关闭该连接；Store/Directory 内部调用返回明确过载错误，不继续积压。

## 8. 持久化与回放

### 首期存储提案

用 MySQL/InnoDB 作为业务持久化来源，首期不引入 Redis 作为房间状态权威源。建议逻辑表：

~~~text
aggregate_event(aggregate_type, aggregate_id, seq, event_type, schema_version, actor_id, occurred_at, payload_json)
aggregate_snapshot(aggregate_type, aggregate_id, seq, schema_version, state_json, saved_at)
chat_message(channel_id, seq, message_id, sender_id, text, created_at)
room_lifecycle(room_id, is_closed, updated_ts) -- 管理面关闭状态，独立于客户端房间事件
~~~

- 逻辑模型中的 aggregate_event 主键为 (aggregate_type, aggregate_id, seq)。当前实现只将房间状态写入 `room_events`/`room_snapshots`；根 Room Actor 也为家族共享变更分配房间序号，Family Coordinator 不维护独立持久化聚合。新写入使用 schema_version=2 的二进制安全 JSON 编码；非 UTF-8 字节（包括对象键）以 `\udcXX` 转义，普通 UTF-8 字符串与 JSON 对象/数组不增加类型包装。恢复同时读取历史 schema_version=1 与当前版本，未知版本会拒绝恢复而不猜测解码。
- Room Actor 为持久事件分配顺序号；数据库事务插入事件并更新快照。未提交的事件不能被广播为成功。
- 定期生成快照，恢复时载入最新快照并重放更高序号的事件。快照间隔以配置和实际写入量决定，不在设计阶段锁定任意条数。
- 写入失败时不应用或广播该持久化命令；记录房间写停、数据库延迟及队列长度。房间可继续处理只读查询和被允许的瞬时消息，但不能假报持久化成功。
- 会话和心跳不进房间事件日志。光标在 Room Actor 生命周期内进入采样回放流；每 250 毫秒按身份合并为一批写 MySQL，每位成员仅保留该批次的最新位置。saveRoomData replayMode 控制回放读取权限，避免晚到的录制元数据丢失此前事件。
- 白板、投票、富文本、房间变量和需要重放的课堂事件暂按可恢复状态设计。聊天历史按频道保存并有保留策略。最终需由产品明确每类数据的 RPO、保留期和是否回放。
- saveRoomData_Request 沿用旧客户端的 replayMode 作为回放读取开关；房间事件从 Actor 创建时持续采集，读取仍只通过需要管理 token 的 API 提供。客户端 data.api 不参与请求目的地址，录制资料 Provider 只能使用服务端配置的固定 HTTPS 地址。

该方案以每个持久化变更一次事务作为清晰的首版语义，实际延迟和吞吐需在有容量目标后测量，再决定是否加入批量提交或异步归档。若业务要求数据库不可用时继续接收持久化变更，需另行定义可接受的数据丢失窗口和本地 WAL 方案。

## 9. 客户端协议适配

协议适配器只负责帧解析、Protobuf 编解码、旧字段归一化及响应格式映射。内部命令与事件使用独立模型。

| 消息族 | 兼容入口/出口 | 领域处理 |
| --- | --- | --- |
| 登录和心跳 | loginRequest/Response、heartbeat、ping/pong、kickOut | 身份授权、Session 和 Membership 生命周期 |
| 成员与变量 | onMemEnterRoom、onMemLeaveRoom、updateVar_*、updateExtVar_*、addVar_* | Room Actor 状态命令 |
| 课堂事件 | event_*、updateCursorPosition_* | 版本化领域事件；光标为瞬时事件 |
| 白板 | page*、style* | 页面/节点/样式操作及查询 |
| 投票 | create/end/close/submit/queryVote_* | 投票状态机、唯一投票约束和结果查询 |
| 聊天 | chatListen/Unlisten/Send/History、chatRecv_Response | Channel 授权、限流、过滤和消息历史 |
| 家族交互 | subRoomVar_*、rootRoom、subRoom | 根 Room Actor 持有共享状态；Family Coordinator 路由并恢复漏投递 |
| 元数据/统计 | saveRoomData_Request、servertime_*、volumestatistics | 服务端策略、时间适配、统计管道 |

兼容阶段保持消息名、字段编号/类型、required/optional/repeated 语义和外层帧格式；不复用已发布字段编号。压缩输入必须验证解压后长度并限制最大解压大小。消息名必须在白名单内。未知消息、格式错误或超限帧按兼容策略关闭连接并留下结构化原因，不把任意客户端输入转发给领域层。

兼容线协议也需要明确字段信任边界：无 token 路径按 legacy 策略解释 id、房间字段和 isMaster，并标记为未验证；带 token 路径以验证结果为准；sender 始终由 Session 生成。聊天频道和 data.api 由服务端策略控制。所有错误要映射到该旧消息已有的错误字段/表现；旧协议没有可表达的错误时，不发送成功广播，并记录诊断。上线前必须用真实支持中的客户端确认每种消息的响应时机、字段和广播行为。

## 10. 安全与管理面

- accessToken 非空时必须校验且 fail closed；本地 access_tokens 表按 HMAC-SHA1 摘要、身份和房间查找，记录提供服务端角色与 beginAt。旧平台 via API 没有身份/角色 claims，不作为授权源。缺少或空 accessToken 时走显式 legacy 兼容策略，沿用旧客户端 identity/role 字段并标记为未验证。
- 对每个命令执行房间级授权。当前 saveRoomData 和投票生命周期命令要求教师角色，学生查询投票时隐藏他人明细；legacy 连接仍按兼容规则解释旧 isMaster 字段。onlyToMaster 只表示广播范围，不能授予权限；disableWordsFilter 的 legacy 行为及风险需要明确保留并监控。
- 持 token 连接的聊天频道由服务端本地授权表确认；空 token 兼容模式默认保留旧版任意合法频道行为，可在 legacy_chat_channels_unrestricted 设为 0 后关闭。消息长度、频道数、发送频率和解压尺寸由服务端限额。
- WebSocket/TCP 只暴露客户端业务面。管理接口绑定内网并采用独立鉴权；它调用应用命令，不直接读写房间内存或数据库表。
- 日志不得输出 access token、完整聊天正文或可重放的认证凭据；所有外部请求使用服务端固定目的地址和超时。

## 11. 故障和运维行为

| 故障 | 首期行为 |
| --- | --- |
| MySQL/本地凭证表不可达 | 带 token 的登录失败（fail closed）；无 token 登录按显式 legacy 策略处理；已认证会话按本地到期策略处理 |
| MySQL 不可达 | 持久化命令拒绝/暂停，不广播成功；报警并保持 Actor 可恢复 |
| Room Actor 崩溃 | 关闭/失效 Session 路由；客户端重连后从快照和事件重建房间 |
| 节点进程崩溃 | 所有连接断开；恢复后从持久化记录重建，客户端重连 |
| 客户端发送坏帧 | 关闭该连接，记录帧类别和大小，不记录认证秘密或任意正文 |
| 慢客户端 | 合并可丢弃消息；有界队列仍满则断开该 Session |
| 某房间过载 | 对该房间限流/拒绝新变更，不阻塞其他房间 Actor |

首期结构化日志和指标至少包含：连接数、登录成功/拒绝数、活跃房间数、各 Room Actor 队列长度、每类命令延迟、数据库提交延迟/失败数、出站队列深度、慢客户端断开数和房间恢复时长。用 roomId、sessionId 和脱敏 subject 做关联。

## 12. 部署与扩展路径

- 首期一个 Skynet 应用节点和一个 MySQL 服务；不要求 Redis、消息队列或独立微服务集群。
- Room Directory 使用本地 Actor 注册表和单飞创建；模块接口预留 RoomPlacement，但首期不实现跨节点租约。
- 需要横向扩展时按 roomId 将房间分配给唯一节点，加入带过期时间和 fencing token 的 owner lease；重分配前先使旧 owner 失效，再从持久化记录恢复。Room Family 的根和子房间需要同节点放置，或明确跨节点调用边界。
- 多节点之间通过 Skynet Cluster 或可靠消息通道传递有类型的命令/事件，不通过 Redis Pub/Sub 传播权威状态。跨节点后再定义节点故障、重复投递、网络分区和会话回程路由。
- 不在没有单机容量数据之前拆分 Chat、Delivery 或 Persistence 为独立集群。

## 13. 需要产品/部署确认的前提

这些事项不阻止形成架构提案，但决定兼容边界和容量方案：

1. accessToken 存在时由谁签发，令牌是否能包含课堂/房间角色？无 token legacy 路径是否能经过受信任入口或房间白名单隔离？
2. 根房间和子房间的真实语义是什么？用户登录后应同时加入哪些房间？共享变量和广播要保证怎样的顺序？
3. 白板、变量、投票、富文本、聊天和回放分别要求什么持久性、RPO 和保留期？当前实现按每 250 毫秒、每人保留最新位置的方式采样光标，产品是否需要更细粒度尚待确认。
4. 单房间最大在线人数、消息峰值、可接受延迟和可用性目标是多少？
5. MySQL 的目标版本、现有实例隔离方式、备份策略和回放数据保留策略是什么？
6. 哪些现有客户端版本必须兼容，是否能提供真实客户端或抓包样本用于协议行为核对？

以上问题确认后，更新本文的假设，再将架构提案拆为具体领域接口、持久化 schema 和 ADR。当前不应先把所有旧功能直接实现；先核实消息行为和持久化级别，避免把历史偶然行为固化成新产品规则。
