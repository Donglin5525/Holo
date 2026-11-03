# HoloBackend

Holo AI Gateway 的本地 MVP 骨架。第一阶段目标是让 iOS App 只调用自己的后端，由后端统一转发到 DeepSeek、Qwen、Moonshot、智谱和 DashScope，避免模型 API Key 暴露在客户端。

## 当前已实现

- `GET /v1/health`
- `POST /v1/ai/chat/completions`
  - `stream: false` 返回 JSON
  - `stream: true` 返回 SSE
  - 拒绝客户端传入 `baseURL`、`provider`、`model`、`apiKey`
- `POST /v1/app-attest/challenge`
- `POST /v1/app-attest/assert`
  - 当前只有开发环境 debug 占位
  - 生产 App Attest 校验还未接入
- `POST /v1/asr/transcriptions`
  - 本地默认返回 mock transcript
  - `HOLO_ASR_PROVIDER=dashscope` 时，后端内部调用 DashScope WebSocket 转写
- `GET /admin/logs`
  - 简单管理网页，用于查看最近 AI 调用详情
  - 必须配置 `HOLO_ADMIN_PASSWORD` 或 `HOLO_ADMIN_TOKEN`
- `GET /admin/prompts`
  - Prompt 管理列表
- `GET/POST /admin/prompts/:type`
  - 查看、编辑、保存或恢复默认 Prompt
- `GET /v1/admin/logs`
  - 管理日志 JSON 列表
- `GET /v1/admin/logs/:id`
  - 单条 AI 调用详情，包含 Prompt、用户输入和模型输出
- 设备级内存限流
- OpenAI-compatible provider 基础转发能力

## 本地启动

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm install
npm run dev
```

默认地址：

```text
http://localhost:8787
```

健康检查：

```bash
curl http://localhost:8787/v1/health
```

非流式聊天 mock：

```bash
curl -X POST http://localhost:8787/v1/ai/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-holo-device-id: local-device' \
  -d '{
    "purpose": "chat",
    "stream": false,
    "messages": [{ "role": "user", "content": "你好" }]
  }'
```

## 配置真实模型

复制 `.env.example` 为 `.env`，填入至少一个 provider 的 API Key，然后把 `HOLO_CHAT_PROVIDER` 改成对应 provider：

```text
HOLO_CHAT_PROVIDER=deepseek
HOLO_CHAT_MODEL=deepseek-chat
DEEPSEEK_API_KEY=真实 Key
```

本地启动会自动读取 `.env` 文件。真实 Key 只放 `.env` 或 ECS 的 `.env.production`，不要提交到 git。

语音识别走 DashScope：

```text
HOLO_ASR_PROVIDER=dashscope
DASHSCOPE_API_KEY=真实 Key
```

## 管理日志

AI 调用详情日志默认关闭。配置账号密码后启用登录页：

```text
HOLO_ADMIN_USERNAME=admin
HOLO_ADMIN_PASSWORD=本地调试用强密码
HOLO_ADMIN_SESSION_SECRET=本地调试用长随机字符串
```

浏览器查看：

```text
http://localhost:8787/admin/logs
```

未登录时会自动跳转到 `/admin/login`。

JSON 接口：

```bash
curl http://localhost:8787/v1/admin/logs \
  -H 'X-Holo-Admin-Token: 本地调试用长随机字符串'
```

如果需要给脚本调试使用，可以额外配置 `HOLO_ADMIN_TOKEN`。网页日常查看建议使用账号密码登录，不建议把 token 放到 URL。

这些日志会包含 Prompt、用户输入和模型输出。本期只保存在后端进程内存中，服务重启后清空，不记录 ASR 音频二进制内容。

Prompt 管理入口：

```text
http://localhost:8787/admin/prompts
```

后台保存的 Prompt 会写入 `src/prompts/managedPrompts.json`，后续 `/v1/prompts/:type` 会优先返回管理后台保存的版本。

## 测试

### 后台成本保护（2026-10-15）

记忆萃取/核验/融合、想法自动整理/关联/类别理解/主题命名摘要共用持久费用台账。
默认每个已验证原始订阅交易每天 0.30 元、每月 2 元；无订阅时按设备。全站每天 3 元、每月 60 元兜底。
预算按北京时间自然日/月刷新，自部署启用时开始记账，不追溯上线前费用。
主动聊天、用户发起的分析/想法洞察、语音、向量和内容审核费用不在此预算内，因此这不是总账单上限。

- 已知 Holo 构建号低于 32 的后台请求返回 426；缺少构建号仍受实际输入和预算检查。
- 请求体及注入系统 Prompt 后的模型输入各限 96 KiB，不静默截断用户数据。
- 每次模型调用前原子预留最大费用，并发不能各自重复使用同一余额。结束后按 usage 结算；无 usage、超时和崩溃保留预留。
- 预算费率默认输入/输出/缓存每百万 token 3/9/0.1 元，是保守内部计价；更换模型时必须核对 `HOLO_BACKGROUND_*_PRICE`。推理 token 不重复计费。
- 同一类别的无效输出冷却 24 小时，暂时故障冷却 1 小时；更改 operationId 不会解除冷却。真实证据、服务端 Prompt 版本或模型变化后可以重新尝试。
- 预算不足返回 `BACKGROUND_BUDGET_EXCEEDED`（429）及 `error.resetAt`；当前客户端可能仍发 HTTP 重试，但不会因此继续调用大模型。整理可能推迟到次日/次月，已有记录不变。
- 新表仅存哈希主体/证据指纹、日期、用途及费用，不保存笔记正文。费用台账保留 90 天，过期冷却记录启动时清理。

配置项见 `deploy/env.production.example`；没有配置时启用以上安全默认值，非正数配置拒绝启动。
回归测试：`node --test tests/backgroundCostGuard.test.js tests/aiCallLogsUsage.test.js tests/thought-category-brief.test.js`。

### 完整测试

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm test
```

## 后续实施顺序

1. 买 ECS 后按 [deploy/README-ECS.md](deploy/README-ECS.md) 部署。
2. 把 iOS 的 `HOLO_BACKEND_URL` 从本地地址切到服务器地址。
3. 接真实 App Attest 校验。
4. 把内存限流升级为持久存储。
