# 事实与设计依据

## 已核对

- 当前云端深度分析首轮以问题、工具目录和冻结任务构建消息，后续追加工具结果；个人档案和记忆数据集可以查询，但没有独立的任务相关个人处境摘要契约。
- 当前本地 agent_loop 默认版本为 25，已包含个人基线、财务多维深挖、历史观察、生活含义和数字表达要求。不能把“缺少一句深入分析指令”当作完整根因。
- 提示词包含至少三个维度、点破式标题等要求；它们是否造成泛化，需要真实失败报告对照验证，不能仅凭静态阅读定论。
- 现有快照默认近 180 天、每数据集上限 2000 行；新方案必须明确截断、缺失、时区和完整性。
- 已有结构化结论、证据、报告与反馈能力，应增量复用。
- 之前的智能化审计提出“理解处境 → 小行动 → 采用 → 回看”；当前实施状态需要按源码与生产分层核验。

## 待核对

- 财务字段、转账/退款/分期/多币种处理规则。
- 个性化、反馈和效果回看在云端正式路径的真实接入程度。
- 当前生产模型、有效 Prompt source/version/digest、实际延迟与费用。
- 用户确认试评材料为 Holo 数据，可直接录入 Holo；具体是否已导入、范围、问题及敏感字段尚未核对，不再默认要求外部表格路径。

## 第二轮核对

- HEAD 为 `6f7b03a389bb7a1f083d6e1c2f49bfb700e3b698`；本轮只有方案新增，未读生产有效配置。
- 财务云端行目录包含 date/amount/type/category/account/project/text；没有币种、退款原单、真实支付时刻精度、预算快照或合同承诺字段。不能仅因本地 FinanceTool 有预算/账户能力就认定云端也可调用。
- 云端查询目录明确不支持 cross_domain.aligned_analysis、expression、linearTrend、coverage；行样本每次最多 10 条。新增计算必须有确定性实现，不能在方案中伪装成已具备能力。
- `HoloFinanceDataSource.queryRows` 使用 `getTransactions`，而本地固定聚合 snapshot 使用 `getStatisticsTransactions`。已进一步核对 `FinanceRepository+Aggregation.swift:79-116`：前者明细语义含对账调整，后者通过 reconciliationExclusionPredicate 排除。因此是源码确认的口径差异；本轮未复现线上报告影响。
- `HoloOutcomeReviewStore` 已存在，记忆卡片有 recordExecution 调用；现结构没有冻结基线、计划与实际执行状态的完整区分。升级应扩展复用，不能另建不相通的回看系统，也不能声称当前已闭环。
- 10 月 14 日成本报告指出后台记忆/情境成本异常和重试问题；本次仅引用其成本隔离原则，不把旧费用或旧模型配置当作当前事实。
- 统一答案 ADR 要求 Job 冻结范围、事件数据不按自然日算覆盖率、建议类型化、单一展示兼容边界。

## 工具与路径记录

- 初次按 `HoloDefaultFinanceDataSource.swift` 文件名查找未命中；实际类型位于 `Tools/HoloFinanceDataSource.swift`，已定位并阅读。
- planning-with-files 的 session-catchup 对本目录执行完成，无待恢复输出。项目根的旧 planning 文件属于日历接入，保留原样。
- 初次按旧名字查 AnswerRenderer/AgentModels 文件未命中，已改用 rg --files 定位现有模型和展示文件；不将猜测路径列为已存在证据。

## 用户最新澄清

- 东林回复：“就是Holo的数据，可以直接录入Holo使用”。主验收改为 Holo 记录就绪 → 当前入口基线 → 同数据方法验证 → 候选接入后同入口复测。
- 是否已导入未被确认；不自动写入日用库。离线核算与消融保留为辅助，不以其结果冒充 App 效果。

## 外部方法来源

上一轮已查阅 Anthropic 官方上下文设计与 Agent 评测方法：精选相关背景，使用真实失败案例，事实核验与主观质量评价分开。引用保留在最终方案。
