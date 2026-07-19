# Holo Agent 真机与灰度验收清单

> 日期：2026-07-19
> 适用：iOS 17+ 可靠恢复；iOS 26+ Continued Processing
> 结论规则：自动化通过不等于真机通过；任一 P0 用例失败即 No-Go，不开启 TestFlight 灰度。

## 一、验收前置

- 后端 step 幂等版本已部署生产，`/v1/health`、带鉴权 release 验收与生产重复请求协议验证通过；管理员发布状态必须返回 `agentStepIdempotencyResponseEncryption = aes-256-gcm-v1`，生产数据库 TTL 内有效响应的明文记录数必须为 0。
- 当前生产验收基线：Git `4f6757a3bdae34ff769c354f15a6b779bba243ae`，source digest `78667682b4e101f8d8277104b7bdee205c3e0087a3da56488464f9334aa0bbd8`，构建时间 `2026-07-19T08:34:56Z`；发布时已验证 4/4 条有效完成响应为 AES-GCM 密文、明文 0 条。
- iOS 26 真机使用最新 Debug 包；如有 iOS 17/18 真机，再执行旧系统 fallback 组。
- Holo 已授予 AI 数据处理授权；Health 场景使用有真实健康数据且已授权的 iPhone。
- Agent Runtime、请求步骤幂等、记忆长廊结果、Observer Tier2 自动深挖和 iOS 26 持续处理均由产品默认开启，无需手动配置。
- 每个场景使用一个新问题，记录开始时间、系统版本、网络、是否低电量模式、最终状态和异常截图。
- 真机验收期间不要通过 App Switcher 强杀 Holo，除非当前用例明确要求验证强杀边界。

## 二、Debug 证据怎么取

在 Debug 构建进入“设置 → AI → Agent 调试入口”：

1. 场景开始前生成一次快照，记录当前任务数和事件基线。
2. 场景结束后再次生成并分享 JSON。
3. 重点核对 `activeLeases`、`structuredEvents`、`reliabilityMetrics`。
4. 快照只能包含技术元数据；如果出现用户问题、对话、工具结果、健康数值、金额、证据/结论原文或 `requestHash`，立即判定隐私 No-Go。

关键事件：

```text
agent_job_created
agent_execution_acquired / agent_execution_attached
agent_lease_changed
agent_checkpoint_committed
agent_execution_expired
agent_resume_started
agent_step_idempotency_hit
agent_result_reconciled
agent_job_completed / agent_job_failed / agent_job_cancelled
```

## 三、iOS 26 核心场景

### A. 前台与跨页面基线

- [ ] 在 Chat 发起需要多轮工具查询的深度分析。
- [ ] 立即返回 Holo 首页，等待 30–60 秒，再回 Chat。
- [ ] 预期：同一 job 继续或已完成；不会重新创建第二个任务；最终只出现一个结果。
- [ ] 证据：同一 `jobID` 只有一个有效 generation；出现 attach 时不再出现第二条并发 acquired。

### B. 回 iOS 主界面

- [ ] 发起深度分析后立即回桌面，停留至少 60 秒。
- [ ] 查看系统持续处理界面是否可见、标题是否为通用文案、进度是否只前进不回退。
- [ ] 回到 Holo。
- [ ] 预期：系统接纳时任务继续并完成；系统未接纳/中止时状态真实暂停，回前台从断点恢复。
- [ ] 隐私：系统 UI 不出现问题原文、金额、健康数据、工具摘要或推理内容。

### C. 切换其他 App

- [ ] 发起后切到 Safari/微信等普通 App，停留 60 秒再返回。
- [ ] 再切到相机、地图或高内存 App，制造更强资源压力。
- [ ] 预期：普通切换优先持续执行；进程被系统清理时，下次打开恢复同一 job，不双跑、不重复结果。

### D. 锁屏矩阵

- [ ] LLM 请求发出前锁屏 60 秒，再解锁。
- [ ] LLM 请求进行中锁屏 60 秒，再解锁。
- [ ] 本地工具执行中锁屏 60 秒，再解锁。
- [ ] Result 保存临界点附近锁屏/解锁并重新进入。
- [ ] 预期：已有 step identity 不变化；相同响应最多应用一次；半完成状态由 reconciler 修复。

### E. HealthKit 锁屏语义

- [ ] 发起明确需要读取健康数据的问题，在读取发生前锁屏。
- [ ] 预期：数据库不可读时显示“等待解锁/数据条件”，不能生成 0 步、0 睡眠、空运动或“没有健康数据”的结论。
- [ ] 解锁并回到 Holo。
- [ ] 预期：同一 job 恢复，读取真实健康数据后继续。

### F. 用户停止与系统结束

- [ ] 从系统持续处理入口执行“停止”（以真机当前系统提供的动作/语义为准）。
- [ ] 预期：本次 lease 结束，job 落为可解释的 paused/system-capacity，不自动静默复活。
- [ ] 回到 Holo，执行明确的继续动作。
- [ ] 预期：取得新 generation，从 checkpoint 继续并只生成一个结果。
- [ ] 另测 Holo 内用户取消：应为 `cancelled`，之后不能自动恢复。

### G. 网络切换与重复请求

- [ ] LLM 进行中开启飞行模式，等待失败/重试状态，再恢复网络。
- [ ] Wi-Fi 与蜂窝数据间切换一次。
- [ ] 预期：重试沿用同一 `runId + stepId + requestHash`；若服务端已完成，客户端收到幂等命中并复用结果，不重复计费/产出。
- [ ] 证据：出现 `agent_step_idempotency_hit` 时，同一步只有一次有效 provider 完成记录。

### H. 强制关闭边界

- [ ] 发起任务并确认 checkpoint 已写入后，从 App Switcher 强制关闭 Holo。
- [ ] 预期：本地任务立即停止；系统不会承诺强杀后继续。
- [ ] 手动重新打开 Holo。
- [ ] 预期：恢复同一 job 或显示明确等待/失败原因，不产生重复结果。

## 四、iOS 17/18 fallback（有对应真机时执行）

- [ ] 发起任务后回桌面 5 秒再返回：允许利用短时后台窗口收尾。
- [ ] 回桌面超过 legacy expiration：应进入等待前台，旧 Task 已取消。
- [ ] 快速 background → active → background：只 attach 同一 job，不双跑。
- [ ] 冷启动：扫描 orphan，使用新 generation 从 checkpoint 恢复。
- [ ] 锁屏健康查询：与 iOS 26 相同，不得伪造零值。

## 五、资源与边界场景

- [ ] 低电量模式开启。
- [ ] 后台 App 刷新关闭。
- [ ] 系统不给 Continued Processing 容量。
- [ ] 跨午夜、修改时区、手动调整系统时间。
- [ ] 首次解锁前与首次解锁后的锁屏（可执行时）。

这些场景允许“不能继续跑”，不允许“状态仍显示运行但实际无 lease”、丢 checkpoint、双执行、重复 Result 或健康伪零值。

## 六、单场景记录模板

```text
设备 / iOS：
App 构建：
后端 release：
场景编号：
开始时间：
网络 / 低电量：
系统是否接纳 Continued：
用户可见状态变化：
最终 jobID / state / waitReason：
generation / checkpointRevision / leaseKind：
是否只有一个最终结果：
是否发现敏感内容：
Debug 快照文件：
结论：PASS / FAIL
备注：
```

## 七、Go / No-Go

### 真机 Go

- [ ] 同一 job 的有效 runLoop 始终为 0 或 1。
- [ ] 已持久化 checkpoint/evidence 不丢；系统中止后可从安全断点恢复。
- [ ] 每个 job 最多一个 canonical result。
- [ ] HealthKit 锁屏不可读不转成零值/无数据结论。
- [ ] 系统 UI 和 Debug 导出无用户敏感原文。
- [ ] 用户取消、系统结束、条件等待三种状态语义可区分。
- [ ] 无 crash、watchdog、明显异常发热/耗电。
- [ ] 后端有效幂等响应全部为认证密文；密钥不出现在响应、日志、报告或仓库。

### 直接 No-Go

- 双 runLoop、旧 generation 覆盖新 checkpoint、重复 Result。
- step 重试产生重复 provider 有效调用或 payload 冲突未拒绝。
- 锁屏健康数据被解释为 0/无数据。
- 系统 UI、客户端日志、后端日志或 Debug 快照泄露业务原文。
- 后端 SQLite 存在 TTL 内明文 Agent step 响应，或加密状态未被发布验收强校验。
- 强杀/expiration 后任务永久卡在“运行中”。
- 可复现 crash、watchdog 或明显后台能耗异常。

## 八、TestFlight 灰度

1. 内部 TestFlight：用户主动 Chat Agent 与 Observer Tier2 均按产品策略开启，持续 2–3 天；单独统计主动与自动任务。
2. 第一档：少量 iOS 26 内测用户验证 Continued Processing；iOS 17–25 继续 fallback。
3. 第二档：扩大 iOS 26 用户范围，同时观察 Observer 触发准确率、P0 抢占、能耗和模型成本。
4. 指标异常时统一调整 Observer 信号门槛、预算或通过紧急版本回退，不增加用户设置开关。

每档至少观察：完成率、恢复完成率、expiration 率、stale rejection、幂等命中、重复结果、crash、watchdog、后台能耗和用户取消率。没有真实样本时不得把“0 次失败”解读为 100% 成功。

量化门槛：

- 内部 TestFlight：至少 2 台 iOS 26 真机、30 个用户主动 job、持续 2–3 天。
- 第一档：至少 10 名用户或 100 个有效 job，持续至少 3 天；正常网络有效问题完成率 ≥ 95%，条件恢复完成率 ≥ 95%，回 active 后 2 秒内进入执行或明确等待状态，crash-free sessions ≥ 99.5%。
- 扩大默认开启前：累计至少 300 个有效 job、连续 7 天；无 crash/watchdog、双执行、重复结果、健康伪零、隐私泄露或明显后台能耗回归。
- Continued Processing 接纳率不是硬性通过指标；系统拒绝或 expiration 可以发生，但状态必须真实、checkpoint 不丢且回前台可恢复。

回滚顺序：先关闭 Continued Processing → 保留 step 幂等与可靠恢复；必要时再关闭客户端 step 幂等调用。P0 generation/CAS、持久化防覆盖、Result 唯一和 HealthKit 严格语义不回滚。
