# Holo App Store 首版上线清单

> 制定时间：2026-08-07
> 适用范围：首版（v1.0.0）发布到 App Store
> 原则：**首版目标不是完美，是「能跑、不崩、合规、成本可控」**。体验优化全部进 v1.1。

---

## 阶段总览

| 阶段 | 内容 | 目标 |
|------|------|------|
| **P0 今天** | 冻结功能 + 降配额 | 锁定要发的版本，止住成本风险 |
| **P1 上线前** | 崩溃监控 + 反馈通道 | 上线后不盲飞 |
| **P2 上线后第一周** | App Attest + 会员恢复验证 | 止住成本黑洞 + 防付费用户投诉 |

---

## P0｜今天必须完成（决定，不是写代码）

### P0-1 冻结首版功能范围 ✅ 已调查清楚

**现状**：工作区 58 个改动，调查后分三桶：

| 桶 | 内容 | 结论 |
|----|------|------|
| A1 表达式引擎 | `ExpressionEngineTests.swift`(编译不过)、`VerifyExpressionEngine.swift`、`HoloQueryRowFormatter.swift` | **❌ 半成品，必须剔除**。核心源码（`HoloExpressionNode/Evaluator/Validator`）没写，测试加进 target 会编译失败 |
| A2 AI 体验大改 | 15 项（实时进度/停止重试/长按菜单/跨模块入口/缓存瘦身/流式中断/收藏分享等） | **✅ 已完成、有测试、可进首版** |
| B 独立修复 | 标签空白折叠、想法整理重构、日历色阶测试、各模块零散小改 | **✅ 已完成、可进首版** |
| C 文档 | `_tmp_screen.png`、两份 plan 文档、V3 方案文档、CLAUDE.md、开发守则 | 文档可随版；`_tmp_screen.png` **删除** |

**执行步骤**：
1. 把 A1 的三个文件从编译目标移除（或直接删掉）—— `ExpressionEngineTests.swift`、`VerifyExpressionEngine.swift`、`HoloQueryRowFormatter.swift`
2. 删除 `docs/_tmp_screen.png`
3. 确认 `docs/plans/2026-08-03-agent-expression-engine-plan.md` 标记为「推迟到 v1.1」
4. 其余所有改动（A2 + B + 文档）作为一个提交：「feat: 首版功能冻结 — AI 体验大改 + 想法标签整理 + 各模块优化」
5. 提交后跑一次完整编译 + 测试，确认绿

### P0-2 降低免费 AI 额度 ✅ 一行配置

**现状**：后端默认 `HOLO_CHAT_REQUESTS_PER_DAY=50`。
**风险**：App Attest 未接入，设备 ID 可伪造，50 次/天 × 无数假设备 = 成本黑洞。

**执行步骤**：
1. 改后端生产环境变量：`HOLO_CHAT_REQUESTS_PER_DAY=15`（够用户体验，不够商用薅）
2. 同步把 `HOLO_ASR_REQUESTS_PER_DAY` 从默认 20 降到 8
3. **需要后端发版**（重启服务生效）

**说明**：这是临时止血。真正的根治是 P2 的 App Attest，接好后可以把额度调回合理值。

---

## P1｜上线前必须完成（写代码，但工作量小）

### P1-1 接入崩溃监控（MetricKit，零依赖）

**现状**：工程内无任何崩溃/性能监控。苹果自带 MetricKit 免费、零第三方依赖，能抓「崩溃 + 卡顿 + CPU/内存峰值」。

**执行步骤**：
1. 新建 `HoloMetricManager.swift`（@ObservableObject），遵循 `MXMetricManagerSubscriber`
2. 订阅三类 payload：`MXCrashDiagnostic`、`MXHangDiagnostic`（卡顿）、`MXCPUExceptionDiagnostic`
3. 在 `HoloApp.init()` 里 `MXMetricManager.shared.add(subscriber)`
4. 收到 payload 时：写到本地日志文件（`FileManager`，按日期滚动）+ 落 OSLog
5. 设置页加一个「诊断日志」入口（可复用现有 `HealthKitDiagnosticsView` 的模式），让用户能导出日志发给你
6. **不需要后端发版**

**为什么不直接上 Crashlytics**：MetricKit 系统自带、零依赖、不引入第三方 SDK（对隐私审核更友好）。首版够用。等用户量上来再考虑 Crashlytics。

### P1-2 设置页加「用户反馈」入口

**现状**：协议里有 `support@holoapp.cn`，但设置页无明显反馈入口。没有监控时，用户反馈是唯一的线上感知渠道。

**执行步骤**：
1. 在 `SettingsView` 的 `otherSettingsSection`（或新建一个 section）加一行「反馈与建议」
2. 点击后用 `MFMailComposeViewController`（MessageUI），预填收件人 `support@holoapp.cn`、主题「Holo 反馈」、正文带设备型号 + 系统版本 + App 版本（方便你定位）
3. 若用户未配置邮件账户，降级为复制邮箱 + 提示
4. **不需要后端发版**

---

## P2｜上线后第一周完成（中等工程，不阻塞首版）

### P2-1 App Attest 全链路（防伪造，止住成本黑洞）

**现状调查（重要）**：后端的 App Attest **是空壳**，不是「写好了接口」：
- `POST /v1/app-attest/challenge` ✅ 能用（返回随机 nonce，但未落库、未绑定设备、可重放）
- `POST /v1/app-attest/assert` ❌ 所有真实请求都返回 401「not implemented yet」
- `getDeviceId()` 只读 `x-holo-device-id` header，**不校验 attestation**，带任意字符串就能绕过强制开关
- 后端无 CBOR/COSE 解析库，无证书链验证，无签名校验

**这意味着**：App Attest 是「前后端都要补」的中等工程，不是「iOS 接一下就完」。

**执行步骤（分前后端）**：

**后端先做（P2-1a）**：
1. 加 CBOR 解析依赖（如 `cbor` 或 `@peculiar`）
2. `assert` 接口实现完整验证链：接收 attestationObject → 解 CBOR → 验 Apple 证书链 → 提取公钥 → 绑定 deviceId 落库
3. challenge 接口改为 nonce 落库 + 一次性消费 + 绑定设备
4. `getDeviceId()` 改为：优先读已验证的 attestation session，header 里的 deviceId 只作 fallback
5. **需要后端发版**

**iOS 后做（P2-1b）**：
1. 新建 `HoloAppAttestService.swift`，封装 `DCAppAttestService`
2. 启动时（或首次调 AI 接口前）：challenge → `generateKey` → `attestKey` → 上传 assert
3. 后续受保护请求生成 assertion 附带
4. 处理 KeyChain 持久化 keyId、过期重置等
5. **不需要后端再次发版**（配合 P2-1a 联调）

**强制开关节奏**：先软上线（`enforceAppAttest=false`，只记录不带 attestation 的请求比例），观察 1-2 天确认 iOS 端无异常，再切 true。

### P2-2 验证「换设备恢复会员」全流程

**现状风险**：会员状态靠 `X-Holo-Device-Id` 同步，不是靠 Apple ID。换机/重装 → deviceId 变 → 会员状态可能丢失 → 付费用户投诉/退款。

**执行步骤（人工测试，非代码）**：
1. 用 A 设备购买 Plus（沙箱或促销码）
2. 在 B 设备装 App、用同一 Apple ID 登录
3. 点「恢复购买」，验证：会员状态是否正确恢复、各档位功能是否解锁
4. 测试「卸载重装」（同设备）场景
5. 重点验证：`HoloSubscriptionService.restorePurchases()` → 后端 `/v1/subscription/sync` → 状态刷新的完整链路
6. 若失败，定位是「deviceId 没跨设备迁移」还是「后端没按 Apple 凭证匹配」

**这是排名第一的客服灾难风险点**，上线后必须第一时间盯退款投诉。

---

## 不在本清单内的事（明确推迟到 v1.1）

- Agent 表达式引擎（A1）—— 核心源码未写
- 想法模块向量化关联推荐（V3 方案）—— 代码未落地
- 后端 AI 多服务商自动 fallback —— DeepSeek 抖动时降级
- Crashlytics / Sentry 升级 —— 等 MetricKit 不够用时再做

---

## 后端发版同步点（给东林）

本清单中**需要后端发版**的项：
- P0-2：降低免费额度（改环境变量 + 重启）
- P2-1a：App Attest 后端验证链

其余项均为 iOS 单端改动或人工测试。
