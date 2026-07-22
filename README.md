# Holo

Holo 是一款以个人数据资产为基础的 iOS AI 助理。它把记账、待办、习惯、想法、健康与记忆放进同一套用户可控的上下文中，用于记录、复盘和规划。

## 仓库结构

- `Holo/Holo APP/Holo/`：SwiftUI iOS App、Core Data、HealthKit、CloudKit、Widget 与本地 Agent。
- `HoloBackend/`：Hono + Node.js 后端网关，负责 AI/ASR 代理、Prompt、身份、限流与运维接口。
- `src/`：`holoapp.cn` 官网和独立隐私、协议、支持、删除、导出页面。
- `docs/`：产品、架构、上架和实施方案。
- `scripts/`：测试清单、standalone runner 与 Xcode Target 同步工具。

## 本地验证

```bash
npm test
npm run lint
npm run build
npm test --prefix HoloBackend
ruby scripts/check-test-inventory.rb
ruby scripts/run-standalone-tests.rb
```

iOS XCTest 需要本机可用的 iOS Simulator runtime；测试清单脚本负责防止新增测试遗漏 Target 或 runner。

## 生产边界

- iOS 和官网生产 API 使用 `https://api.holoapp.cn`，不直连大模型。
- 后端代码、Prompt、Docker 或配置变更必须重新发布 ECS，并通过 `/v1/live`、`/v1/ready`、`/v1/release/status` 和真实业务请求验收。
- Prompt 改动必须同步 iOS fallback 与后端默认模板，并提升版本号。
- 生产密钥、SQLite 数据、部署备份和签名材料不得提交到仓库。

进一步阅读：[架构](ARCHITECTURE.md)、[安全](SECURITY.md)、[运行手册](RUNBOOK.md)、[测试](TESTING.md)、[数据与隐私](DATA-PRIVACY.md)。
