# 架构方向

当前总体方案与运行时边界见 [实时服务端总体设计 v0.1](design/server-architecture.md)。单节点核心实现已落地；产品权限、持久性目标及容量仍需确认，外部身份和排课系统的联调也未完成。

新旧服务器在运行模型、身份认证、房间状态、持久化和回放方面的异同，见[新旧服务器设计对照](design/old-server-comparison.md)。该对照分别标明旧源码现状、新设计目标和当前实现状态。

## 当前核心决策

- 新系统按业务需求重新建模，不继承旧服务端内部模块结构。
- 首期以单个 Skynet 应用构成模块化单体，不先引入 Redis Pub/Sub 或微服务集群。
- 每个房间由一个 Room Actor 独占状态写入和房间内顺序；根 Room Actor 持有家族共享状态，Family Coordinator 维护路由和恢复。
- TCP/WebSocket 与 Protobuf 只位于协议适配器，领域命令和事件不依赖旧协议类型。
- Session、Identity、Membership 和 Role 分开建模；持 token 连接使用本地授权记录；无 token 旧客户端保留 legacy 权限解释并明确标记。
- MySQL/InnoDB 作为首期持久化基线，使用版本化聚合事件和快照恢复状态；最终依赖现有部署约束确认。

## 尚未定案

无 token 兼容路径的隔离方式、子房间真实命名与成员范围、各类数据的 RPO/保留期及容量目标
