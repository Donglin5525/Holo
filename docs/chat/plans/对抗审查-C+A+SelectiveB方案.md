# 对抗性审查：C+A+Selective B 方案

> 审查人：Claude (基于原始方案作者视角)
> 审查对象：GPT 生成的「C+A 打底，Selective B 兜底」方案
> 审查日期：2026-05-04

---

## 一、总体评价

这份方案在工程完整度上远超我最初的四方案对比。特别是 `categoryCandidate` 字段设计、`dueDateText` 保留自然语言交代码解析、Validator 校验层、分阶段实施计划——这些都是我在原始方案中没有充分考虑的好想法。

但方案存在一个核心矛盾：**Selective B 作为方案的核心差异化卖点，实际上并不解决它声称要解决的问题。**

---

## 二、致命问题：Selective B 的存在必要性

### 2.1 动机案例不支持 Selective B

整份方案的起点是"家政52"这个科目幻觉案例。但看方案自己给出的期望处理流程：

```
家政52
  → 第一轮：categoryCandidate: "家政", primaryCategory: null, subCategory: null
  → Validator：科目为空，标记 invalidCategory
  → 执行：进入"待确认"
```

**这里没有 Selective B 任何事。** 科目表中不存在"家政"，无论调几次 LLM 都不存在。最终结果就是"待确认"。

方案中 Section 9.3 给 Selective B 的示例输入也是"家政52"，但二次 prompt 的输出仍然是 `primaryCategory: null, subCategory: null`。**二次调用没有任何收益，白浪费了一次 API 调用和延迟。**

### 2.2 逐条审查 Selective B 的 9 个触发条件

| 触发条件 | C+A 能否解决 | Selective B 能否改善 | 判定 |
|---------|-------------|--------------------|----|
| confidence < 0.85 | 更强模型 + 精简 prompt → 置信度普遍提升 | 二次 prompt 用同样模型，置信度未必更高 | 疑似无效 |
| intent == unknown | 更强模型减少 unknown | 专用 prompt 可能帮助，但 unknown 意味着连分类都做不到，专用 prompt 如何选？ | 逻辑矛盾 |
| required field missing | few-shot + 精简字段减少遗漏 | 有价值——提醒模型补字段 | ✅ 唯一有价值的场景 |
| amount conflict | 代码预提取 + Validator | 二次 prompt 不太可能修正数字识别 | 疑似无效 |
| invalid category | 科目表内没有就是没有 | 无法无中生有 | 无效 |
| categoryCandidate exists but category is null | 同上，这是正常的"待确认" | 无法改善 | 无效 |
| queryAnalysis period/domain ambiguous | 更强模型 + 更好的 prompt | 有价值——专用分析 prompt 可细化 | ✅ 有价值 |
| multi-action item partially invalid | 更强模型减少拆分错误 | 有价值——逐个 item 精修 | ⚠️ 有价值但触发频率低 |
| JSON decoded but business validation failed | prompt/JSON Mode 减少这类问题 | 取决于失败原因 | 不确定 |

**结论：9 个触发条件中，只有 2-3 个真正能从 Selective B 中受益，而且这些场景的触发频率很低。**

### 2.3 Selective B 的自相矛盾

方案 Section 3.1 论证"Stage 1 分错会导致不可恢复错误"来反对全量 B。但 Selective B 也面临同样的问题：

- 如果第一轮把 intent 分错了（比如把 query_analysis 识别成了 record_expense），Selective B 只会用 record_expense 的专用 prompt 去修正，反而巩固了错误。
- Selective B 不能纠正 intent 级别的错误，只能在正确 intent 下修正字段级别的遗漏。

这和方案自己的论点是矛盾的。

---

## 三、工程复杂度问题

### 3.1 新增 6 个模块，比全量 B 更复杂

方案新增了：

```
AIInputPreprocessor.swift
NLDateParser.swift
AIParseBatchValidator.swift
SelectiveRefinementService.swift
IntentSpecificPromptFactory.swift
AIResponseTextBuilder.swift
```

作为对比，一个干净的两阶段 pipeline 只需要：

```
NLDateParser.swift           (共享)
AIParseBatchValidator.swift  (共享)
AIResponseTextBuilder.swift  (共享)
```

**Selective B 的"按需调用"看似更轻量，实际上需要 SelectiveRefinementService + IntentSpecificPromptFactory 两个额外模块来管理"什么时候调"和"调哪个 prompt"，这比全量 B 更复杂。**

全量 B 的逻辑是确定性的：每个请求都走 Stage 1 → Stage 2，没有分支判断。Selective B 引入了非确定性：根据 9 个条件判断是否触发、选哪个专用 prompt、如何合并结果——这些分支逻辑比全量 B 的线性流更难测试和调试。

### 3.2 LLM 调用日志复杂化

方案自己提到了这个问题（Section 11.2）：

> 如果二次调用发生，建议扩展日志结构支持多条调用记录

这意味着 `LLMCallLog` 模型需要从"一次请求一次日志"变成"一次用户输入可能有多条日志"。这会影响：
- 日志展示 UI（ChatLogView 当前是一条消息一条日志）
- 调试体验（哪个结果来自哪次调用？）
- 错误追踪（第一次对了但第二次改错了怎么办？）

### 3.3 多动作 + Selective B 的组合爆炸

用户输入 "午饭35，家政52，提醒我明天买牛奶"：

- 3 个 items
- 其中"家政52"触发 invalidCategory
- SelectiveRefinementService 只重跑这一个 item
- 但 Selective B 返回的结果仍需经过 Validator
- 如果 Validator 仍然不通过，是保留第一轮结果还是进入待确认？

方案 Section 14.3 给了策略，但这个"第一轮→Validator→Selective B→Validator→合并→执行"的管道比看起来更复杂。

---

## 四、方案中值得肯定的设计

批判归批判，以下是方案中比我的原始设计更好的地方：

### 4.1 categoryCandidate 字段（强烈同意）

这是我最喜欢的设计。让 LLM 输出一个 `categoryCandidate` 保留用户原始语义，而 `primaryCategory/subCategory` 只允许填科目表中存在的值。这样：

- 不匹配时不会丢失信息
- "待确认"卡片可以显示"家政"而不是空白
- 用户手动确认时有一个推荐起点

这个设计应该直接采纳，且它完全是 C+A 层面的改进，不依赖 Selective B。

### 4.2 dueDateText 而非 dueDate（同意）

让 LLM 输出 `dueDateText: "明天下午3点"`，代码解析为 `dueDate: "2026-05-05 15:00"`。这比我原方案"代码预处理时就算好日期注入上下文"更好——LLM 做语义理解（识别哪些是日期表达），代码做精确计算。

### 4.3 Validator 校验层（同意，但建议简化）

即使不做 Selective B，在执行前增加一层校验也是好实践。但建议第一版只做最关键的 3 项：

1. 科目白名单校验
2. 必填字段非空
3. amount 非负数

不需要完整的 `AIParseValidationIssueCode` 枚举。

### 4.4 分阶段实施（同意，建议调整）

5 个阶段的节奏是对的，但建议砍掉阶段 4-5（Selective B），把精力放在：

- 更充分的 few-shot examples（覆盖更多科目边界案例）
- NLDateParser 覆盖更多日期表达
- PromptManager 版本迁移更稳健

---

## 五、被方案忽略的替代路径

### 5.1 Embedding/Synonym 科目匹配

方案在审查问题中提到了但未展开：**能否用 embedding 或 synonym 映射替代 LLM 的科目判断？**

当前 `CategoryMatcherService` 已有 synonym 匹配能力。如果：

1. LLM 只输出 `categoryCandidate: "家政"` + `note: "家政"`
2. 代码层用 synonym 映射表匹配：`"家政" → "其他 > 社交"` 或新建"家政"作为自定义子分类
3. 用户可以学习/自定义映射

这样科目匹配完全不依赖 LLM 的判断力，而是依赖一个可控的映射表。比 Selective B 更确定、更快速、更可维护。

### 5.2 更激进的 prompt 精简

方案保留了完整的科目表在 prompt 中。但既然代码层有 `CategoryMatcherService`，prompt 中是否可以只传一级科目（9 个），二级科目完全交给代码 synonym 匹配？

这样 prompt 可以再砍 ~30 行，模型负担更轻。

### 5.3 用户学习机制

"家政"出现了 3 次都被归入"待确认"，这其实是信号：用户频繁使用这个分类，应该在用户确认后自动学习映射。这比任何 LLM 方案都能更好地解决长尾科目问题。

---

## 六、结论与建议

### 方案评级

| 维度 | 评分 | 说明 |
|------|------|------|
| 问题诊断 | 9/10 | 准确、全面 |
| C 阶段设计 | 9/10 | 模型升级 + JSON Mode，无争议 |
| A 阶段设计 | 8/10 | categoryCandidate、dueDateText、Validator 都是好的 |
| Selective B 设计 | 4/10 | 核心差异化卖点没有解决它声称要解决的问题 |
| 工程复杂度控制 | 5/10 | 6 个新模块，比全量 B 更复杂 |
| 实施计划 | 8/10 | 分阶段合理，但应砍掉 Selective B 阶段 |
| 测试设计 | 8/10 | 覆盖面好 |

### 最终建议

**采纳 C + A，搁置 Selective B。**

具体来说：

1. **直接采纳**：
   - 阶段 1：升级模型 + JSON Mode
   - 阶段 2：NLDateParser + AIResponseTextBuilder + 简化版 Validator
   - 阶段 3：重写主 prompt（采纳 categoryCandidate、dueDateText、按意图收敛字段、few-shot）

2. **不采纳**：
   - 阶段 4（Selective Refinement 框架）
   - 阶段 5（专用二次 prompt）
   - SelectiveRefinementService、IntentSpecificPromptFactory

3. **补充做**：
   - 科目 synonym 映射表扩充（"家政" → 已有最接近的分类）
   - 用户确认后自动学习分类映射
   - 考虑 prompt 中只传一级科目，二级科目完全交给代码

4. **作为未来观察指标**：
   - C+A 上线后，记录"字段缺失率"和"科目未匹配率"
   - 如果字段缺失率 > 5%，再考虑引入 Selective B 只处理 `required field missing` 这一个场景
   - 如果科目未匹配率 > 15%，优先扩充 synonym 映射表而非 Selective B

---

## 七、一句话总结

GPT 的方案在诊断和 C+A 设计上非常出色，但 Selective B 是一个"听起来很聪明但实际解决不了问题"的过度设计。C+A 本身已经足够解决当前的核心问题。如果 C+A 上线后仍有特定场景需要精修，再按需引入 Selective B 也不迟——那时候会有真实数据来指导触发条件设计，而不是提前预设 9 个可能无意义的条件。
