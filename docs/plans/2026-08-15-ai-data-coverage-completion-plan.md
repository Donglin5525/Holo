# AI 数据读取补全方案

- 日期：2026-08-15
- 状态：第一批实施中（东林已批准）
- 背景：全量审计「数据存在但 AI 读不到」的缺口后制定，审计结论见对话记录；本方案解决全部七类缺口 + 两个顺手项。

## 已确认决策（东林拍板）

| 决策点 | 结论 |
|---|---|
| 打卡备注（HabitRecord.note） | 全链路打通：手动输入 UI + AI 写入 + 三处 AI 读取 |
| 账单周期 | 口径对齐：AI 跟随全局记账周期设置 + 信用卡事实注入 |
| 纪念日 | 轻量注入：聊天上下文 + 洞察生活事件，不加 Agent 工具 |
| 顺手小项 | 两个都做：删 Goal.source 恒真防御（根治删字段）+ 实现 ✅反向定位 |

## 第一批：纯客户端（无需后端发版）

### P0-1 想法趋势假数据修复
`ThoughtAnalysisContextBuilder.swift` 的 buildDailyThoughtTrend 用「总数÷天数」伪造趋势，替换为 `ThoughtRepository.getThoughtCountByDay`（yyyy-MM-dd 键，格式一致）。无记录日补 0，保留 31 天上限。审计确认仅此一处假数据。

### P0-2 目标字段补全
`HoloGoalToolRecord` 加 `summary`/`motivation`（optional），excerpt 拼接加「摘要/动机」（截 40 字）。

### P0-3 删除 Goal.source 恒真防御
`"suggestion"` 从未写入，`isUserCreated` 恒真。删字段 + 赋值 + 下游 guard（GoalMemorySignalBuilder）。

### P0-4 打卡备注全链路
- UI：数值记录弹层加备注框（限 100 字）；打卡习惯当日记录可补备注（接已有 updateRecord）
- AI 写入三处（体重/数值习惯/打卡）：`toggleCheckIn` 加 note 参数；原文从 IntentRouter 入口传入；note = 原话去掉习惯名与数值后剩余文本，trim >2 字才存、截 60 字（避免「打卡跑步」这类无信息量备注进上下文）
- AI 读取：HabitAnalysisContextBuilder（item 带近期备注 ≤3）、HealthInsightContextBuilder（习惯证据带 note）、HoloHabitDataSource.aggregate（近 14 天非空备注）

### P0-5 账单周期口径对齐
- 新增 FinanceAnalysisPeriodResolver：日期→记账周期起始日（FinancePeriodSettings + BillingCycleCalculator），三处共用
- FinanceAnalysisContextBuilder：月度分桶按周期起始日（label「M/d起」）；预算「当前自然月」比对换成记账周期区间
- HoloFinanceDataSource：快照加 creditCards（名称/账单日/还款日/额度，仅 hasBillingCycle）；「月」语义在财务数据源层换算（不动全工具共用的时间解析器，避免污染健康域）
- FlexibleQuery「本月」同规则

### P0-6 纪念日轻量注入
UserContextBuilder 加「## 临近纪念日」（未来 14 天，含 repeatYearly 换算）；MemoryInsightContextBuilder 生活事件加 collectAnniversaryEvents（module "anniversary"）。

### P0-7 ✅ 反向定位
想法详情页 ✅（taskMark 自带 taskId+displayText）可点击 → TodoTask.sourceTextSnippet 定位正文并滚动高亮；失败回退 displayText；皆失败不响应。

## 第二批：随知识树二期后端发版（实施前单独同步东林）
- P1-1 thought_organization v5：payload 加 `currentTopic:{title,confidence,reason}|null` 回读，后端 prompt 同步（需过护栏测试）
- P1-2 Topic.summary 综述（thought_topic_summary 新 purpose）+ P1-3 打标注入档案上下文：直接引用 `docs/thoughts/plans/2026-08-15-knowledge-tree-mainline-v1.md` §6 二期清单，不重复设计

## 明确不做
- richContentJSON 结构增强：content 纯文本已含 #标签/@引用 字面（RichContentSerializer 设计如此）
- 死字段清理：知识树三期已排期
- 洞察评分/对话原文进 Agent 工具：有意白名单设计

## 风险与约定
- 工作区有知识树 v1 等未提交改动：只碰本方案文件、每项独立编译、不自行提交
- 全部使用现有 CoreData 字段，无迁移
