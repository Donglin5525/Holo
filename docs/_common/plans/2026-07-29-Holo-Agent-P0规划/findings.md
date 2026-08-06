# Holo Agent P0 规划发现

## 用户需求

- 规划 P0 四件事：连续追问、指标语义统一、真实质量门禁、生产发布身份与整体可观测性。
- 重点解释连续追问的真实复杂度、实施边界和风险。
- 本轮只产出规划，不实施业务代码。
- 用户要求进一步形成一份完整、易懂且可直接实施的连续追问方案，重点写清完整用户旅程、Use Case、产品交互如何变化、Context 如何防污染、父子 Result 如何定义和生命周期如何管理。
- 用户要求方案完成后进行两轮自审：第一轮审产品完整性，第二轮审技术、故障边界和验收闭环。

## 已确认事实

- 当前深度分析入口以单条 `question` 创建新 Job，并通过 `sourceMessageID` 关联承载结果的 AI 消息。
- 当前 Conversation Tool 只暴露对话活动和 intent 元数据，不返回历史消息原文。
- Agent 已有持久化 Job、Checkpoint、Result、Evidence、Message、Scheduler 和冷启动恢复链路。
- Agent Result 已持久化结构化 claims、evidence IDs、coverage、requested deliverables 等信息，可作为追问上下文来源；原问题保存在关联 `HoloAgentJob.userQuestion`，不在 Result 内。
- `HoloAgentStartRequest`、`HoloAgentJob` 当前只有 `sourceMessageID`，没有 parent job、parent result、thread 或 lineage 字段。
- `HoloLocalAgentRuntime.startAnalysisJob` 会根据当前短问句重新解析时间、任务画像和必要工具；若直接输入“为什么”“第二点呢”，缺少上一轮语义锚点。
- 当前 Job 内部的 `conversationState` 只服务同一 Job 的多轮推理与恢复；它已经支持历史工具结果和 Evidence ID 复用，但 Job 完成后没有被下一 Job 继承。
- `ConversationCoordinator` 仅根据当前输入的 intent 判断是否进入 Agent，普通短追问没有确定性的“承接上一 Agent 结果”路由。
- Chat 消息已有 `parentMessageId`，但当前 Agent 启动只把 AI 占位消息 ID 写入 `sourceMessageID`；没有把本轮用户消息、上一份 Agent 结果与新 Job 串成可追溯 lineage。
- Agent 卡片在 Chat 中只持久化展示态 `HoloRenderedAgentResult`；可复核的完整 Result/Evidence 仍应从 Agent Store 经 Job 关联读取，不能把展示 JSON 当事实源。
- 当前确定性 Eval 明确不调用 LLM，不能覆盖真实模型规划、工具选择、协议遵守和最终表达。
- 当前 Agent 可靠性遥测主要保存在设备本地环形仓库。
- 当前生产健康接口正常，但公开 release identity 返回 unknown，无法证明线上准确版本。
- 终态 Job 默认完成后保留 30 天、失败后保留 7 天，并级联删除 Checkpoint 和 Result；当前清理器不知道 parent/child lineage。连续追问上线前必须让仍被子 Job 引用的父 Job/Result 不被提前清理，或把必要事实快照固化到子 Job。
- 现有类型化 `HoloMetricSemantic` 已是工具侧唯一语义入口，包含 domain/dataset/measure/operation/valueRole/dimension 等；P0-2 应在它上面补稳定身份，不应重建第二套指标目录。
- 当前 Verifier 为兼容动态指标，允许 claim 与 evidence 的 metricKey 只要“同域 token 重叠”就通过；这能兼容旧链路，但边界过宽，仍可能把同域不同口径的指标误认为同一指标。
- 现有真机/灰度清单已经给出生命周期门槛：内部至少 2 台 iOS 26 真机、30 个主动 Job、2–3 天；第一档至少 10 名用户或 100 个有效 Job、3 天，完成/恢复完成率均 ≥95%，crash-free sessions ≥99.5%。P0-3 应复用这些门槛，不另造一套数字。
- 当前 Eval 规模已达到 165+，但注释明确“全部确定性、不调用 LLM”；因此缺口不是继续堆同类 fixture，而是增加真实模型轨迹、录制回放和真机生命周期三层门禁。
- 后端 `verify-production-release.sh` 已会拒绝 commit/sourceDigest/buildTime 缺失或 unknown；但 `deploy.sh` 公网验收只检查响应里是否含服务名，未调用这套严格校验，所以部署可以在 identity unknown 时仍显示“部署成功”。

## 初步判断

- 连续追问不是简单地“多带几条聊天记录”；正确方向是建立结构化 `AgentConversationWorkspace`，只携带上一轮已验证结论、证据引用、权威时间范围、未完成问题和用户纠正。
- 连续追问应分三类：解释已有结果、基于已有结果继续计算、改变问题范围后重新规划。
- 原 Job 已完成后不应直接改写或续跑；应创建新 Job，并通过 parent/lineage 关联上一 Result，保证历史可审计。
- 澄清请求仍属于同一 Job 的恢复，不应和“完成后的追问”混为一套语义。
- 连续追问复杂度属于“中等架构改造”，不是重做 Runtime：存储和恢复底座可复用，主要新增 lineage、上下文解析、追问路由、Evidence 复用与 UI/测试闭环。
- 必须区分“同一 Job 内模型多轮”“等待用户澄清后恢复同一 Job”“已完成结果上的用户追问新 Job”三种生命周期，否则会破坏状态与审计。
- 连续追问的作用域应由消息邻接关系和明确的 parent job/result 决定，不能读取“全局最后一个 Agent 结果”，否则跨主题聊天会串错上下文。
- 指标语义收口的正确边界是“别名只在输入解析阶段出现，进入 Tool → Evidence → Claim → Verifier 后只认 canonical identity”；旧数据继续走显式兼容分支并记录命中率。
- 生产身份问题的根治点不是再加一个状态接口，而是让部署成功条件与严格发布证明使用同一脚本；unknown 必须使发布失败，并保留上一个可证实版本。
- 既有 ADR 已规定 Job 是时间口径唯一真相源、Evidence Ledger 是数值血缘真相源、Verifier 决定可交付性；连续追问只能继承这些结构化真相，不能把聊天文字或 Renderer 展示结果升级成新真相源。
- “一个直接父 Result”必须转化为用户可理解且系统可确定的产品关系：自然相邻追问可自动锚定，历史或分支追问应通过卡片动作显式锚定；一旦创建 child Job，parent Result ID 必须冻结落盘，不能在恢复时重新猜。
- 连续追问 Context 应按“唯一候选父结果 → 闭集 relation → 继承策略 → 最小结构化 Context → child Job”编译，每一轮从 canonical stores 重建，不递归追加整段历史。
- Holo 过去已经发生过 Router 被聊天长上下文中的 backlog/thoughts/trends 污染的问题；既有结论是 intent recognition 必须保持最小 Router context，profile 只能辅助消歧、不能覆盖用户当前明确指令。连续追问必须延续这个边界，不能为了识别追问重新把长聊天塞回 Router。
- 用户更关注可感知的端到端 Use Case；最终方案应把每一次输入、界面反馈、内部 relation、是否复用证据、是否重查数据和失败时展示逐步写清，不能只列模型字段。
- 当前 `AgentDeepAnalysisCard` 整张卡只有一个点击行为“查看完整分析”，没有继续追问、纠正口径或绑定历史结果的入口。
- 当前 `AgentDeepAnalysisDetailSheet` 只接收 `HoloRenderedAgentResult`，展示结论、建议、观察、覆盖和依据；没有 lineage、父结果、沿用/重查状态，也没有从详情页继续追问的动作。
- 当前 `ChatInputView` 是单一 TextField + 语音 + 发送/停止，没有显示“当前正在基于哪份分析继续”的上下文锚定条。因此若只做后台隐式关联，用户无法发现或纠正系统绑定错了哪份 Result。
- 当前 Chat 消息链已有 `assistant.parentMessageId → user message ID`，且 Agent 卡片通过 `message.agentResult` 渲染；产品方案可以复用消息 ID 和卡片，不需要新建独立 Agent 页面。
- 当前 Chat 的“会话边界”只是消息加载层按 4 小时间隔切分；它不是持久化的 Agent 分析线程。自然自动承接可以限定在当前会话和相邻结果，显式从历史卡片继续则必须依靠 Result/Job ID，不能依赖这 4 小时规则。
- `HoloAgentResultStore` 已保证同一 `jobID` 只保留一条 canonical Result；Result ID 和 Job ID 可以定义 A/B 结果，不需要通过内容相似度判断。
- 当前 Result 清理由 Job 更新时间和 30/7 天保留期驱动，并不了解子 Job 引用；完整方案必须给 lineage ancestor 做引用保护，避免有效 child Result 的父证据被级联删除。
- 当前 Runtime 在 `startAnalysisJob` 中依次注入长期记忆、AgentPolicyContext、AnswerContract 和当前用户问题；连续追问 Context 应作为独立、类型化的系统消息插入 AnswerContract 之前，并保持记忆/偏好/事实的权限边界。
- `HoloRenderedAgentResult` 当前有 question、scope、Evidence 摘要等展示字段，但没有 canonical resultID/jobID/lineage。Chat 卡片若要精确继续历史分析，需要增加最小的可持久化 `continuation` 展示元数据，不能拿标题或问题文本反查。
- 当前 `ConversationCoordinator` 在调用 Router 后才知道是否进入 Agent；Router 请求只包含最小 intent context + 当前输入。连续追问不能把父 Result 直接塞进这条通用 Router，而应先由本地 Anchor Resolver 产生一个闭集候选信封，再让 Router 只判断 `followUpRelation` 或直接走确定性短指代规则。
- 执行型 intent 已在 Coordinator 中和 Agent 路由明确分开；即便输入栏带有显式追问锚点，记账、建任务、删除等执行动作也必须优先脱离分析 Context，继续走确认/执行链路。
- 当前用户上下文构建器明确区分 `.intentRecognition` 与 `.chat`，前者是最小上下文。新设计应增加专用 `followUpRouting` 或独立 Resolver 输入，而不是复用 `.chat` 长上下文。
- 当前 normalDeep 是累计 80K input token / 12 轮，系统消息会随轮次重复发送；继承 Context 不能按总预算比例无限放大。P0 应设独立小预算（建议渲染后约 1.5K token、最多 5 条相关 claim / 12 条脱敏 Evidence 摘要），超出时按目标相关性确定性裁剪。
- Evidence 已区分完整 `excerpt` 与可发给模型的 `redactedExcerpt`，并有 sensitivity。Follow-up Context 只能渲染 `redactedExcerpt`；完整 excerpt 继续只在本地 Verifier 使用。
- 现有 `HoloAgentInputSnapshot` 尚未包含 lineage/context digest。child Job 的恢复身份必须把 parentResultID、relation、context snapshot digest 和有效时间范围纳入 stable hash，避免冷启动后上下文改变却继续旧 checkpoint。

## 两轮 Review 后收口

- Chat 需要新增 optional `agentInteractionJSON`，只保存确认/启动状态；canonical parent/child 仍在 Agent Store，避免重复事实真相源。
- child Snapshot 必须复制最小 verified assertion payload，不能只留 selected IDs；Evidence 正文仍留在统一 Ledger。
- Swift actor 在跨 Store `await` 时可重入；child 创建和 cleanup 需要非重入 transaction gate、持久化 journal 和启动前滚。
- 当前 JSON Store 的 delete-then-move fallback 存在主文件缺失窗口；实施前需加入 last-known-good 恢复。
- 历史卡片可用性必须批量查询，Store 读失败与“结果不存在”必须是不同状态。
- 跨领域联合计算默认重查全部参与领域，不能把父领域旧快照与新领域当前快照拼接。
- 自由文本 `redactedExcerpt` 仍是不可信数据，必须做 Prompt data block 隔离和转义。
- CloudKit 只同步展示 JSON、本机无 canonical Agent Store 时只能“在这台设备重新分析”。
- 旧 Result 没有冻结 presentationOrder 时不能猜“第二点”；新 Result 必须保存稳定展示顺序。
- 方案两轮 Review 已完成，当前无待核验的连续追问 P0 设计项；实施仍需按 DoD 完成代码、生产和真机证明。

## 相关资源

- `docs/standards/Holo-Agent研发与验收规范.md`
- `docs/_common/plans/2026-07-26-Holo-Agent统一答案展示架构ADR.md`
- `docs/_common/plans/2026-07-19-Holo-Agent真机与灰度验收清单.md`
- `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentAnalysisService.swift`
- `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloLocalAgentRuntime.swift`
- `Holo/Holo APP/Holo/Holo/Services/AI/Agent/HoloAgentScheduler.swift`
- `Holo/Holo APP/Holo/Holo/Services/AI/Agent/Tools/HoloConversationTool.swift`

## 外部资料

- 本轮未使用外部网页资料。
