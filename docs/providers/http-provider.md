# Provider HTTP 约定

内置旧平台 Provider 通过 Skynet v1.8.0 HTTP 客户端发起服务器端 HTTPS 请求。项目为上游 ltls 客户端补上 CA 链、主机名和 TLS 1.2 以上协议校验；需要 OpenSSL 1.1.1 以上版本，且系统信任根需要在部署环境可用。

- provider_http_timeout_ms 默认为 2000，允许 100 到 30000 毫秒。Skynet 将该值换算为 10 毫秒 tick；连接建立后，响应头和响应体共用一次请求的时间预算。
- provider_http_max_response_bytes 默认为 65536，最大只能设置为 65536 字节。
- 请求地址必须由配置提供，必须是 HTTPS 主机和固定绝对路径；客户端字段不会参与主机或路径构造。
- token 仅作为 Bearer 请求头发送，不记录 token、完整请求或认证头。
- 带 Content-Length 的响应会在读取前检查声明长度；chunked 响应在读取每个数据块前校验大小；其他流式响应在累计字节超过上限时关闭。超时后连接会关闭。

外部服务的 DNS/TLS 可用性由部署环境决定。若 OpenSSL 安装未带可用 CA 根证书，需设置 SSL_CERT_FILE 或 SSL_CERT_DIR。Provider 接口默认关闭，因此未配置外部服务时不会发送 token。
