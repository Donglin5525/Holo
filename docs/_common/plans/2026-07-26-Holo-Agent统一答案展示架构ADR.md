# ADR：Holo Agent 统一答案与展示架构

- 状态：已采纳，已实施
- 日期：2026-07-26
- 适用范围：所有 Agent 领域（财务、健康、习惯、任务、目标、观点、跨域）

## 产品问题

同一次分析目前存在三套彼此独立的解释：

1. Runtime / Tool 决定实际查询时间和数据；
2. Composer / Renderer 再次根据问题或 Evidence 猜时间、覆盖率和主结论；
3. 卡片与详情页根据松散的 `sections.kind` 再次猜哪些是建议、哪些应置顶。

因此会出现底层已查询 2026 年、界面却写“近 30 天”，财务事件记录被解释成 `132/365` 天覆盖不足，以及第一条建议被提升为大字、第二条建议留在卡片中的割裂结果。它们不是三个独立 UI Bug，而是答案语义缺少唯一真相源。

## 决策

### 1. Job 是时间口径的唯一真相源

Job 创建时冻结：

- `primaryTimeRange`
- `snapshotCutoffAt`
- baseline（如有）

Analysis Service 将它们封装为 `HoloAgentAnswerContext` 交给 Renderer。Renderer 和 UI 不再解析用户原话来推导时间，也不能用第一条 Evidence 的旧 label 覆盖 Job 范围。

### 2. 覆盖数字必须携带数据形态语义

`HoloDataCoverage` 必须声明：

- `eventRecords`：交易、任务、想法等事件；没有记录也是有效事实，禁止按日历天数判断完整度；
- `dailyObservations`：步数、睡眠等预期每天产生的数据；可以显示日度覆盖并给趋势边界；
- `currentSnapshot`：当前状态快照；不使用日历覆盖率。

覆盖文案、限制说明和交付前核验统一由 `HoloCoveragePresentationPolicy` 决定。其他层不得自行比较 ratio。

### 3. 建议是一级结构，不再是普通 Section

新结果包含类型化 `recommendations`：

- 稳定 ID
- 动作标题
- 解释正文
- 优先级
- 支撑 Evidence ID
- 与主范围不同时的独立 scope label

开场只提供简短答案概括；所有建议按同一组件、同一字号、同一顺序展示。禁止把第一条建议提升成开场正文，禁止 UI 根据 `sections.kind` 重新排序。`sections` 只保留事实和旧消息兼容。

### 4. 新旧结果在单一边界兼容

旧模型可能把“建议 1（高优先级）：标题。正文”塞进一个字符串。只允许 Renderer 的兼容适配器解析一次并转换为类型化 Recommendation；摘要卡和详情页只消费转换后的结构，不重复解析。

### 5. 跨时间范围必须显式

建议引用的 Evidence 时间范围若与主分析范围不同（例如年度分析引用本月预算），Recommendation 必须带 scope label，由卡片明确标注，不能无提示混入年度事实。

## 不变量

每份新 Agent 结果交付前必须满足：

1. `result.scope` 与 Job 权威时间一致；
2. 标题、直接答案和覆盖文案不得出现与主范围冲突的时间；
3. 事件型数据的 `coverageText` 必须为空；
4. 用户要求建议时，`recommendations` 非空且顺序稳定；
5. 同一条建议只能有一个展示来源；
6. UI 不根据自然语言正文推断建议层级；
7. 历史统计只使用 `snapshotCutoffAt` 之前已发生的数据。

## 被否决的方案

- 分别替换“近 30 天”和 `132/365` 文案：无法阻止下一个领域或下一次查询再次产生冲突。
- 只调整 SwiftUI 字号和间距：第一条建议仍会因数据结构被提升，视觉问题会复发。
- 继续让 Renderer 解析问题中的年份：会形成与 Time Semantic Resolver 并行的第二套时间解析器。
- 对财务单独关闭覆盖提示：无法覆盖任务、观点等其他事件型数据。

## 代价与后续

- 新旧消息会短期共存；旧消息通过兼容适配器展示，新消息使用完整类型化结构。
- 需要为时间、覆盖语义、建议列表和 UI Narrative Model 建立联合回归，而不是只测单个工具。
- 后续 LLM 输出协议可以直接产出结构化建议元数据；在此之前兼容适配器是唯一过渡入口。
