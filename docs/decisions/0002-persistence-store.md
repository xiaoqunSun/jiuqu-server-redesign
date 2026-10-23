# ADR 0002：首期持久化存储

- 状态：已采纳
- 日期：2026-10-21

## 决策

首期持久化使用 MySQL/InnoDB。房间事件、状态快照、聊天历史、本地 access token 授权记录和房间生命周期开关使用 MySQL 管理；Skynet Room Actor 是房间内存状态的单写入者，MySQL 保存可恢复的持久化记录。Skynet v1.8.0 自带 MySQL 驱动当前只支持 `mysql_native_password`，部署账号需启用该认证插件。

## 原因

新服务端要从已有客户端行为重新设计，但持久化继续使用 MySQL，减少新项目同时引入数据库平台的成本。InnoDB 事务用于保证聚合事件和顺序号一起提交。房间状态恢复采用带 schema_version 的快照加后续版本化事件重放，聊天历史按频道顺序保存。

Redis 不作为房间状态或事件日志的权威来源。是否用于非权威缓存、过期 Presence 或跨节点消息，由后续容量需求单独决定。

## 影响

- MySQL schema、事务延迟、连接池和恢复过程成为首期设计与容量评估的一部分。`room_lifecycle` 单独保存管理关闭状态，不混入客户端可写入的房间事件流。
- token 原文不持久化；服务端以 AUTH_TOKEN_PEPPER 计算 HMAC-SHA1 摘要，本地凭证记录绑定 identity、room、root room、role、beginAt、expiry 和 revoke 时间。非空 accessToken 必须匹配本地权威记录；旧 via API 只返回课程状态和 beginAt，不能作为身份/角色凭证来源。
- Room Actor 在内存中计算新状态，MySQL 单事务写入事件和对应快照；事务确认成功后才广播。失败时重新读取数据库权威状态，不广播未提交变更。Actor 启动时恢复最新快照并按连续序号重放后续事件。
- COMMIT 响应丢失时，Store 重连后核对提交序号和快照，避免把已经提交的变更误判为失败。
- 主服务在开放 TCP/WebSocket 监听前连接 MySQL 并确认所需表可用；连接、认证或建表失败时拒绝启动，避免出现可连接但不能持久化的半可用实例。
- 新数据库在 sql/001 中创建基础表；已有数据库可执行 sql/002 到 sql/006 的增量脚本，运行时也会自动补建缺少的表和 `schema_version` 列，并将历史聊天 `TEXT` 列转换为 `BLOB`。自动迁移要求应用账号具备 ALTER 权限；已由运行时升级后无需重复执行对应脚本。旧记录以 schema_version=1 的 UTF-8 JSON 读取，新写入的快照和事件使用 schema_version=2；v2 对非 UTF-8 字节及对象键使用可逆 `\udcXX` 转义。遇到未知版本、非法转义或损坏数据时 Room Actor 会拒绝恢复而不会猜测解码。
- 上线前需确认 MySQL 目标版本、备份与恢复策略、事件/聊天保留时间，并验证所选 Lua MySQL 客户端和事务行为。
