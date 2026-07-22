# Holo 安全基线

## 身份与滥用控制

生产 AI/ASR 应只接受后端签发的短期 app-instance session。客户端自报的 device ID 不能作为可信身份或独立配额依据。App Attest 校验包括一次性 challenge、证书链、app ID、环境、nonce、签名与单调计数器。

正式启用强制校验前必须配置 Team ID、Bundle ID、环境和可信根证书，并完成 Debug、TestFlight、Release 真机灰度。缺少任一生产配置时后端应拒绝启动。

## 数据与日志

- 请求/响应正文默认不进入热缓存；健康、财务、记忆等敏感 purpose 即使开启诊断也不保留正文。
- 管理入口使用独立强密钥、Secure Cookie 和失败限流；公网部署还应叠加反向代理访问控制。
- AI、ASR、CSV 和 JSON 请求均有体积、条数、字符数或 token 上限。
- 密钥、生产 `.env`、SQLite 和备份文件不入库；同步部署必须保护 `deploy/.env.production*` 与数据目录。

## 漏洞报告

请将安全问题私下发送至 `support@holoapp.cn`，包含影响、复现条件和建议修复方式，不要在公开 Issue 中附真实用户数据或凭据。
