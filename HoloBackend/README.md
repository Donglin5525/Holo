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

## 测试

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO/HoloBackend
npm test
```

## 后续实施顺序

1. 买 ECS 后按 [deploy/README-ECS.md](deploy/README-ECS.md) 部署。
2. 把 iOS 的 `HOLO_BACKEND_URL` 从本地地址切到服务器地址。
3. 接真实 App Attest 校验。
4. 把内存限流升级为持久存储。
