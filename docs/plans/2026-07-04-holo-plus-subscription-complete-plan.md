# Holo Plus 订阅商业化完整方案

**Goal:** 将 Holo 第一版商业化落成「免费版 + Holo Plus」两档，通过 StoreKit 订阅、每日次数限额、ASR 时长限制和后端 quota ledger 控制成本。

**Architecture:** 免费版保留完整基础记录能力，Plus 解锁效率增强与 AI 能力。客户端负责权益展示、付费弹窗、StoreKit 购买与恢复；后端负责订阅权益校验、quota 计数、限流、ASR 时长限制和成本埋点。

**Tech Stack:** iOS / SwiftUI / StoreKit 2、HoloBackend Node.js、SQLite quota ledger、DeepSeek V4 Flash、DashScope ASR、Apple In-App Purchase。

---

## 1. 最终产品决策

Holo 第一版商业化只做两档：

| 档位 | 定位 | 用户心智 |
|---|---|---|
| 免费版 | 完整记录生活 | 我可以放心把财务、任务、想法、习惯、健康记在 Holo |
| Holo Plus | 更好用，也更懂我 | Holo 帮我省事，并提供更高额度 AI 分析与整理 |

明确不做：

| 不做项 | 原因 |
|---|---|
| Pro 档 | 0 真实付费用户阶段，三档会让商业化复杂度过高 |
| 买断 | Plus 包含 AI / ASR 持续成本，买断会制造长期履约风险 |
| 积分包 | 第一版用户心智不清晰，客服与审核复杂度增加 |
| 额外 AI 次数包 | Phase 3 真实数据出来前不加 |

核心原则：

```text
记录不收费。
效率增强收费。
AI 高额度收费。
成本用次数和后端保险丝控制。
```

---

## 2. 定价方案

### 2.1 首发价格

| SKU | 价格 | 角色 |
|---|---:|---|
| Holo Plus 月付 | `¥12/月` | 低门槛入口 |
| Holo Plus 年付早鸟 | `¥98/年` | 首发限时/限量主推 |
| Holo Plus 年付标准 | `¥128/年` | 早鸟结束后的默认年付 |

早鸟边界：

```text
¥98/年：首发 14 天或前 500 名，以先到者为准。
早鸟结束后恢复 ¥128/年标准价。
```

说明：

1. `¥98/年` 是冷启动策略，不作为长期标准价。
2. 后续切到 `¥128/年` 只影响新用户，无法修复已售年付 cohort 的成本问题，所以早鸟必须一开始就限时/限量。
3. 如果 Phase 3 数据显示 AI 成本低、转化差，可以短期延长早鸟，但仍必须明确截止条件。

---

## 3. 权益分层

### 3.1 免费版

免费版必须完整保留基础记录，避免用户产生“生活数据被绑架”的感觉。

| 模块 | 免费版权益 |
|---|---|
| 财务 | 收入、支出、转账、分类、备注、基础汇总 |
| 任务 | 创建任务、截止日期、完成状态、基础列表 |
| 想法 | 记录想法、手动标签、搜索 |
| 习惯 | 创建习惯、打卡、连续天数、基础统计 |
| 健康 | HealthKit 接入、基础数据查看 |
| 记忆 | 基础时间线、基础回看 |
| AI | 少量每日体验 |

### 3.2 Holo Plus

Plus 负责“效率增强 + AI 高额度”。

| 模块 | Plus 权益 |
|---|---|
| 桌面小组件 | 财务、待办、习惯、健康、记忆等组件 |
| 财务增强 | 财务分期、周期账单、订阅扣费提醒、预算进度 |
| 统计增强 | 高级趋势、跨月对比、年度视图、自定义看板 |
| 提醒增强 | 周期提醒、临近提醒、异常提醒 |
| 个性化 | 自定义首页模块、分类展示、工作台布局 |
| AI 聊天 | 更高每日次数 |
| AI 深度分析 | 财务、健康、任务、习惯、想法的跨模块分析 |
| AI 自动整理 | 想法聚类、标签建议、主题沉淀 |
| AI 周报/月报 | 个性化回顾 |
| 生活观察 | 每日一次 AI 观察，识别近期变化 |

重型 Agent 不进入 Phase 1，移到 Phase 2。

---

## 4. 使用限额

### 4.1 用户可见限额

| 能力 | 免费版 | Plus |
|---|---:|---:|
| AI 聊天 / 问答 | `3 次/天` | `30 次/天` |
| 自然语言/语音记账解析 | `20 次/天` | `50 次/天` |
| 自然语言/语音任务解析 | `10 次/天` | `30 次/天` |
| 单次 ASR 时长上限 | `60 秒/次` | `60 秒/次` |
| AI 深度分析 | `1 次/周` | `1 次/天` |
| AI 自动整理想法 | `3 次/周` | `3 次/天` |
| AI 周报 | `1 次/月体验` | `1 次/周` |
| AI 月报 | 预览版 | `1 次/月` |
| 生活观察 | 本地规则版或不开放 | `1 次/天` |
| 重型 Agent | 不开放 | Phase 2：`5 次/月` |

### 4.2 内部限额规则

| 规则 | Phase | 是否展示给用户 |
|---|---|---:|
| 每日次数限制 | Phase 1 | 是 |
| 每分钟请求限制 | Phase 1 | 否 |
| 单次 maxTokens | Phase 1 | 否 |
| ASR 单次 60 秒硬截断 | Phase 1 | 异常时提示 |
| 失败重试上限 | Phase 1 | 否 |
| 月度 token 软/硬上限 | Phase 3 | 仅特殊场景提示 |

关键约定：

1. `intent` 是内部分流调用，不单独消耗用户可见 quota，避免一次对话扣两次。
2. `finance_action_parser`、`task_action_parser` 归入 `naturalLanguageInput` quota。
3. ASR 按秒计费，必须做单次 60 秒硬截断。
4. 每日恢复时间按 `Asia/Shanghai` 切日，不按 UTC。

---

## 5. 成本测算

### 5.1 价格假设

DeepSeek V4 Flash：

| 计费项 | 价格 |
|---|---:|
| 输入 cache miss | `$0.14 / 1M tokens`，约 `¥1.008 / 1M` |
| 输入 cache hit | `$0.0028 / 1M tokens`，约 `¥0.020 / 1M` |
| 输出 | `$0.28 / 1M tokens`，约 `¥2.016 / 1M` |

DashScope ASR：

| 计费项 | 价格 |
|---|---:|
| 实时语音识别 | 约 `¥1.12/小时`，即 `¥0.00031/秒` |

默认测算口径：

| 口径 | input 单价 |
|---|---:|
| 默认 | `¥0.7 / 1M tokens`，假设 30% cache hit |
| 保守 | `¥1.0 / 1M tokens`，假设 cache hit 不稳定 |

### 5.2 单次成本

| 功能 | 调用链 | 单次成本 |
|---|---|---:|
| 文本聊天 | intent + chat | `约 ¥0.003` |
| 语音聊天 10s | ASR + intent + chat | `约 ¥0.006` |
| 深度分析 | intent + insight | `约 ¥0.010` |
| 生活观察 | memory_observer | `约 ¥0.002` |
| 自动整理想法 | thought_org + convergence | `约 ¥0.004` |
| 文本记账 | finance_action_parser | `约 ¥0.0004` |
| 语音记账 10s | ASR + finance_action_parser | `约 ¥0.003` |
| 重型 Agent 单步 | agent_loop ×1 | `约 ¥0.034` |
| 重型 Agent 3 步 | agent_loop ×3 | `约 ¥0.103` |

### 5.3 月成本判断

Phase 1 不含重型 Agent：

| 用户类型 | 估算成本 |
|---|---:|
| 普通 Plus 用户 | `约 ¥2-3/月` |
| 重度 Plus 用户，1x | `约 ¥5.3/月` |
| 重度 Plus 用户，2x 压力测试 | `约 ¥10.6/月` |

Phase 2 含重型 Agent：

| 用户类型 | 估算成本 |
|---|---:|
| 重度 Plus 用户，1x | `约 ¥5.8/月` |
| 重度 Plus 用户，2x 压力测试 | `约 ¥11.6/月` |

产品结论：

1. `¥98/年` 只适合早鸟。
2. `¥128/年` 更适合作为长期标准价。
3. Phase 2 开放 Agent 前，必须看 Phase 3 的真实成本数据。
4. 如果 ASR 被大量使用，成本会上升很快，60 秒硬截断是必要条件。

---

## 6. 付费触发流程

推荐链路：

```text
用户点击 Plus 功能
→ 展示 Holo 自己的价值说明弹窗
→ 用户选择月付或年付
→ 调起 Apple StoreKit 支付确认
→ 支付成功后回到原功能并立即解锁
```

不推荐：

```text
用户点击功能
→ 直接弹 Apple 支付窗口
```

原因：系统支付窗口只负责确认交易，Holo 自己的弹窗负责解释价值。

### 6.1 Paywall 文案

```text
让 Holo 更好用，也更懂你

升级 Holo Plus 后，你可以使用桌面小组件、财务分期、高级统计，
并解锁更多 AI 问答、深度分析、自动整理和生活观察能力。

AI 分析基于你的本地数据生成，结果仅供参考，可能存在误差。
随着模型迭代，部分 AI 能力的表现可能会调整。
```

按钮：

```text
开通 Plus 年付 ¥98
月付 ¥12
暂时不用
```

早鸟结束后按钮改为：

```text
开通 Plus 年付 ¥128
月付 ¥12
暂时不用
```

### 6.2 超限文案

免费 AI 聊天超限：

```text
今天的免费 AI 次数已用完
升级 Holo Plus 后，每天可以使用更多 AI 问答、深度分析和自动整理能力。
```

免费自然语言记账超限：

```text
今天的免费自然语言记账已达上限
你仍可手动选择分类记账，或升级 Plus 获得更高额度的自然语言记账。
```

Plus 深度分析超限：

```text
今天的 AI 深度分析次数已用完
你仍然可以继续记录和查看数据。Plus 的深度分析次数将在明天恢复。
```

ASR 超时：

```text
单次语音最长支持 60 秒
你可以缩短录音，或分成多段记录。
```

---

## 7. Apple 审核与支付要求

Holo Plus 属于 App 内数字功能解锁，应使用 Apple In-App Purchase / StoreKit。

审核准备：

1. App Store Connect 配置 `Holo Plus Monthly` 和 `Holo Plus Yearly`。
2. App 内提供“恢复购买”入口。
3. 付费页、弹窗、App Store 元数据的价格和权益一致。
4. 付费页说明 AI 结果仅供参考，可能存在误差。
5. 审核说明写清免费版可用范围、Plus 权益、AI 次数限制、自然语言记账降级规则。
6. 付费页不暗示 Apple 之外的付款方式。
7. Family Sharing 建议关闭，这是商业成本配置项，不是审核硬要求。

---

## 8. 工程方案

### 8.1 当前后端基础

当前 HoloBackend 已有：

| 能力 | 当前状态 |
|---|---|
| SQLite usage store | 已有 `createSqliteUsageStore(database.db)` |
| rate_limits 表 | 已按 key/count/expires_at 计数 |
| AI purpose route | 已支持 `chat`、`intent`、`insight`、`finance_action_parser` 等 |
| ASR route | 已有 `/v1/asr/transcriptions` |
| App Attest | 目前仍是待完善方向 |

当前缺口：

| 缺口 | 说明 |
|---|---|
| entitlement | 缺 StoreKit receipt 校验后的会员权益记录 |
| quota type | 现有按 purpose 计数，不等于商业权益分类 |
| remaining / resetAt | 429 不能支撑友好超限提示 |
| token 计量 | 需要记录 input/output tokens 供 Phase 3 校准 |
| 时区切日 | 现有按 UTC 切日，中国用户早 8 点恢复次数 |
| ASR 时长 | 需要单次 60 秒硬截断 |

### 8.2 后端数据模型

建议新增或演进：

```text
entitlements:
- user_id
- device_id
- tier: free | plus
- source: storekit
- product_id
- expires_at
- last_verified_at
- created_at
- updated_at
```

```text
quota_ledger:
- id
- user_id or device_id
- tier
- quota_type
- period_type: daily | weekly | monthly
- period_key
- used_count
- input_tokens
- output_tokens
- reset_at
- created_at
- updated_at
```

```text
quota_events:
- id
- user_id or device_id
- quota_type
- purpose
- route
- allowed
- denial_reason
- input_tokens
- output_tokens
- asr_seconds
- created_at
```

### 8.3 Quota Type 映射

| purpose / route | quota_type | 用户是否可见 |
|---|---|---:|
| `chat` | `chat` | 是 |
| `intent` | `internalIntent` | 否，不消耗用户可见次数 |
| `finance_action_parser` | `naturalLanguageInput` | 是 |
| `task_action_parser` | `naturalLanguageInput` | 是 |
| `thought_organization` | `thoughtOrganization` | 是 |
| `thought_tag_convergence` | `thoughtOrganization` | 是 |
| `insight` / `health_insight_generation` | `deepAnalysis` | 是 |
| `memory_observer` | `dailyObserver` | 是 |
| `/v1/asr/transcriptions` | `asr` + 对应业务 quota | 部分可见 |
| `agent_loop` | `agentTask` | Phase 2 可见 |

### 8.4 限额判断顺序

```text
解析 deviceId / userId
→ 读取 entitlement，确定 free / plus
→ 映射 purpose 到 quota_type
→ 如果是 internalIntent，只做内部计数，不扣用户可见 quota
→ 检查 per-minute 限流
→ 检查 daily / weekly / monthly quota
→ ASR 检查单次 60 秒
→ 执行上游模型或 ASR
→ 记录 used_count / tokens / asr_seconds
→ 返回 remaining / resetAt / quotaType
```

### 8.5 客户端职责

客户端负责：

1. 展示会员状态：免费版 / Plus。
2. 在 Plus 功能入口展示锁标识或 Plus 标签。
3. 触发 Plus paywall。
4. 使用 StoreKit 2 完成购买和恢复购买。
5. 同步订阅状态到后端。
6. 展示剩余次数与恢复时间。
7. 免费用户超限后降级到手动输入。
8. ASR 超 60 秒时提示用户缩短录音。

客户端不负责：

1. 最终判定能否调用 AI。
2. 自己计算 token 成本。
3. 绕过后端直接调模型。

---

## 9. 上线阶段

### Phase 0: 计费后端前置工程

目标：先把“能可靠计数、能判断权益、能返回剩余次数”打通。

交付：

1. 基于现有 SQLite 限流扩展 quota ledger。
2. 建立 `purpose -> quota_type` 映射。
3. 接入 StoreKit receipt 校验或 Phase 0 过渡 entitlement。
4. `finance_action_parser` / `task_action_parser` 归入 `naturalLanguageInput`。
5. intent 内部计数但不扣用户可见 quota。
6. `/v1/asr/transcriptions` 增加 60 秒硬截断。
7. daily reset 按 `Asia/Shanghai`。
8. 限额响应返回 `remaining`、`resetAt`、`quotaType`。

验收：

1. 后端重启后 quota 不丢。
2. 免费用户自然语言记账超过 20 次/天后被拦截。
3. Plus 用户自然语言记账超过 50 次/天后被拦截。
4. intent 不导致一次聊天扣两次用户可见 quota。
5. 超 60 秒 ASR 被拒绝。
6. 北京时间 0 点恢复每日次数。

### Phase 1: 最小商业化闭环

目标：上线可购买、可恢复、可解锁、可限额的 Holo Plus。

交付：

1. Plus 月付、年付 StoreKit 商品。
2. 付费弹窗与会员中心。
3. 恢复购买。
4. 桌面小组件、财务分期、高级统计权益控制。
5. AI 聊天：免费 3 次/天，Plus 30 次/天。
6. 自然语言记账：免费 20 次/天，Plus 50 次/天。
7. 自然语言任务：免费 10 次/天，Plus 30 次/天。
8. AI 局限性披露。
9. Family Sharing 关闭。

暂不上：

1. 买断。
2. Pro。
3. 积分包。
4. 额外 AI 次数包。
5. 重型 Agent。

### Phase 2: AI 能力扩展

目标：在 Phase 1 成本可控后，开放更高价值 AI。

交付：

1. AI 深度分析：Plus 1 次/天。
2. AI 自动整理想法：Plus 3 次/天。
3. AI 周报：Plus 1 次/周。
4. AI 月报：Plus 1 次/月。
5. 生活观察：Plus 1 次/天。
6. 重型 Agent：Plus 5 次/月。
7. 内部 usage dashboard。

### Phase 3: 成本校准

目标：用真实数据决定是否调整价格、次数和 token 保险丝。

观察 2-4 周：

1. Plus 转化率。
2. 月付 / 年付比例。
3. 人均 AI 聊天次数。
4. 隐式调用次数。
5. ASR 秒数分布。
6. P90 / P99 token 消耗。
7. 失败率和重试率。
8. 单 Plus 用户月均成本。
9. 重度用户占比。

决策：

1. 是否结束或延长 `¥98/年` 早鸟。
2. 是否稳定展示 `¥128/年`。
3. 是否调整每日次数。
4. 是否启用月度 token 软/硬上限。
5. 是否继续扩大 Agent 能力。

---

## 10. 关键测试清单

### 后端

| 测试 | 预期 |
|---|---|
| 免费用户 chat 第 4 次 | 返回限额错误，含 `remaining=0` 和 `resetAt` |
| Plus 用户 chat 第 31 次 | 返回限额错误 |
| 免费用户自然语言记账第 21 次 | 降级提示，不调 parser |
| Plus 用户自然语言记账第 51 次 | 返回限额错误 |
| intent + chat | 只扣 chat 可见 quota |
| ASR 61 秒 | 返回音频过长 |
| 北京时间 0 点后 | daily quota 恢复 |
| 后端重启 | 当日 quota 不丢 |

### 客户端

| 测试 | 预期 |
|---|---|
| 免费用户点 Plus 功能 | 展示 paywall |
| 用户购买 Plus 成功 | 原功能立即解锁 |
| 恢复购买 | 正确恢复 Plus |
| 免费 AI 超限 | 展示升级文案 |
| 免费自然语言记账超限 | 可以手动表单输入 |
| Plus 深度分析超限 | 提示明天恢复 |
| ASR 超 60 秒 | 提示缩短录音 |

### App Store

| 检查项 | 预期 |
|---|---|
| IAP 商品 | Monthly / Yearly 配置正确 |
| 恢复购买 | App 内可见 |
| 元数据 | 与 App 内权益一致 |
| AI 局限性 | 付费页和审核说明均有 |
| Family Sharing | 关闭 |

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| Plus 成本高于预期 | 年付毛利不足 | 早鸟限时/限量，标准价 ¥128，Phase 3 校准 |
| ASR 被重度使用 | 成本按秒上升 | 单次 60 秒硬截断，Phase 3 看是否加总时长 |
| 隐式调用绕过限额 | 免费侧成本穿透 | action_parser 归入 naturalLanguageInput |
| intent 双重扣额 | 用户实际次数缩水 | intent 内部计数，不扣用户可见 quota |
| UTC 切日 | 中国用户早 8 点才恢复 | 按 Asia/Shanghai 切日 |
| 付费弹窗太频繁 | 降低信任 | 只在触发 Plus 功能或超限时弹 |
| StoreKit 状态伪造 | 权益绕过 | 后端校验 receipt，维护 entitlement |
| AI 结果被误解 | 审核或用户投诉 | 明确 AI 结果仅供参考 |

---

## 12. 最终定稿

```text
免费版：
完整记录生活。
AI 聊天 3 次/天。
自然语言记账 20 次/天。
自然语言任务 10 次/天。
单次语音最长 60 秒。

Holo Plus：
¥12/月。
¥98/年，首发 14 天或前 500 名早鸟。
标准价 ¥128/年。

Plus 包含：
桌面小组件、财务分期、高级统计、
AI 聊天 30 次/天、
自然语言记账 50 次/天、
自然语言任务 30 次/天、
AI 深度分析、AI 自动整理、AI 周/月报、生活观察。

Phase 1 不含：
重型 Agent。

不做：
买断、Pro、积分包、额外 AI 次数包。
```

如果后续进入实现，凡涉及 `HoloBackend` 的配置、路由、quota、StoreKit receipt 校验、AI purpose 映射或 ASR 限制变更，都需要在本地验证后进行后端发版，否则生产环境不会生效。
