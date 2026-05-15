# Holo 管理后端方案

## 结论

本期不新建独立 GitHub 仓库，也不新起独立服务。Holo 管理后端先内嵌在现有 `HoloBackend` 项目中，通过独立目录 `src/admin/` 承载管理能力。

这样可以复用现有后端部署、环境变量、AI Provider、Prompt 托管和后续用户上下文能力，同时避免过早引入多服务认证、跨服务日志同步、独立发布流水线等复杂度。

## 当前边界

管理后端当前属于 HoloBackend 的内部运维能力，不面向普通 App 用户开放。

当前模块位置：

```text
HoloBackend
├── src
│   ├── app.js
│   ├── prompts/
│   └── admin/
│       ├── adminAuth.js
│       ├── adminLogStore.js
│       ├── adminLogsPage.js
│       └── adminRoutes.js
```

## 本期目标

本期先实现 AI 调用详情日志，用于验证 Prompt 后端托管和模型调用链路是否按预期工作。

提供两个入口：

- `GET /admin/logs`：简单网页，方便在浏览器查看最近 AI 调用。
- `GET /v1/admin/logs`：JSON 接口，方便调试或后续接正式管理前端。
- `GET /admin/prompts`：Prompt 管理列表。
- `GET/POST /admin/prompts/:type`：查看、编辑、保存或恢复默认 Prompt。

## 安全边界

AI 调用详情日志会包含敏感信息，包括 system prompt、用户输入和模型输出。因此本期必须遵守以下约束：

- 必须配置 `HOLO_ADMIN_TOKEN` 后管理入口才可用。
- 管理网页通过 `/admin/login` 账号密码登录，登录成功后使用 HttpOnly Cookie 维持会话。
- 管理 JSON 接口仍支持 `X-Holo-Admin-Token`，用于脚本调试和自动化检查。
- 日志默认只保存在内存里，不落盘，不持久化。
- 日志数量和单条详情长度必须有上限，避免长期保存敏感内容。
- ASR 音频二进制内容不进入管理日志。
- HTML 页面展示内容必须转义，避免日志内容触发 XSS。
- Prompt 管理后台只面向内部使用，保存内容会写入后端本地 `src/prompts/managedPrompts.json`。

## 后续扩展

当管理后端继续发展时，可以继续在 `src/admin/` 下扩展：

- Prompt 版本管理
- Prompt 发布记录
- 用户 AI 上下文查看
- 财务科目配置查看
- 周报/月报洞察触发记录
- 用户确认队列

## 何时拆成独立项目

只有当管理后台变成完整运营系统时，再考虑拆成独立项目或独立仓库：

- 需要多人登录和角色权限。
- 需要复杂前端页面、筛选、编辑和发布流程。
- 需要独立域名、独立部署或独立发布节奏。
- 需要数据库审计、操作回滚和长期日志留存。
- 管理后台与 HoloBackend 的生命周期明显分离。

在这些条件出现之前，保留在 `HoloBackend` 内部更简单，也更适合当前阶段。
