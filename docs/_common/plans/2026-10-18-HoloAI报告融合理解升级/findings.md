# 核对发现

- 工作区存在习惯模块和财务深度洞察方案的其他在途改动，保持原样。
- 已存在 MemoryCore、MemoryRepository、MemorySignals 等记忆能力，方案应优先复用。

- 当前 HoloMemoryRecord 已包含事实/模式/假设、证据 lineageKey、有效期、反证、用户裁决和版本信息。无需重建用户画像仓库。
- HoloDefaultInsightDataSource 仅查 MemoryInsight 最近最多 6 条标题摘要；不能代表对全量历史报告的持续理解。
- 对话报告档案来源是 ChatMessageRepository；MemoryInsightService 另有周期报告生成与落库链路。需先建立统一报告适配器，而非把内容举报服务误当报告存储。
- 个人情境检索已有最多 40 条候选、8 条选取和降级规则；新能力应复用预算。
- 当前 HoloMemoryContextEnvelope 已区分精确统计与背景用途；新链路不得让报告代替明细统计。
- 财务深度洞察 06 文档已更新为真实模型方法验证完成、生产接入未开始（按工作区文件记录，非本会话实测），需要沿用其事实分层与背景接口。

## 关键补充：已存在的报告融合雏形

- `HoloReplayDigestService.swift` 已维护一个 JSON 累计摘要，含 keyPatterns、trackedGoals、sourceInsightIDs；监听回放完成并调用 AI 合并，有历史回填与冷却。不能把这次方案说成首次引入历史报告联系。
- `HoloLongTermMemoryCandidateObserver.swift` 已监听同一回放事件、受 feature flag 保护、经 Mapper/PromotionPolicy 写入候选。新链路必须核实桥接方式，切写入权，不能双写晋升。
- `HoloPeriodReplayCoordinator.swift` 云端成功回放同样落洞察档案并发通知；snapshotHash 缺失时存在只落卡不落档案分支，适配器要覆盖并明确来源可用率。
- `HoloCloudAnalysisService.swift` 结果有 claims 与 evidence，但呈现层只保留部分信息；方案要求落地时保留理解所需映射，不能把渲染后的文本当全部证据。
- `HoloMemoryAccessPolicy.swift` 统一约束自动学习、回答辅助和外部 AI 授权。本次不会默认替用户打开开关。
- 后台目的集合实际含 personal_context_*、memory_* 等，未见 replay_digest_consolidation；该摘要目的云端任务与直接调用都有轨道，需实施时追踪预算归属，现阶段不认定线上漏洞。

## 当前源码定位（项目根目录相对路径）

全部 iOS 路径前缀为 `Holo/Holo APP/Holo/Holo/`。

| 文件/入口 | 已读位置 | 证明范围 |
|---|---|---|
| Services/AI/MemoryInsightService.swift | 285–336 | ready 持久化、候选卡片通知 |
| Services/AI/Insight/HoloPeriodReplayCoordinator.swift | 73–144 | 云端回放解析、落档案和完成通知 |
| Services/AI/HoloLongTermMemoryCandidateObserver.swift | 20–151 | 既有候选萃取、晋升与旧 Store 调用 |
| Services/AI/HoloReplayDigestService.swift | 20–200、590–636 | 累计摘要模型、维护、历史回填、完成观察器 |
| Services/AI/Agent/Cloud/HoloCloudAnalysisService.swift | 440–500 | 云端 claims/evidence 到渲染结果与消息持久化 |
| Data/Repositories/ChatMessageRepository.swift | 搜索定位 810、1203、1569、1606 | 完成持久化、删除、报告 DTO 与档案查询入口；方法内部待实施进一步核对 |
| Views/Chat/ReportTab/ChatReportTabViewModel.swift | 20–155 | 页面分页和同周期去重，不适合作为学习扫描源 |
| Services/AI/Agent/Tools/HoloInsightDataSource.swift | 14–89 | 最近最多 6 条洞察标题摘要读取 |
| Models/AI/HoloMemoryRecord.swift | 11–218 | 类型、状态、裁决、证据与版本及可选载荷 |
| Models/AI/HoloMemoryEvidence.swift | 11–64 | lineageKey、revision、范围与聚合口径 |
| Services/AI/MemoryRepository/HoloMemoryRepository.swift | 32–139 | 开关默认值、写入/裁决/遗忘相关契约 |
| Services/AI/MemoryCore/HoloMemoryLifecycle.swift | 17–175 | 支持/反证/替代/纠正与独立血统计数 |
| Services/AI/PersonalContext/HoloContextRetrievalService.swift | 34–200 | 候选 40、选取 8、反证与混合检索 |
| Services/AI/HoloMemoryContextEnvelope.swift | 99–152 | 统计回源、背景限定和使用标记 |
| Services/AI/MemoryQuery/HoloMemoryAccessPolicy.swift | 11–100 | 学习/回答/授权统一边界 |
| HoloBackend/src/usage/backgroundCostGuard.js（仓库根目录） | 1–130 | 后台目的集合、预算预留、计费与 resetAt |

## 实施时还要核对，本文未下结论

1. 各生产安装包实际开关/门控、服务器当前版本与模型效果。
2. 各类报告的实际历史数量、原始 evidence 可回查率、跨设备同步状态。
3. 旧 Store 与新 Repository 的实际读写桥接、全局来源失效通知和所有缓存。
4. 摘要 purpose 在云端任务和直调路径中的最终预算挂接。
5. 新增出处与任务台账是否可在现有持久化载荷里承载；模型若变更须另做增量迁移审查。

## 2026-10-18 主会话评审补充核对

对上文关键声明的抽查复核，作为评审修订（README 🔧 修订1–9、验收文档修订A–C）的事实依据：

- 当轮核对称 BACKGROUND_PURPOSES 无 replay_digest_consolidation。2026-10-19 补充：集合还含多个 thought_* purpose，并非只含所列五项；模板类型缺位本身不足以判断修复方式，实际链路详见下节。
- 证实：HoloInsightDataSource.recentInsights 的 fetchLimit = max(1, min(limit, 6))，「最近最多 6 条」属实。
- 证实：HoloMemoryIdentity（MemoryCore/）与 HoloMemoryCandidateReconciler（MemoryRepository/）均存在；原稿「CandidateReconciler」系缩写，README 已勘误（修订2）。
- 证实：HoloContextRetrievalService 的 mergedEntryLimit=40、selectionLimit=8 属实。
- 证实：HoloLongTermMemoryStore 存在且被 HoloMemoryRuntime 引用——新旧桥接存在，具体读写路径维持「P0 核对」结论不变。
- 修正一处错误：验收文档 §6 原称「HoloTests 无常规 Xcode test target」，与工程不符——HoloTests 为常规测试目标；文件总数并不代表执行用例数，当前桥接方式见下节。
- 当轮发现：iOS 中未找到 PersonalSituationBrief 这一命名；财务 05 的 T03 和 06 的任务表均有规格。2026-10-19 已将“本方案唯一承接”修正为“共用接口和单一注入，可先交付最小投影”。未找到命名类型不代表现有检索基础能力不存在。
- 证实：HoloCloudAnalysisService.finalizeCloudResult 位于 439 行起，与上文「440–500」相符。


## 2026-10-19 GLM 澄清复审证据

- 工程 project.pbxproj:1795–1798 定义 HoloTests unit-test target；Holo.xcscheme:50–56 包含测试目标；编译条件含 HOLO_XCTEST_BRIDGE。StandaloneExecutableBridgeTests.swift:326–328、366–368 调用记忆生命周期与仓库集成测试。修正原稿测试目标判断，不宣称本轮运行通过。
- serverPromptPolicy.js:20：replayDigest → replay_digest_consolidation 是 purpose 到 Prompt 类型的映射。app.js:825–826 直调 upstreamRequest 保留 purpose。
- cloudAnalysisExecutor.js:857–867 使用 replayDigest 注入模板并记录 cloud_replay_digest 日志，但 callProvider:580 固定发 purpose=agent_loop。app.js:375–387 的后台中间件不匹配云端异步任务路由；worker 未注入 backgroundCostGuard。当前源码两条摘要路径确实未进入该后台金额保护，不是加模板名即可修复。
- backgroundCostGuard.js:89–104 预留依赖 scope.getStore()；131–142 按 request.purpose 判定是否预留，说明云端修复需同时处理 purpose 与可信预算主体。
- shared backgroundCostGuard 集合仍包含多个 thought_* 项，不能写成“只含五项记忆目的”。
- 财务 05/06 的背景投影规格与本方案共享接口；本轮仅补交叉约定，未更改其分析方法、任务完成状态或其他并行修改。
- 已将可归并率与增量价值拆开，把工程候选与效果通过拆开，删除额外产品选择题式批准步骤；未启动业务实现。
