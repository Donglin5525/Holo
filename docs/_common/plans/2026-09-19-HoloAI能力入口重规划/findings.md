# 事实记录

- 用户截图：Holo AI 对话页，键盘打开；输入框上方横排当前显示“深度分析”带下拉箭头、“今日状态”、“周期回放”、“规划目标”（最后一个部分被裁切）。前一条助理消息正在谈财务分析问题。
- 现有工作区有大量他人/并行未提交改动，包含 ChatView、ChatViewModel、AnalysisScenarioPanel 和能力模型；本轮仅写独立方案，不覆盖业务代码。
- 待核实：当前代码与 2026-09-17 目标共创计划的一致性、各胶囊真实动作与状态。
- `HoloAICapabilityProvider.persistentCapabilities` 当前固定四入口且“深度分析”第一；`QuickActionBar` 水平滚动、隐藏指示、每枚胶囊垂直内边距 6pt，无已验证的 44pt 命中区。首屏和报告空态另有能力教育。
- `AnalysisScenarioPanel` 现有跨域、财务、习惯、健康、任务、想法、目标复盘、长期模式 8 项；选后仅预填，需手动发送。长期模式实际是普通聊天，不占深度分析额度。面板在输入条上方内联展开，打开时收键盘。
- `ChatViewModel.resolveSendRoute` 只有“选中场景且文本等于预设问句”才确定性进深度分析；用户编辑预填后退回常规意图识别。显式选择可取消旧规划会话，此处应有用户可理解的交代。
- `handleCapabilityTap` 今日状态预填问题；周期回放弹周期 Sheet 后直接由独立协调器生成；规划目标走 `startGoalPlanning`，开 `goalWorkshopV1` 旗标时跳 `GoalWorkshopFlowView`，关旗标回旧流程。目标页在开旗标时有“一起想清楚/让 HoloAI 规划/手动创建”三选，可能形成重复 AI 入口。
- 2026-09-17 共创计划部分任务已在工作区打勾，但质量评测/真机/双端验收仍待办；`goalWorkshopV1` 本地默认 false，不能把当前代码等同生产已上线。旧方案文件开头“尚未开发”是早期快照，不能当现在事实。
- Today 页包含“今日概况”和进行中信息；这是“今日状态”作为常驻能力行入口的替代位置候选，不等于同一 AI 快问已完全覆盖。
- 报告 Tab 已将深度分析/周期回放归档与发起分离；空态 CTA 跳回对话并打开分析目录，不应再创建一套分析报告。
- Apple HIG：按钮命中区域一般至少 44x44pt；可调整高度的 sheet 可在中高度显示最相关内容并向上展开；水平滚动内容应让更多内容的存在可感知。来源分别为 https://developer.apple.com/design/human-interface-guidelines/buttons 、https://developer.apple.com/design/human-interface-guidelines/sheets 、https://developer.apple.com/design/human-interface-guidelines/scroll-views 。

## 2026-09-19 深度分析 Prompt 追加核对

- `docs/standards/PROMPT_GUIDELINES.md` 明确 Persona Preamble 是唯一人格真源；purpose Prompt 的任务方法与硬 JSON 契约分层；不宜用“增加更多禁止语句”替代方法论。后端默认路径优先，iOS `PromptManager` 是后备/DEBUG；修改须双端同步、版本递增、重建镜像并核对生产 Prompt。
- `docs/standards/Holo-Agent研发与验收规范.md` 明确“问题/时间/数据形态/数值/证据/可交付/运行状态”分层单一真相源；确定性计算与 Evidence 验证归代码，模型做工具选择及证据内解释；Prompt 不能补数据契约。查询不应强送建议，用户问原因必须回答原因。验收链为入口→Router→Job→Runtime→Tool→Evidence→Verifier→Renderer→UI/持久化，需对抗 fixture 和生产核验。
- 后端 `agent_loop` 当前 registry 为 v21，iOS `PromptManager.agentLoop` 显示 v17，需检查是否只是客户端后备版本滞后及当前完整模板差异。云端首轮深度分析在 `cloudAnalysisExecutor.js` 注入服务端 `agent_loop`；输出含 `narrativeSummary`/`keyInsight`，代码中已有保存/客户端读取迹象，不能直接复述旧记忆的“字段丢失”结论，须以当前链路核实。
- `defaultPrompts.json` 的 v21 方法论要求分析题第一轮近 90 天按月 groupBy、财务/睡眠至少覆盖 3 维等；可能把具体短窗或窄问题强推到广泛数据读取，是否真有冲突需核对 timeRange 权威与运行逻辑/测试后再定。
- 现代码证实更直接的云端冲突：`cloudAnalysisExecutor.js` 把通用 `agent_loop` Prompt 和云端目录拼一起；其基础 Prompt 自称“本地 Agent Loop/请求 iOS 本地工具”，并推荐 `spending_breakdown`、`budget_status`、`cross_domain.aligned_analysis`。但云端执行器主要支持快照 `dynamicPlan`、`snapshot_rows`、快照里存在的 statics；设备快照构造只含 `datasets`，没有这些预取 statics。未知固定 query 返回 `NOT_SUPPORTED_BY_CLOUD`。
- `cloudAnalysisQueryEngine.execute` 明确拒绝 baseline、expression/linearTrend/coverage；只执行基本聚合，groupBy 仅对 `type=field` 分组，`type=month/day/week` 通过 Validator 后会落到全量 all 桶；`plan.timeRange` 经 Validator 解析但云端 execute 不应用，只有模型自己显式写 `filters` 才会缩范围。这与 v21“首轮近90天按月基线”以及其他通用附录的比较口径不一致。结论是云端能力契约和 Prompt 不对齐，不宜只强化文案。
- 当前本地 `getPrompt("agent_loop")` 返回 default v21、拼装后 11226 字符；生产可能取 SQLite/managed 最新版本（`getPrompt` 优先数据库），本地 v21 不能视为线上有效 Prompt。iOS `PromptManager.agentLoop` 版本标记 v17，虽正文提到 v21，但来源/版本与后端仍须逐字段 diff；当前云端首轮实际使用后端 Prompt。
- 云端执行器已保存 `title/narrativeSummary/keyInsight/claims/reasoning/evidence`，iOS 客户端已解码叙事字段并渲染，不再是旧记忆所述“字段必丢”的当前状态；但 `CloudClaim` 只解码 displayText/type/confidence/interpretation/evidenceIDs，未保留 `metricAssertions`，端侧目前用内部 token 清理而非完整数字/Evidence 验证。
- 后端 `validateAgentLoopContent` 主要做结构规范化；`final_claims` 空 claims 也可通过并使云端任务完成（既有测试亦以空 claims 作为可完成 fixture），非空证据 ID 与指标值是否真的来自本次工具结果未在该层比对。后端证据池 metrics 按 metricKey 去重且仅保留最近 16 条，行样本最多 4 组；可能造成引用/展示不完整，应评估而非靠 Prompt 宣称可核验。
- 用户此轮所说“深度分析的提示词弱”紧跟入口规划，优先指向七个场景的**用户可见预填问题**。方案需要直接提供可替换的逐场景问句；同时说明不修云端契约时，写强问句会制造更高期待与更明显的失败。
- 七个现有可见问句多数用“深度分析一下我最近的……重点看……”泛域话术；没有明确用户要解决的决策、比较对象、结论形态。跨域问句只说“各类数据放一起”，目标复盘也只说进度和风险；这会弱化能力感知。应以可编辑的真实问题替换，不把后台方法学塞进用户输入。
- 已有 2026-09-15 离线 `warm-p0-blind-review.html`（29 条完成样本）是叙事字段保真对照材料，非用户打分结果。其 F01“为什么这个月又超支”示例明确说快照没按月拆、无预算却展示“超支”相关分析，说明时间和证据契约的重要性；不可把该样本当线上事故证明。可复用其冻结输入并补七场景专项 Eval。
- 官方 Anthropic Prompt 指南建议清晰任务、相关且多样的例子，并对复杂提示结构分段；这是通用设计参考，不替代 Holo 自己的真实模型 A/B 与数据契约。来源：https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/prompt-templates-and-variables 。OpenAI Evals API 提供数据集与 graders 机制，可借鉴“冻结样本 + 自动/人工评审”方法，实际首选仓库可复现脚本：https://platform.openai.com/docs/api-reference/evals/deleteRun 。
- 只读最小复现：快照两笔 `2026-08-10 ¥10` / `2026-09-10 ¥20`，请求 `timeRange=九月` 且 `groupBy=[month]`，云端 engine 回单个 `all=¥30`，把 8 月也计入；`validateAgentLoopContent` 对 `status=final_claims, claims=[]` 返回 `valid=true`。这是代码行为证明，不是线上用户样本。
- `HoloCloudEvidencePresenter.citedEvidence` 只按 claim 的 evidenceIDs 与回传 metricKey 匹配；引用缺失或不匹配时回退展示整个证据池。云端工具事件 ID 形如 `dynamic-<metricKey>`，回传证据 metricKey 不带前缀；若模型引用事件 ID，可能无法精准收敛，需统一 canonical evidence ID。
