# 云端异步深度分析（二期）设计稿 v1.0

日期：2026-08-30 ｜ 状态：两轮对抗性审查通过，M1 开工
前置：一期止血包（后端 4e2a3efe / iOS e5deaabe）已上线，锁屏断连死循环已根治但「锁屏期间推进」仍受 iOS 后台窗口约束；二期把执行搬上云根治。

## 使命

发起深度分析 → 本地聚合数据包上传 → 云端队列跑完整 Agent → 完成推送/回前台拉取 → 结果落地本地、云端数据即焚。锁屏/杀 App/没电不影响执行。执行与手机生命周期彻底解耦。

## 关键决策（含两轮审查结论）

1. **销毁承诺代码化**：任务完成/失败/取消时，后端主动 DELETE 该 runId 的全部 step 幂等缓存 + 快照 + 结果副本；7 天无人认领过期清理兜底。文案「分析结束即删除」由真实行为背书。
2. **结果只在设备上**：结果回传确认后云端删除；追问时 iOS 携带上文。多设备查看三期另议。
3. **快照=数据域结构化全集**（非预挖结论），云端工具=快照查询器，动态分析循环（need_tools→executeTools）完整保留，不牺牲深度。
4. **第一版排除健康数据**：涉健康的分析自动走本地轨道（合规保守项，东林可推翻，推翻需同步隐私披露）。
5. **双轨灰度**：云端轨道 feature flag 控制，失败/超时自动回落本地 runAnalysis。云端故障零用户影响。
6. **隐私文案**（首启一次+设置可查+隐私政策同步）：
   > 为了让你锁屏、离开 App 后分析也能完成，Holo 会把本次分析所需的数据（如任务、账目、习惯、想法记录）加密上传到云端完成分析。这些数据仅用于这一次分析——分析结束或失败后立即删除，云端不会保留；分析结果只保存在你的设备上。Holo 不会出售你的数据，也不用于广告。
   禁止表述：「Holo 不存储用户数据」（全局假承诺——长期记忆/本地存储存在）。

## 架构

### 数据流
```
iOS 前台发起
  ├─ 本地聚合各数据域快照（任务/财务/习惯/想法/日历…，不含健康）
  ├─ POST /cloud/start → taskId
  ├─ PUT /cloud/:id/snapshot（分片，AES-256-GCM 服务端落存）
  └─ 锁屏自由离开
云端 worker
  ├─ 快照齐备 → 状态 uploading→queued→running
  ├─ Node 版 runLoop（LLM 循环+快照工具查询+Verifier）→ completed
  ├─ 完成即焚：DELETE step 缓存（该 runId）+ 快照
  └─ 结果密文暂存（≤7 天）等回传，APNs 推送通知
iOS 回前台/点通知
  ├─ GET /cloud/:id → 结果（回传成功即 DELETE 结果+整行）
  └─ 渲染落本地（复用现有 HoloAgentResultStore + 消息管道）
```

### 后端（M1 底座 → M2 执行器）

**M1：任务底座**
- migration #16 `agent_cloud_analysis_tasks`：id(runId)/device_id/status(uploading|queued|running|completed|failed|cancelled|expired)/question(密文)/snapshot_encrypted(BLOB)/snapshot_size/result_encrypted/时间戳组/expires_at_ms(创建+7d)。
- 快照与问题字段复用 stepResponseCipher 的 AES-256-GCM 应用层加密模式（独立 key，AAD=taskId）。
- 端点：
  - `POST /v1/ai/agent/cloud/start`：创建任务（限流+额度预留按现有 deepAnalysis 池，quotaType 复用）。
  - `PUT /v1/ai/agent/cloud/:id/snapshot`：上传快照（首版单次整包≤2MB 压缩 JSON；分片续传留接口位 Content-Range）。
  - `GET /v1/ai/agent/cloud/:id`：状态/结果拉取；结果回传即销毁。
  - `DELETE /v1/ai/agent/cloud/:id`：用户取消，立即销毁。
- 状态机与所有权：仅创建设备可读写（device_id 校验）。
- 兜底清理：启动时+每小时 purge 过期行（expired）。

**M2：执行器与接入**
- Node 版 runLoop：prompt 协议沿用 agentLoop 模板（PromptManager 同源下发），step 幂等沿用（重试不重算），工具=快照 JSON 查询器（finance/task/habit/thought/calendar 域）。
- 完成钩子：purge step 缓存+快照，落结果密文，APNs 推送。
- iOS：发起改造（feature flag `cloudDeepAnalysisEnabled`，服务端下发）+ 状态卡片 + 隐私文案首启页 + 回回落本地。

### 错误处理
- 上传中断：iOS 重试（幂等：同 taskId 重复 PUT 覆盖未完成快照）；超 24h 未完成上传 → 任务 expired 清理。
- 云端执行失败：状态 failed+原因密文回传；iOS 侧回落本地轨道重跑。
- 推送丢失：回前台 GET 兜底；结果密文 7 天留存期。
- 恶意滥用：现有限流（agentLoop 桶）+ 额度池（deepAnalysis action=runId）沿用。

### 测试
- M1：任务生命周期（创建/上传/拉取/取消/过期清理/跨设备 403）+ 销毁彻底性（完成后 step 缓存行数=0、快照列为 NULL）+ 密文落盘断言。
- M2：执行器对快照工具循环的端到端（fake provider）+ 完成即焚集成测试 + 回落路径。

## 里程碑
- M1（本文档落地批次）：后端任务底座+测试。
- M2：云端执行器+iOS 双轨接入+隐私文案上线（含隐私政策与 App 隐私标签核对）。
- M3（另立）：多设备结果、健康数据域评估。

## 明确不做
- 不做全量数据库上云（快照仅分析所需数据域）。
- 不做云端结果长期存储/多设备同步（三期）。
- 不改现有本地轨道任何行为（双轨并存）。
