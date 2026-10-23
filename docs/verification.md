# 实现验证记录

日期：2026-10-22

## 2026-10-23 二进制安全持久化

发现旧 v1 兼容协议将房间变量作为 Protobuf `bytes`，而原持久化实现直接把其值放入 UTF-8 JSON，任意非 UTF-8 值和对象键无法安全写入 MySQL。新增独立的持久化 schema v2：非 UTF-8 字节及对象键使用可逆 `\udcXX` 转义，其他值仍按普通 JSON 表示；schema v1 的历史 JSON 仍可读取。客户端帧与 v1 Protobuf schema 未变化。

使用 Skynet v1.8.0 自带 Lua 运行时验证了中文、含 NUL/非法 UTF-8 字节的值、二进制对象键、嵌套数组/null 往返、旧 schema v1 解码及管理响应二进制 envelope。另在新建的临时 MySQL 8.4.10 数据目录中，只绑定 `127.0.0.1`，通过应用 Store 服务确认 v2 快照、房间事件、回放分页、Family class_event 查询和二进制 room id 的读写均逐字节往返，数据库返回的 schema_version 为 2。从预置 UTF-8 `TEXT` 的旧表启动时，Store 自动将 `chat_messages.message_text` 转为 `BLOB`；`save_chat_batch`、`save_chat` 和 `chat_history` 对含 NUL/非法 UTF-8 的正文、频道、sender 也逐字节往返。探针账号使用 `mysql_native_password`；没有访问或修改本机现有 MySQL 库，临时实例与数据目录已停止并清理。Skynet `make -j4` 构建和项目 Lua 5.4 语法解析通过。

## 原客户端 WebSocket

使用旧仓库的 `src/skynet/skynetWS.js` 和其生成的 Web Protobuf 类连接新服务端 WebSocket 端口。客户端发送空 `accessToken`，与旧客户端的实际登录调用一致。

- 登录和房间成员信息；同一身份再次登录时旧连接收到 `kickOut`。
- 房间变量、扩展变量读写、课堂计数变量。
- 聊天订阅、发送和历史查询。
- 白板页面写入与读回、页面复制、样式写入与查询、游标广播。
- RichText 全文更新（9009）和读取（9006）。
- `saveRoomData_Request` 元数据、服务端时间和心跳保持。连接持续超过两个服务端心跳周期。
- 带非空 token 的成功登录，以及错误非空 token 被拒绝且不会回退到未验证登录。

投票消息不在客户端的 `pb/index.web.js` 导出表中，因此使用仓库冻结的 v1 Protobuf schema 和相同外层帧格式验证创建、提交和查询。

## MySQL 事件恢复

在隔离的本地 MySQL 测试库中保留完整 `room_events`，将 `room_snapshots.sequence_no` 回退到 `0`、快照设为空对象，再让 Room Actor 重新启动。原协议客户端确认房间变量、扩展变量、白板页面和样式、RichText 文档及 `saveRoomData` 元数据可读；投票协议客户端确认投票选项和结果可读。

RichText 端到端验证发现并修复了 `string.gsub` 多返回值导致序列化失败的问题，修复位于 `domain/richtext_compat.lua`。

## 未覆盖范围

- TCP v1 帧的空 token 登录和 `updateVar` 往返已通过手写最小客户端验证；未运行实际原生 TCP 客户端应用。
- 未运行整套课程应用，也未连接真实平台的身份/排课/录制系统。
- 当前原客户端源码没有调用 `subRoomVar_Request`；其实际房间命名规则和字段行为仍需线上样本确认。
- `volumestatistics` 在旧服务端中没有实际保存逻辑，本实现保持兼容接收，不作为课堂功能验收项。

## 2026-10-22 后续实现状态

在上述历史联调后追加了 Room 命令角色检查、聊天频道授权、token 频道授权表和独立管理 API。这些后续变更已经通过 macOS make 构建和 Lua 语法检查，但尚未重新进行客户端联调；不得把前面的历史记录当成本次改动的验证结果。

Room Family 的根到子同步、房间映射和管理回放导出是在早期历史联调之后加入的。本轮用两个 v1 WebSocket 会话验证了根快照进入子房间、根变量实时传播、`subRoomVar_Request` 查询和子房间本地变量隔离；房间名为合成值，当时尚未用真实课堂样本确认命名映射或运行 Family Coordinator/Room Actor 重启恢复；重启与落后快照补同步的后续证据见本文件末尾。此后修复的回放起始序号读取、聊天回放条件、多频道聊天事务、关闭房间命令门禁、压缩解码上限、子房间查询授权、Actor 恢复后的在线状态重同步和 Provider 插口没有全部做运行联调。录制资料 Provider 插口尚未连接真实外部服务。

本轮新增房间在线统计管理查询与课程结束时间管理：旧版每 5 秒累计在线/上课时长、首次进入及进出历史；新 API 允许查看摘要或历史，并将结束时间作为 MySQL 房间事件保存。`is_k12=1` 时，Room Actor 会在结束时间加配置宽限期后踢出在线会话；Actor 恢复后的登录路径也会检查已过期时间。

后续在隔离环境完成了运行核验：使用 Skynet v1.8.0、独立 MySQL 8.4.10 临时库和只绑定 `127.0.0.1` 的服务端口，没有访问或修改本机现有 MySQL 库。用 v1 二进制 WebSocket 帧验证了空 token 登录、`updateVar` 往返；管理 API 无 token 返回 401、有效 Bearer token 返回 200；`/room/online` 返回在线时长和进出历史，`POST /room/end-time` 写入后可从 `/room` 读取结束时间。另一次短联调让客户端保持连接到排定时间，确认收到 `kickOut` 后 WebSocket 正常关闭（验证配置将宽限期缩短至 0 秒）。双会话联调还覆盖了根/子房间共享变量、子房间查询和本地变量隔离。另用 TCP v1 帧验证了空 token 登录和变量往返；尚未运行实际原生 TCP 客户端应用。

事件恢复核验保留 `room_events`，将隔离库中 `r_audit` 的快照序号回退到 0 并重启 Skynet。新 Room Actor 重放到序号 2，恢复了变量和结束时间；已过期课程的兼容登录收到错误响应。Skynet/zlib `make` 构建、项目 Lua 语法解析、Python 工具语法解析及 `git diff --check` 均通过。该轮没有覆盖完整课程应用、TCP 客户端、Family Coordinator/Room Actor 重启恢复、真实 token 授权或外部 Provider；原客户端历史联调的范围仍以本文件前文为准。

## 旧入口源码覆盖审计

对旧 `agent_handler.lua` 中 27 个入站消息名与新 `service/session.lua` 的 dispatch 分支做了静态集合对照，未发现缺少入口。`volumestatistics` 仍按旧服务实际行为作为 no-op 接收。旧 simpleweb 的房间查询、成员查询、变量读取/写入、事件、停止房间、在线统计及结束时间操作，分别由新管理 API 的 `/rooms`、`/room`、`GET/POST /room/var`、`/room/event`、`/room/close`、`/room/online` 和 `/room/end-time` 覆盖；这是功能映射，不承诺旧 HTTP 路径兼容。此项是源码静态审计，不能替代每个消息的客户端运行联调。

## 2026-10-22 登录替换审查

Room Directory 在替换同一身份的旧连接前，会先确认目标 Room 已恢复、未关闭且未超过 K12 课程结束宽限期；Room Actor 在实际入房时再次检查这些条件。这样目标房间已关闭或课程已结束时，登录拒绝不会先踢掉该身份当前有效的旧连接。此改动仅做了源码审查，本轮未重新运行客户端或 MySQL 联调。

## 2026-10-22 聊天串行与回放审查

Chat Service 现在用 Skynet 有序队列串行处理订阅、发送、历史读取和注销；它之前在等待 MySQL 时允许其他 Chat 命令插入。调度器也会保留命令的全部返回值，使 `chatSend_Request.saveToReplay` 能收到过滤后的正文和已授权频道并写入房间事件。此改动仅做了源码审查，本轮未重新运行聊天或回放联调。

## 2026-10-22 课堂事件边界审查

对照旧 `EVENT_DEFINE.lua` 后将 RichText 区间上界改为 9099（不包含），使事件 9099 按普通课堂事件持久化和传播。此前新代码将其误归为 RichText 并忽略。本改动只做了源码审查，本轮未发送事件 9099 做客户端联调。

## 2026-10-22 启动依赖审查

主服务现在在创建 TCP/WebSocket 监听器之前调用 Store 初始化，确认 MySQL 可连接且所需表可用；失败时启动报错。此前数据库问题只会在第一次房间操作时暴露。此改动只做了源码审查，本轮未通过停库场景验证启动失败路径。

## 2026-10-22 聊天历史计数审查

`chatHistory_Request.count` 现在接受 0 并返回空记录，保持旧 Chat Service 对零计数的行为；其余请求仍默认最多返回 500 条。本改动仅做了源码审查，本轮未重新联调 count=0 的客户端行为。

## 2026-10-22 子房间 Actor 创建审查

子房间查询现在只路由到已注册 Room，或恢复 MySQL 中已有快照的 Room；未知且无状态的子房间返回空值，不会因未验证客户端任意指定 ID 而创建 Actor。数据库查询失败时请求不会创建房间。本改动仅做了源码审查，本轮未运行子房间查询联调。

## 2026-10-22 v1 schema 冻结核对

将 `compat/v1/proto/` 下六个 `.proto` 文件与旧仓库 `proto/` 下同名原始文件逐一执行文本 diff，六个文件均无差异；字段编号、类型、required/optional/repeated 声明和消息定义保持原样。该项证明 schema 文件一致，不替代全部客户端消息的运行联调。

## 2026-10-22 旧平台接口契约审查与 TLS 接入（源码审查）

对照旧仓库的 viaService.lua、gameplay/room.lua、etc/config.k12 和 etc/config.live，确认了认证 API 的 Bearer token、POST app 字段、status/beginAt 响应，以及录制资料 API 的 GET 路径、Bearer token 和响应 id 检查。新项目加入了固定 HTTPS 配置下的录制资料适配器。旧 via API 的响应不包含身份和角色，因此新登录仍只信任本地 token 表。saveRoomData_Request.data.api 仍被忽略。Provider HTTP 层限制响应大小和读取时间，并且不记录 token。另为 Skynet v1.8.0 构建接入 OpenSSL TLS，并在上游 ltls 客户端补上 CA 链、主机名与 TLS 版本验证。Provider、TLS 和 Makefile 变更最初只完成源码审查，后续 macOS `make` 已成功编译 zlib 与 TLS 模块；仍未完成 Provider 的真实外部服务联调。

## 2026-10-22 光标回放采样

旧服务端从 Room Actor 启动时写入临时回放流，saveRoomData 后决定是否保留。新服务端也从 Room Actor 创建时持续收集持久化房间事件、客户端标记 saveToReplay 的聊天及光标采样；replayMode 控制回放读取是否开放。光标默认每 250 毫秒最多提交一条批次事件，每位成员每批只保留最新位置；普通实时广播仍逐条进行。Room Actor 恢复时会顺序消费这些无状态回放事件。该变更完成源码审查；本轮 `make` 在 macOS 成功：Skynet 核心目标已是最新，zlib 和 OpenSSL TLS 模块重新编译。随后将管理回放查询改为直接读取 MySQL 快照和事件表，因此不再依赖活动 Room Actor。房间事件、快照现带 schema_version，旧表启动时自动补列，并提供 sql/004 手工迁移；Room Actor 遇到未知版本会拒绝恢复。新增的有界串行锁将会员/权限/房间关闭检查移入 Room 队列临界区，避免命令排队期间依据旧成员状态放行。Room、Directory、Chat、Store 的 outstanding 数现有上限，客户端 Room/Chat 队列饱和时连接关闭。相关分支完成 Lua 5.4.7 语法检查与源码审查，尚未通过运行联调验证迁移、Actor 空闲回收读取、光标批次、过载拒绝和失败重试。本轮检查时 127.0.0.1:3306 没有 MySQL 服务，因此没有连接或改动任何本机数据库。

## 2026-10-23 启动与旧表自动升级核验

启动检查发现 `etc/config.lua` 将 `ltls.so` 作为无模块占位符放在 `lua_cpath` 首位，导致 Lua 把它当作 `skynet.core` 加载并在数据库初始化前退出。配置现已改为标准 `luaclib/?.so` 搜索模板；Skynet v1.8.0 随后正常加载核心和 TLS holder，Store 完成初始化并启动 loopback TCP 监听。

为验证旧表自动升级，检查只使用 `/private/tmp` 下新建的 MySQL 8.4.10 临时数据目录、独立库 `jiuqu_redesign_smoke` 和临时账号，服务端口只绑定 `127.0.0.1:18801`，WebSocket 与管理端口关闭。启动前先创建不含 `schema_version` 的旧版 `room_events` 与 `room_snapshots` 表；启动后 `information_schema` 确认两个表都已增加 `SMALLINT UNSIGNED NOT NULL DEFAULT 1` 列，Store 所需的六张表均已创建，TCP 监听接受了本机连接。本次没有连接或修改 `127.0.0.1:3306` 上的数据库，也没有在此检查中发送客户端协议消息。

## 2026-10-23 管理变量定向读取

使用独立 MySQL 8.4.10 临时库、只绑定 `127.0.0.1` 的 TCP 端口 18817 和管理端口 19082，通过最小 v1 TCP 帧完成空 token 登录，并观察到 `loginResponse`、`onMemEnterRoom`、`updateVar_Response` 与 `updateExtVar_Response`。随后验证 `GET /room/var` 可读取单个普通变量、通过 `key`/`ext` 别名读取单个扩展变量、省略 key 时返回整类变量，以及缺失 key 返回 `found=false` 和 JSON `null`；无 Bearer token 请求返回 401。此检查使用临时库和临时服务配置，没有触碰本机 3306 数据库或项目配置文件。

## 2026-10-23 回放起点与光标采样

在另一套隔离 MySQL 8.4.10 临时库和 loopback TCP/管理端口上，通过最小 v1 TCP 帧登录，发送 `saveRoomData_Request`（`replayMode=1`）及同一身份的两次光标更新。管理回放 API 从 `start_sequence=1` 返回 `room_metadata` 序号 1 和带 `schema_version=1` 的 `cursor_presence_batch` 序号 2；将验证配置的采样窗口设为 1000 毫秒后，两次更新合并成一批，内容保留最后一次坐标 `(10,20)`。该检查未运行完整课程客户端，使用的数据目录和服务端口均为临时隔离资源。

## 2026-10-23 空闲回收后的回放查询

使用临时配置将 `room_idle_timeout` 设为 2 秒；最小 v1 TCP 会话登录、启用 replayMode、写入一个房间变量后断开。管理 `/rooms` 在 2 秒后显示零活动会话且房间列表为空，证明 Room Actor 已回收；随后 `/room/replay` 仍从 MySQL 返回序号 1 的元数据事件和序号 2 的变量事件。重复查询 `/rooms` 后房间列表仍为空，确认回放读取没有重新创建 Room Actor。

## 2026-10-23 排课结束时间与 roomData 兼容

对照旧 `game_server/gameplay/room.lua` 确认：`saveRoomData_Request` 成功取得排课资料后，`loginResponse.hasRoomData` 反映 `roomData` 是否存在；K12 房间在 `roomData.endAt` 缺失时以 Room 启动时间为基准，宽限 30 分钟后关闭。新实现现将 Provider 的秒级 `endAt` 映射到 `roomData.endAt`，把首次 `saveRoomData_Request` 时的 Room 启动时间写入事件和快照，并在恢复时沿用；Provider 刷新不能覆盖管理员手动设置或清除的结束时间，`hasRoomData` 则由恢复后的 `roomData` 状态计算。

本轮 `make` 构建成功，Skynet 自带 Lua 5.4 编译器解析了 36 个项目 Lua 文件，`git diff --check` 通过。此项完成源码对照和构建检查，尚未连接真实排课 Provider 做运行联调。

## 2026-10-23 白板与投票行为源码对照

继续逐项对照旧 `whiteboard.lua`、`room.lua` 和 `vote.lua` 后，更新了协议命令映射：白板既有节点采用字段 Patch，手绘点追加、简化点替换并清除原手绘点，删除列表移除对应节点；复制不存在的源页会清除目标页；样式按 id 覆盖。投票重复 end/close 仍广播原响应，统计票数按被选择的选项数累计。上述项目已完成新旧源码静态比对；本轮没有发送这些边界场景的客户端消息。

## 2026-10-23 同连接重新登录的 Membership 顺序审查

Session 重新登录现在先完成身份校验、目标 Room 恢复和实际入房；目标拒绝时不先注销当前 Session。Room 接受后，Directory 才移除该 Session 的旧房间 Membership，Session 再替换聊天订阅。新身份若已有其他连接，旧连接也在目标 Room 接受后才收到 kickOut。登录切换期间发生 socket 关闭时，Session 暂缓清理；身份切换成功后清理新身份，失败时清理旧身份，避免留下孤儿 Membership。当时仅完成源码顺序审查；关闭房间拒绝和重新开放后切换房间的运行结果见下一节。过期课程时的同连接重新登录仍未做运行验证。

## 2026-10-23 同连接重新登录运行核验

使用 Skynet v1.8.0、MySQL 8.4.10 和一次性 v1 TCP 客户端，在独立 MySQL 临时数据目录、临时配置及仅绑定 `127.0.0.1` 的端口上验证。客户端首个登录显式发送空 `accessToken`，进入 `r_probe_a`；管理 API 关闭 `r_probe_b` 后，同一 TCP 连接再次登录目标房间，收到 `loginResponse.error=1`。该连接随后仍能收到 `r_probe_a` 的 `updateVar_Response`，并且管理查询确认原用户仍在 `r_probe_a`、变量已写入。重新开放 `r_probe_b` 后，该连接再次登录成功，管理查询确认用户已进入 `r_probe_b`，并已从 `r_probe_a` 移除。结束后关闭并删除本次专用 MySQL 数据目录和临时配置。此次仅验证最小 TCP 协议探针，没有运行原生 TCP 客户端应用。


## 2026-10-23 管理关房状态持久化实现

修复管理 `/room/close` 只在 Directory 内存生效的问题：Store 自动创建 `room_lifecycle` 表，管理关闭和开放通过 MySQL upsert 持久化；Directory 在新房间登录时读取该状态，持久化关闭的房间在 Actor 创建前即拒绝登录。活动 Room Actor 仍负责踢出在线成员。增加 `sql/005_room_lifecycle.sql` 供已有数据库手动升级。完成源码审查；其后的重启恢复运行结果见下一节。


## 2026-10-23 管理关房重启恢复运行核验

使用 Skynet v1.8.0、MySQL 8.4.10、独立临时数据目录和仅监听 `127.0.0.1` 的 TCP/管理端口。对未活动房间执行 `POST /room/close` 后，直接查询临时库确认 `room_lifecycle.is_closed=1`，且 `/rooms` 未出现该房间，说明管理关闭没有创建 Room Actor。停止并重新启动 Skynet、保留同一临时 MySQL 数据后，用空 `accessToken` 的 v1 TCP 登录得到 `loginResponse.error=1`；管理查询仍未显示 Room Actor。随后执行 `POST /room/open`，同一连接再次登录成功并创建 Room Actor。测试后关闭并删除临时服务数据目录。


## 2026-10-23 录制资料 Provider 本地 HTTPS 联调

使用 Skynet v1.8.0、MySQL 8.4.10、一次性 CA/服务端证书、本地 HTTPS 假 Provider 及只绑定 `127.0.0.1` 的 TCP/管理端口。客户端以空 `accessToken`、legacy 教师角色登录 `r_123`，发送 `saveRoomData_Request`，其中 `data.api` 指向客户端指定的路径。假服务实际仅收到配置的 `GET /schedule-api/t/rooms/123` 和 `Authorization: Bearer local-provider-token`；匹配的响应 `id=123`、`endAt=2000000000` 出现在管理 API `roomData` 中，并直接从 MySQL 快照确认已持久化。

对 `r_124`，假服务返回错误 `id=999`，管理 API 仍显示 `hasRoomData=false` 且无 Provider metadata。另启动只信任另一 CA 的 Skynet 实例，请求在 TLS 阶段失败；假服务没有收到该请求，房间资料也未改变。验证后关闭并删除临时 CA、证书、数据库、配置和服务数据。该联调覆盖本地 TLS 与 Provider 契约，不代表真实平台服务已验收。


## 2026-10-23 根/子房间进程重启与落后快照恢复

使用 Skynet v1.8.0、MySQL 8.4.10、独立临时库和两条最小 v1 TCP 会话。根房间 `r_family_probe` 写入 `family_shared_probe=from_root` 后，子房间 `r_family_probe:subA` 收到更新；子房间另写入 `child_local_probe=from_child`，根房间没有该变量。MySQL 快照确认根序号 1 保存共享变量，子房间序号 2 同时保存共享变量和本地变量。

停止并重启整个 Skynet 进程后重新登录，根和子房间均恢复原值。为模拟 Family 广播丢失，又在临时库将子房间快照回退：移除共享变量、设 `family_sequence=0`、清空 `family_synced_vars`，保留子房间本地变量。再次重启并首次登录子房间后，Directory 从根房间快照补同步；管理查询确认子房间恢复根变量、保留本地变量，MySQL 中子房间序号由 2 增至 3、`family_sequence` 恢复为 1。测试使用合成房间名，验证了状态恢复机制，未确认真实课堂的 subRoom 命名规则。临时数据库、端口和服务目录均已清理。


## 2026-10-23 本地 accessToken 身份与角色授权联调

使用 `tools/provision_access_token.py`、隔离 MySQL 8.4.10 和临时 `AUTH_TOKEN_PEPPER` 生成学生与教师凭证，通过最小 v1 TCP 客户端验证。学生凭证记录 `is_master=0`，客户端登录却提交 `isMaster=true`；登录成功，但 `createVote_Request` 被 Room 权限层拒绝且投票数保持 0。教师凭证记录 `is_master=1`，客户端提交 `isMaster=false`；登录成功并创建投票。学生随后仍能提交该投票，说明凭证角色决定教师命令权限，同时保留学生投票能力。

另确认 token 身份与客户端 id 不匹配、随机无效 token、`expires_at=1` 的过期 token 和已设置 `revoked_at` 的 token 均返回 `loginResponse.error=1`。Provisioning 工具从 stdin 读取测试 token；SQL、token、临时数据库和端口在验证后均已删除。真实身份平台到本地凭证表的签发/同步仍未联调。


## 2026-10-23 活动房间管理关闭与重新开放

使用 Skynet v1.8.0、独立 MySQL 8.4.10 和仅绑定 `127.0.0.1` 的 TCP/管理端口。最小 v1 TCP 客户端以空 `accessToken` 登录 `r_active_close_probe`，收到 `loginResponse` 后调用 `POST /room/close`。同一连接先收到 `onMemEnterRoom`，随后收到 `kickOut`，服务端关闭 TCP；管理 `/rooms` 显示 `active_sessions=0`。再调用 `POST /room/open`，该身份新建 TCP 连接并成功收到登录响应。该结果补齐活动房间踢出路径；测试只覆盖最小协议客户端，未运行原生客户端应用。测试后停止隔离 Skynet/MySQL 进程并删除专用临时数据目录。


## 2026-10-23 本地 token 会话到期处理

修复本地 token 的会话生命周期：凭证查询现在返回 `expires_at`，Session 在登录成功后按 Unix 秒级到期时间安排 `kickOut` 和连接关闭；同一 Session 成功重新登录时会使旧到期计时失效，未设置过期时间的凭证不安排踢出。到期时间较远时以一天为上限分段检查，避免计时器溢出。随后用 Skynet v1.8.0、隔离 MySQL 8.4.10 和最小 v1 TCP 客户端验证了活跃会话：短期 token 登录成功，约 30 秒到期后收到 `kickOut`，TCP 连接关闭，管理 `/rooms` 显示 `active_sessions=0`，服务日志记录 `access token expired`。临时数据库、端口和目录已清理。

## 2026-10-23 v1 schema 与入站消息覆盖静态审计

将新仓库 `compat/v1/proto/` 的 6 个 `.proto` 文件与旧仓库 `proto/` 按字节比较，内容全部一致。再从旧 `agent_handler.lua` 提取 27 个入站消息名，与新 `service/session.lua` 路由逐项核对，未发现遗漏；`volumestatistics` 仍只执行旧服务器实际存在的 no-op 行为。该静态审计证明 schema 文件未漂移、入口名称齐全，不替代所有消息语义和原生客户端的逐项验收。

## 2026-10-23 Skynet v1.8.0 补丁可重复构建

确认 `third_party/skynet` 的 HEAD 为锁定标签 `v1.8.0`、提交 `ba64be6f9fa044933c77de1317f466afbade8eaa`。将客户端 TLS 证书链、主机名、IPv4 字面地址和 TLS 1.2 校验等 4 个上游文件改动保存为仓库内 `patches/skynet-v1.8.0-tls.patch`；Makefile 的 `patch-skynet` 会检查基线提交，并在补丁尚未应用时应用它。先把这 4 个文件恢复到上游基线，再执行 `make patch-skynet`，得到的 Skynet diff 与仓库补丁逐字节一致；随后 `make` 构建成功。由此干净子模块可按仓库脚本恢复所需补丁。

## 2026-10-23 管理指标接口隔离运行核验

`make -j4` 构建成功，Skynet Lua 5.4 运行时用 `loadfile` 解析了 37 个项目 Lua 文件。随后使用 Skynet v1.8.0、MySQL 8.4.10、一次性数据库目录和仅绑定本机的临时 TCP/管理端口启动完整服务。无 Bearer 凭证请求 `GET /metrics` 返回 401；携带临时凭证后返回连接、登录、命令延迟直方图、MySQL 提交、房间恢复和 Directory/Room/Chat/Store 队列数据。空房间队列列表经跨 Actor 返回后仍编码为 JSON 数组。真实 TCP 连接建立及关闭分别使 active connections 从 0 变为 1 再回到 0，opened/closed 计数各增加 1；通过管理关闭房间触发的 MySQL 写入也增加了提交延迟计数。另用独立 Skynet smoke 直接调用 Metrics Actor，确认数据库提交/恢复失败数、持久化写失败数和命令延迟累计正确，慢命令日志会清理 room_id 控制字符且只输出 subject HMAC 脱敏值。烟测后停止进程并删除临时数据库、配置和日志目录。完整管理接口烟测没有发送登录或课堂命令，因此没有覆盖真实 Session 产生的客户端命令延迟。

## 2026-10-23 子房间查询路由核对与持久房间恢复

先前的说明把旧路径概括为 `subRoom` 与实际 room id 精确比较，表述过强。旧 `live.lua` 仅在根房间发布查询；子房间端的过滤条件写成 `subRoom == 0` 或 `subRoom == roomid`，但 v1 请求字段为 `int32`、登录 room id 为 Protobuf `bytes`，非零整数没有可靠的字符串 ID 映射，且 `live.registerLiveCMDHandler` 当前为空、旧响应回调的参数也不匹配。因此这些源码只能显示旧路由意图，不能证明一个可工作的非零查询规则。新 Directory 现也只接受根房间成员发起查询；这是源码审查，未做新的客户端联调。

Room Family 先前仅从活动 Actor 中按别名解析；没有活动 Actor 时只检查合成的 `rootRoom:subRoom` 持久化房间。现 Directory 会按 `subRoom`、`r_<subRoom>`、`rootRoom:subRoom` 顺序检查已有快照，再创建并恢复匹配的子房间。随后以 Skynet v1.8.0、隔离 MySQL 8.4.10 和 fake Session Actor 运行真实 Store、Directory、Room Actor：创建 `r_parent_probe` 根房间及实际 ID 为 `r_actual_child_probe` 的子房间，在子房间写入仅本地保存的 `route_probe`，离房并等待两个 Actor 回收，再由根房间按字符串 ID 查询。新服务从该 ID 的 MySQL 快照恢复子房间，响应值为 `from_exact_child`，证明 Directory 服务级字符串路由能恢复正确快照；这不是 v1 `int32 subRoom` wire 兼容验证。测试使用合成房间名，真实课堂数值映射和零值行为仍需客户端样本确认；临时数据库和端口已清理。

## 2026-10-23 v1 Protobuf 扩展与启动校验

扩展协议文档说明原始 `.proto` 的维护步骤、消息路由位置和当前 Lua codec 支持范围。codec 现在会拒绝 `enum`、`map`、`oneof`、`group` 等未支持声明，不再静默忽略；主服务启动时先解析全部 v1 schema，错误时不会启动监听器。隔离 Skynet Lua 5.4 smoke 解析了 37 个项目 Lua 文件，成功加载当前六个 schema、编解码并往返一个带空 accessToken 的 `loginRequest`，并确认带 `oneof` 或 proto3 声明的临时 schema 明确报错。该检查未连接 MySQL，也未修改冻结 v1 schema 文件。

## 2026-10-23 Session 断线清理审查

源码审查发现 Listener 为每条连接创建 Session Actor，但连接关闭后 Actor 没有退出；此外 Directory 原先会在 Room 接受退出前清除在线索引，Room 队列过载时可能留下幽灵成员。现在断线清理会在队列满或命令异常时重试，Directory 保留索引直到 Room 确认退出；Room Actor 已退出时则直接清除索引。Room 给每次成员登录分配进程内代次，切房或单点登录的延迟退出按旧代次匹配，不会误删同一 Session 后续重新加入的成员。Session 完成房间与聊天注销后安排自身退出。本项通过 Skynet v1.8.0 的 Lua 5.4 编译器语法检查和 `make -j4` 构建。

随后使用隔离 MySQL 8.4.10、仅监听 `127.0.0.1` 的临时 TCP/管理/debug 端口和两个最小 v1 TCP 客户端做运行核验。先让同一身份在第一条连接登录，再从第二条连接登录替换它；Skynet 服务列表中的 Session Actor 数量稳定为 1，Room `member_count` 为 1。关闭新连接后，Session Actor 数量回到 0，Room `member_count` 也回到 0。测试使用空 `accessToken`，结束后停止进程并删除临时配置与数据库目录。该核验覆盖正常断线和同身份替换；未注入 Room 队列过载来验证重试分支。

## 2026-10-23 协议长度校验、聊天缓存和子房间 wire 类型审查

Protobuf 解码器现在拒绝超出 64 位范围的 varint、负长度或超出消息余量的字段长度、非法字段号、跨越 packed 字段边界的 varint，以及长度不符合 float/double 宽度的 packed 数据。聊天服务释放无人订阅的频道路由，并将数据库故障回退历史缓存限制为最多 1024 个频道、每频道 500 条；Room Directory 不再永久缓存已关闭房间 ID，关闭状态以 MySQL 为准。`subRoomVar_Request.subRoom` 在冻结 schema 中实际为 `int32`，Directory 现将它转成十进制别名再查找。以上变更已完成源码审查；`make -j4` 和 Lua 语法检查通过，未对这些新增边界场景运行客户端联调。旧源码将请求按 `subRoom == 0` 或 `subRoom == roomid` 选出目标，但当前仓库中 handler 注册函数为空；没有客户端调用样本，因此数值到真实子房间 ID 的映射和 `0` 的语义仍未确认。此前以字符串 `r_actual_child_probe` 直接调用 Directory 的服务级探针不代表 v1 帧兼容验证。

## 2026-10-23 房间状态提交异常回滚

Room 状态变更现在把 JSON 序列化和 Store 提交一起纳入错误处理：序列化异常会恢复提交前内存快照；数据库提交失败会重新加载持久状态，恢复失败时退回提交前快照，并重建 RichText manager。本项完成源码审查；Skynet v1.8.0 构建、全部项目 Lua/config 语法检查和 `git diff --check` 通过，未注入序列化或数据库故障做运行测试。

## 2026-10-23 Family 持久课堂事件补发（源码审查与构建）

审查发现，Family 的周期快照只能修复变量和 RichText 当前状态，不能补回根房间漏投递的持久课堂事件。现在 Store 可按根房间序号分页读取 `class_event`；实时课堂事件投递、每 5 秒对账和每次子房间登录前都会在已有成员的子房间按独立课堂事件水位补齐缺口。子房间先持久化事件和水位再广播；课堂事件水位与变量/RichText 快照水位分开，避免后到的变量更新或课堂事件掩盖早先缺口。补齐事件后才应用最新状态快照。Coordinator 的实时命令与周期对账共用有界 FIFO 队列，避免新事件越过补发中的旧事件；队列满时会记录错误，后续从 MySQL 继续对账。变量和 RichText 由快照恢复，瞬时光标不补发。子房间没有成员时会推进事件水位，不把此前事件发给后续登录用户；整个 Skynet 进程重启后新建的子房间只同步当前状态，不重放旧课堂事件。

Family outstanding 队列也加入受保护的 `/metrics`，按根房间报告队列长度和上限。本轮 `make -j4`、Skynet Lua 5.4 对全部项目 Lua 文件的语法解析及 `git diff --check` 均通过。未运行带 MySQL 和客户端的漏投递/队列满场景，因此补发与去重路径仍需运行联调确认。

## 2026-10-23 Family Coordinator 中断后的课堂事件补发运行核验

使用 Skynet v1.8.0、MySQL 8.4.10 独立临时数据目录、loopback TCP 13306 和真实 Store/Room/Room Family Actor，创建根房间、子房间及两个 fake Session Actor。子房间有成员时终止 Family Coordinator；根房间仍成功持久化序号 1、2 的课堂事件。重建 Coordinator 并重新注册仍存活的 Room Actors 后，`reconcile_room` 从 MySQL 按序补发两条事件，子房间 Session 收到顺序 `[1101, 1102]`。再次发布序号 2 后仍只有两条；序号 3 的实时事件正常到达。随后让子房间成员离开，根房间持久化序号 4，再执行子房间对账并让另一身份登录；新 Session 未收到旧事件，且子房间事件水位推进到根房间当前序号。

这项核验覆盖了 Coordinator 中断/恢复、持久事件顺序、重复投递去重和空房间历史边界；它通过服务级 fake Session Actor 完成，没有经过 TCP/WebSocket 编解码，也没有注入 Family 命令队列满。临时 Skynet、MySQL、配置、账号与数据目录均已停止并清理。
