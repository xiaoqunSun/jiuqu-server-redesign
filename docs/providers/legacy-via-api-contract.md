# 旧平台 via API 契约

旧仓库的 viaService 使用配置的 viaApi 对非空 accessToken 做课程状态检查，并读取 beginAt。源码契约已核对，但新服务器不调用该接口作为登录凭证来源。

旧接口的请求是 POST，JSON 请求体包含 r_ 前缀之后的房间标识，并以 Bearer token 鉴权；响应以 status = "ok" 表示课程 token 有效，并可返回 beginAt。旧实现还会对包含 _mock 的房间名本地放行。

该接口没有返回用户身份、教师角色、根房间、聊天频道或子房间授权。新服务器要求非空 accessToken 命中 MySQL access_tokens 权威记录，因此不能仅凭该接口的 ok 响应建立新身份。旧 token 只有通过可信授权流程绑定 identity、room、role 和有效期后，才能生成新的本地授权记录。

旧认证契约的源码位置见旧仓库 game_server/viaService.lua、game_server/agent/agent_handler.lua 和 etc/config.k12。新服务器不会把客户端提供的 URL 或 accessToken 转发给此接口。
