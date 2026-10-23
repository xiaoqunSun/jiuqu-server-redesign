# 旧协议到新领域命令映射

- 状态：基于旧服务端代码的行为清单，待真实客户端核对
- 日期：2026-10-21
- 来源：旧仓库的 proto/*.proto、agent_handler.lua、agent.lua 和 gameplay/room.lua

这份清单记录旧客户端行为和目标领域映射，不作为代码完成状态清单。当前运行代码及未接入项见 [README](../../README.md)。它不是新领域模型，也不把旧实现中的权限漏洞、偶然错误或基础设施当成必须保留的设计。现有线格式说明见 [客户端协议兼容边界](../protocol-compatibility.md)。

## 连接与房间成员

| 客户端输入 | 旧服务端可见输出 | 新系统内部处理 | 注意事项 |
| --- | --- | --- | --- |
| loginRequest | loginResponse；成功后广播 onMemEnterRoom | 验证身份与房间授权，创建/替换 Session，建立 Membership，返回 RoomView | 有非空 accessToken 时使用验证结果；缺失或为空时按 legacy 兼容路径处理 id、rootRoom、subRoom、isMaster，并标记为未验证；roominfo 现含 vars 和 studentID。目标 Room 接受前不清除当前 Session 的旧 Membership，拒绝的重新登录保留原会话 |
| heartbeat | 服务端每约 3 秒发送 heartbeat；约 30 秒未收到客户端 heartbeat 后关闭连接 | 更新 Session 活跃时间 | 新旧定时参数与旧 `agent.lua` 源码一致；还需实际客户端确认断网场景行为 |
| ping | pong，回送 timestamp | Session 层往返响应 | 不进入房间命令队列 |
| 连接关闭/心跳超时 | 广播 onMemLeaveRoom（当前实现立即退出） | 立即移除 Membership 并广播 onMemLeaveRoom | 沿用旧可见行为；协议没有用于恢复旧 Session 身份的恢复令牌 |
| 服务端踢出 | kickOut | 使旧 Session 失效并关闭 | 保留消息名和空 payload |

## 房间变量与事件

| 客户端输入 | 旧服务端可见输出 | 新系统内部处理 | 注意事项 |
| --- | --- | --- | --- |
| updateVar_Request | updateVar_Response；普通更新广播给房间，onlyToMaster 时发给 master 和发起者 | Set/Delete RoomVariable | var 是 bytes，不假设为 JSON；字符串 null 有删除语义；onlyToMaster 只影响投递范围 |
| updateExtVar_Request | updateExtVar_Response；可全房间或 master 范围 | Set/Merge/Delete ExtendedVariable | varIsTable、isMerge、onlyToMaster 映射到受限内部操作；isBoradcast 字段标记废弃，不能据此授权 |
| queryExtVar_Request | 发起者收到 queryExtVar_Response | 查询扩展变量 | 返回值要保留旧编码方式 |
| addVar_Request | 发起者收到 addVar_Response；当前实现同时广播 updateVar_Response | 原子 Increment，可设置 clampMin/clampMax | 必须在 Room Actor 顺序队列中完成，不能用客户端先读后写 |
| event_Request | event_Response 广播或仅回发给发起者；富文本事件会经专用逻辑处理 | 发布受版本管理的 RoomEvent 或 RichTextCommand | 旧服务端将 `[9000, 9099)` 留给 RichText；9099 及以上按普通课堂事件处理。sender 从认证 Session 得出 |
| updateCursorPosition_Request | updateCursorPosition_Response 广播给房间 | 更新瞬时光标 Presence | sender 由服务端填充；不作为权威房间状态。Room Actor 生命周期内每 250 毫秒按身份合并为一批持久化；saveRoomData 的 replayMode 只控制回放读取是否开放 |
| subRoomVar_Request | 仅根房间成员可发起；由 Room Directory 查询对应子房间并回送实际变量值 | 协议中的 `subRoom` 是 `int32`；新服务把整数转为十进制别名，Room Family 先匹配活动 Actor，再按 `<n>`、`r_<n>`、`rootRoom:<n>` 查找持久化状态并恢复 | 子房间发起的查询按旧 `live.sendCMDtoSub` 行为忽略，避免跨子房间读取；token 用户只能查询凭证授予的子房间；旧源码显示 `subRoom == 0` 会广播，但非零整数与字节串 room id 没有可靠映射，且旧响应回调参数错位，不能据此确认完整可用语义。真实数值映射和 `0` 的产品行为仍需客户端样本；先前精确字符串 ID 探针是 Directory 服务级调用，不是 v1 协议帧验收；字段形状见 room.proto |
| servertime_Request | servertime_Response 回传 client 并附 server 时间 | Session 层读取服务端时钟 | 当前使用秒级时间；新响应不能擅自换精度或字段类型 |
| saveRoomData_Request | 无直接客户端响应 | 提交兼容的课堂/回放元数据提示 | 旧实现接受 data.token 并可使用 data.api 请求外部地址；新实现忽略任意 URL，回放策略来自服务端 |

## 白板与投票

| 客户端输入 | 旧服务端可见输出 | 新系统内部处理 | 注意事项 |
| --- | --- | --- | --- |
| pageUpdate_Request | pageUpdate_Response 广播，含 senderId/pageId/nodes/nodesDeleted | 校验并应用页面节点 Patch | 已按旧白板源码核对：新增节点完整复制；已有节点仅更新请求带来的字段，userPoints 追加、simplifyPoints 替换并清空 userPoints；nodesDeleted 删除节点 |
| pageCopy_Request | pageCopy_Response 广播 | 复制页面状态 | 旧代码对缺失来源执行 deepcopy(nil)，会清除目标页；新实现保持此行为 |
| pageQuery_Request | pageQuery_Response 单播 | 读取页面快照 | 不存在页面按旧实现返回空 nodes 列表；空 repeated 字段按 v1 schema 编码 |
| styleAdd_Request | styleAdd_Response 广播 | 创建/替换样式记录 | 旧逻辑按 style.id 写入，重复 id 会替换已有样式；新实现保持该规则，权限按新角色策略执行 |
| styleQuery_Request | styleQuery_Response 单播 | 读取样式列表 | 旧实现遍历 Lua table，顺序不稳定；新实现按 id 排序，字段与元素保持兼容 |
| createVote_Request | createVote_Response 广播，含新 id/info | 创建投票 | 需要教师角色；客户端 student_count 不能作为权威人数。legacy 教师声明仍来自客户端 isMaster |
| endVote_Request | endVote_Response 广播 | Active -> Ended | 按旧 `vote.lua` 状态规则更新；重复结束仍广播相同响应，教师角色按新授权策略校验 |
| closeVote_Request | closeVote_Response 广播 | Vote -> Closed | 按旧 `vote.lua` 状态规则更新；重复关闭仍广播相同响应，教师角色按新授权策略校验 |
| submitVote_Request | submitVote_Response 单播 | 验证选项并记录一个身份的一次投票 | 当前仅允许每人投一次；total_votes 实际按所选选项数累计，需核对客户端展示是否依赖该语义 |
| queryVote_Request | queryVote_Response 单播 | 查询投票、本人选项或受权限控制的明细 | 学生的 include_detail 会被强制关闭；vote id 0 当前代表最后一项 |

## 聊天与统计

| 客户端输入 | 旧服务端可见输出 | 新系统内部处理 | 注意事项 |
| --- | --- | --- | --- |
| chatListen_Request | 无确认响应 | 按 Session 授权频道订阅 Channel | token 用户使用本地授权表和房间别名；空 token 兼容模式默认保留旧版任意合法频道行为，可配置关闭 |
| chatUnlisten_Request | 无确认响应 | 取消订阅 Channel | 幂等处理 |
| chatSend_Request | 每个频道向订阅者发送 chatRecv_Response | 过滤、限流、写入频道记录并扇出 | 旧实现最大 5000 bytes；过滤开关须检查角色；saveToReplay 服从服务端回放策略 |
| chatHistory_Request | chatHistory_Response，最多取请求数量或默认最近 500 条 | 查询持久化历史并按旧字段编码 | count 为 0 时返回空列表；token 用户按本地频道授权表校验；空 token 默认兼容旧版任意合法频道，count 上限由服务端控制 |
| volumestatistics | 当前 handler 不执行实际保存 | 统计管道或明确弃用 | 虽有 Protobuf 定义，旧入口目前是 no-op；兼容层可接收并忽略或按客户端探查确认 |

## 新领域边界

- 协议适配器维护旧消息名、Protobuf 字段语义和响应选择；领域命令使用自己的类型。
- 旧协议对多数变更没有 requestId、通用错误响应或 eventSeq。新实现不能声称跨断线 exactly-once；协议 v2 可引入去重键和恢复游标。
- 新旧映射不仅要比较编码结果，也要确认登录失败表现、广播范围、响应时机、重复提交、超时及断线重连行为。
- 第一期应将原始 .proto 文件审阅后复制到新仓库自己的 compat/v1 目录，固定字段号并记录来源版本。新项目运行时不能依赖旧仓库路径。
