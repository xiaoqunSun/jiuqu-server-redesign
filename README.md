# Jiuqu Realtime Server

一个从产品需求重新设计的实时协作服务端。新项目不沿用旧服务器的模块划分或内部数据模型。

## 当前方向

- 以房间为实时状态和顺序一致性的边界。
- 服务端负责身份、角色、成员权限和房间生命周期。
- 客户端协议先通过独立适配层保持兼容；协议不是领域模型，未来可以版本化替换。
- 按数据用途定义持久性和恢复行为，回放来自规范化的房间事件。
- 初期采用模块化 Skynet 服务，按房间扩展；基础设施随规模需求增加。

## 项目状态

目前处于设计与运行时基线建立阶段，尚无业务实现。需求假设、架构草案、协议边界和 Skynet 基线分别记录在 `docs/`。

## 文档

- [需求假设](docs/requirements.md)
- [架构草案](docs/architecture.md)
- [客户端协议兼容边界](docs/protocol-compatibility.md)
- [Skynet 基线决策](docs/decisions/0001-skynet-baseline.md)
