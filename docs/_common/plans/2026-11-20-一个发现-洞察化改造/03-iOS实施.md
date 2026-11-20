# 03 · iOS 实施

> 前置：读 `01-方案总纲.md`；读 `docs/standards/设计规范.md`（改 UI 前）、`docs/standards/开发规范.md` 第 13、16 节。
> 路径前缀：`Holo/Holo APP/Holo/Holo/`

## 现有代码地图（v3）

| 文件 | 角色 | v4 处理 |
|---|---|---|
| `Services/AI/Discovery/DiscoveryMemoryReviewService.swift` | 本地扫描 + 5 分钟缓存 | 保留；v4 新增分支调用新 Builder |
| `Services/AI/Discovery/DiscoveryTopicService.swift` | 形状提取、选题、buildCard、localFallback | 保留作 v3 兜底，不修改其逻辑 |
| `Services/AI/Discovery/DiscoveryTopicStore.swift` | UserDefaults 队列、每日一条、冷却 | 扩展可选字段 |
| `Services/AI/Discovery/DiscoveryLocalService.swift` | presentationState | 不变 |
| `Views/Chat/DiscoveryReviewSheet.swift` | 「今日一条」卡片 | 新增 v4 卡片视图 |
| `Services/AI/Understanding/*` | 蒸馏 + 画像 | 只读复用；反馈回流需调用 PortraitStore API |

## 任务拆分（每项改动 ≤3 个文件）

### I1 · 契约类型 `Services/AI/Discovery/V4/DiscoveryInsightContract.swift`（新）

按总纲 §5.1 和 §5.2 定义 `InsightInputPacket` 和 `InsightDraft`（Codable、Sendable、值类型、不可变）。附 JSON 编解码单测，对照总纲中的样例。

### I2 · 候选构建 `DiscoveryInsightCandidateBuilder.swift`（新，纯逻辑）

- 输入：`PortraitStore` 当前条目（只取 `confirmed` / `inferred`，排除拒绝黑名单）、`HoloLifeFeatureDistiller` 输出的 `CrossDomainFeaturePacket`、miner 产出的 `HoloKnowledgeRevision`（转为带 slots 的 feature）、目标/习惯/想法中的意图短句。
- 输出：`InsightInputPacket` 和端侧私有的 `SlotValueTable`（`[featureId: [slotName: 格式化后的值]]`，**不上传**）。
- 去标识化：复用记忆系统现有的去标识化工具，**不要另写**（实施前先 grep 定位）；`description` 中出现数字时剥离并转为 slot。
- 截断规则见总纲 §5.1。
- 数据不足判定：portrait + features < 3 → 不请求，直接走 v3。
- 单测：去标识化（输出中不含数字或金额）、截断、拒绝黑名单过滤、slot 表与 packet 一致。

### I3 · 请求服务 `DiscoveryInsightService.swift`（新）

- 走 `HoloBackendAIProvider`，purpose = `.discoveryInsightV2`（在 purpose 枚举中新增），`stream=true` + `sendStreaming`，**必须流式**。
- 端侧终检（防御后端闸门遗漏，同时满足方案 B）：解析 → 数字检查 → refId / slot 引用检查 → 长度检查。数字检查要同时覆盖中文数字，与后端共用同一组测试样例。
- 失败、开关关闭或 `noneReason` 时：`disabled` / `gate_rejected` / 网络错误回落 v3 `DiscoveryTopicService.refreshIfNeeded`；`none_worthwhile` → 当天不出卡，**不回落**（宁缺毋滥）。
- 错误用 `Logger` 记录，不得静默吞掉。

### I4 · 卡片组装 `DiscoveryInsightCardBuilder.swift`（新，纯逻辑）

- 用 `SlotValueTable` 填充 evidence 模板，得到 `evidenceLines`；有任一 slot 缺值时删掉该行，删完后行数为 0 则整卡作废。
- 填充后的终检：不得残留 `{`；evidence 中的数字必须全部来自 slot。
- 产出 `DiscoveryInsightCard` 并写入 `DiscoveryTopicStore`（I5）。

### I5 · Store 扩展 `DiscoveryTopicStore.swift`

- 新增可选字段（总纲 §5.3），`version` 缺省视为 3。
- `todayCard()` 规则不变：每日一条，v4 优先。
- 维护 `recentAngleKeys`（最近 30 天）和 `rejectedAngleKeys`，供 I2 填入 packet。

### I6 · 卡片 UI `Views/Chat/DiscoveryInsightCardView.swift`（新）

结构自上而下：
1. 领域 chip（sourceDomains，跨域时显示「习惯 × 任务」）；
2. `headline`（标题字号，遵循设计规范）；
3. `insight` 正文；
4. 「依据」折叠区：默认收起，展开后显示 1～3 行 evidenceLines，每行前面带领域图标（SF Symbol 先验证存在）；
5. `prompt`（若有），弱化样式；
6. 底部三个按钮沿用 v3：准 / 不太准 / 先放一放。

`DiscoveryReviewSheet` 中按 `card.version` 选择 v4 或 v3 视图。ScrollView `showsIndicators: false`。v3 视图不改。

### I7 · 反馈回流 `DiscoveryInsightFeedbackBridge.swift`（新）

- 准：把卡片对应的 `portraitRefs` 在 PortraitStore 中升级为 `confirmed`；无 portraitRef（纯 feature 产生的洞察）时，新建一条 `crossDomainInsight` 维度、`confirmed` 的画像条目，statement 用 insight，evidenceSummary 用去掉数字的 evidence。
- 不太准：`angleKey` 进入 `rejectedAngleKeys`；对应 portraitRefs 进入画像拒绝黑名单（先核实现有 API）。
- 先放一放：沿用 v3 的 7 天冷却。
- 写入后 `await` 刷新，并发送现有的知识变更通知，让记忆页同步。
- 单测：三种反馈对 Store / PortraitStore 的影响（Core Data 测试用 `async throws`）。

### I8 · 开关

本地 `DiscoveryFeatureFlags.insightV2Enabled`（DEBUG 默认开，Release 默认跟随后端；后端返回 `disabled` 时即视为关闭）。

### I9 · Prompt 后备

`Services/AI/PromptManager.swift` 加入 `discovery_insight_v2` 模板（内容与后端一致），升级 `promptVersions`。

## 验证

- 每项任务完成后 `build_sim`；涉及测试的用 `test_sim`。
- 模拟器无 HealthKit 数据，健康相关 feature 用 Mock 数据源单测覆盖。
