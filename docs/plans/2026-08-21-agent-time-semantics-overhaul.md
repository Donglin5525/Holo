# Agent 时间语义彻底改造（三层解析 + 显式披露 + 可换范围）

> 日期：2026-08-21
> 起因：用户问「近半年我的工资收入趋势是什么」，实际只按「最近30天」取数（7/23–8/21），
> 按月分组只切出 7、8 两个桶，回答与数据依据均只覆盖两个月。
> 东林拍板：治本方案，做扎实，交付前自校验一轮。

## 1. 根因（链路全查证）

```
用户原话「近半年…」
  → HoloAgentTimeSemanticResolver.resolve()   词表枚举：本月/上月/本周/上周/今年/去年/近N天
      「近半年/近3个月/近一年/上上月」全部未命中 → 返回 nil
  → HoloAgentTimeSemanticExtended             季度/年初至今/月至今/工作日，也无「半年」族 → nil
  → job.timeRange = nil
  → AnswerContract prompt 告诉 LLM：「用户未明确指定时间，按工具默认范围」
      （用户其实指定了，是词典不认识；系统对 LLM 撒了谎）
  → HoloFinanceDataSource.queryRows：range 为 nil → 默认窗口 = 最近30天（其他模块 14 天）
  → 按月分组只有 7、8 两个桶 → 「趋势」只算两个月
```

三个系统性缺陷：
1. **枚举词表永远覆盖不了自然语言**（理解力问题）。
2. **解析失败静默降级**，LLM 与用户都不知道实际查的是哪个窗口（可见性问题）。
3. FollowUpRouter 认识「近半年」（判断换范围追问用），Runtime 预留了 `.changeScope` 分支，
   但真正干活的解析器不认识——系统内部自相矛盾。

## 2. 架构决策（三层金字塔 + 披露 + 可纠正）

原则：**理解交给会理解的，信任靠晒出来，不靠隔离。**

### L1 词典快车道（保留，零成本 100% 确定）
现有 `HoloAgentTimeSemanticResolver` 词表不动：本月/上月/本周/上周/今年/去年/近一周/近一个月/最近N天。
命中即用，LLM 不可覆盖（`requestWithJobScope` 现有优先级保留）。

### L2 通用组合规则（新增，本地确定性，覆盖「数量×单位」）
正则族：`（近|最近|过去）+（半|\d+）+（个）?（天|日|周|月|年）`
- 「近半年」→ 近183天（今天-6个日历月+1天 ～ 明天0点）；「近3个月/近三个月/最近3个月」同理
- 「近一年」→ 近365天；「近2周」→ 近14天；「近90天」由现有「最近N天」词表先命中
- 中文数字（三、六、十二）先归一为阿拉伯数字（复用现有 normalizeChineseYearAndMonth 思路）
- 只接「近/最近/过去」前缀，不接「前」（「前一个月」词表已映射上一自然月，避免语义冲突）
- 优先级：词表 > 通用族 > explicitMonth > explicitYear（现有顺序中插入）
- matchedText 透传（「近半年」），供卡片披露「来自你的『近半年』」

### L3 LLM 解析兜底（新增，治任何 L1/L2 覆盖不到的表达）
「春天那会儿」「上上个月」「发年终奖之后」这类表达只有 LLM 能解。
机制（全部走现有协议，零额外 LLM 调用）：
- `HoloAgentAnswerRequestPolicy.promptInstruction` else 分支重写：
  不再说「用户未明确指定时间，按工具默认范围」，改为：
  「用户原话可能含时间表达但系统未能确定性解析。今天是 {date}。请先解析用户原话的时间语义：
   若确有时间范围，必须填入每个 toolRequest.timeRange（label 含原话词，start/end 为 epoch 秒），
   并在 final_claims 披露解析结果；若原话确无时间语义，按工具默认范围并在答案中明确披露。」
- ResponseParser 现有 `normalizeTimeRange` 只接受数值时间戳，天然过滤 ISO 字符串——保留。
- Runtime 在解析 LLM 输出后：`job.timeRange == nil` 且 toolRequests 携带合法窗口 →
  **提升为 job 权威范围**（provenance = .modelResolved），并向对话追加一条系统消息
  更新 AnswerContract 的权威时间（后续轮次工具与总结都以它为准）。

### 校验护栏（新增，LLM 窗口不是想填什么就什么）
`HoloAgentModelTimeRangePolicy`（新）：
- start < end，均为数值时间戳（Parser 已保证）
- end ≤ 明天 0 点（未来截断；历史事实策略已有二次截断）
- 跨度 ≤ 731 天（2 年，与数据集 maximumRangeDays=366 双保险；超限由动态查询校验器报 rangeTooLarge）
- start ≥ 今天 − 5 年
- 任一不满足 → 丢弃 LLM 窗口 → 按默认窗口执行 + 披露「未能识别时间范围，按最近30天查询」

### 显式披露（卡片永远可见）
`HoloAgentJob` 增加 `timeRangeProvenance`（lexical / rule / modelResolved / override / default），随
`HoloAgentResult` → Renderer → `HoloRenderedAnswerScope` 透传，卡片 scope 位展示：
- 词典/规则命中：「近半年（2026年3月–8月）· 截至8月21日」
- LLM 解析：「2026年3月–8月 · 按你的「近半年」 · 截至8月21日」
- 用户点选：「近1年 · 你选择的范围」
- 默认窗口：「最近30天 · 未指定时间范围」——**静默降级从此消失**

### 可点换范围（复用 .changeScope 语义）
- 卡片 scope 胶囊可点 → Menu 快捷档：近30天 / 近3个月 / 近半年 / 近1年
- `HoloAgentContinuationRequest` 增加 `overrideTimeRange: HoloAgentTimeRange?`
- Runtime `.changeScope` 分支：优先采用 override（provenance = .override），绕开解析层，确定性 100%
- 走现有 continuation 链路（父结果锚定、lineage、额度），不新建机制

## 3. 改动清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | HoloAgentTimeSemanticResolver.swift | 新增通用组合正则族 resolveRelativeSpan（L2） |
| 2 | HoloAgentJobModels.swift | HoloAgentJob + timeRangeProvenance（enum HoloAgentTimeRangeProvenance + matchedText） |
| 3 | HoloAgentOutputModels.swift | promptInstruction else 分支重写 + 有 provenance 时的依据披露 |
| 4 | HoloLocalAgentRuntime.swift | LLM 窗口提升 + 护栏校验 + 追加权威时间更新消息；.changeScope 用 override |
| 5 | 新文件 HoloAgentModelTimeRangePolicy.swift | 护栏校验 |
| 6 | HoloAgentContinuationModels.swift | HoloAgentContinuationRequest + overrideTimeRange |
| 7 | HoloAgentResultModels.swift / Renderer | scope 透传 provenance + matchedText，displayLabel 分型文案 |
| 8 | HoloFinanceDataSource.swift 等默认窗口 | nil→默认窗口的 label 显式化（「最近30天」而非「本期」），仅展示层 |
| 9 | AgentDeepAnalysisCard.swift | scope 胶囊可点 + Menu 四档 |
| 10 | ChatViewModel.swift | 换范围重查入口（构造 changeScope continuation + override） |

不改后端：agentResponseValidator 的 normalizeTimeRange 对合法 {label,start,end} 放行；
后端系统模板「timeRange 是权威范围不得擅自改」约束的是有权威范围时，与 L3 指令不冲突。

## 4. 边界与取舍
- 「上上个月」「前年」等：L2 不做，交给 L3 兜底（LLM 能解）。
- 换范围 v1 只做四档快捷，不做自定义日期区间（避免新 UI 组件，观察使用率再议）。
- 各数据源默认窗口不一致（财务30天/其余14天）本期不改行为，只改披露文案；统一窗口另议。
- maximumRangeDays 超限（如「近三年工资」）：动态查询报 rangeTooLarge → 工具错误如实透出，
  不静默截断（错误可见优于数据残缺）。

## 5. 测试与自校验
- 单测（新增 HoloAgentTimeSemanticsTests）：
  - L2：「近半年/近3个月/近三个月/最近半年/过去半年/近一年/近2周」→ 窗口断言（固定 referenceDate）
  - L2 不误伤：「2026年7月」「本月」「最近7天」「近半年我的工资收入趋势」
  - 护栏：start≥end / 跨度>731天 / 未来窗口 → 拒绝
  - changeScope override 优先于解析
- 自校验走查（按 self-review 惯例）：问句→解析→prompt 注入→窗口提升→卡片披露→点换范围→重查，逐环节核对
- 编译：xcodebuild 全量编译通过

## 6. 发版说明
纯 iOS 客户端改动，**无需后端发版**。
