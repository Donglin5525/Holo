# HoloAI 意图识别优化调整版方案：C+A 先落地，Selective B 暂缓

> 更新时间：2026-05-04  
> 用途：替代上一版「C+A 打底，Selective B 兜底」方案  
> 调整原因：吸收 GLM 对抗性审查意见，降低第一阶段工程复杂度，避免用二次 prompt 解决本应由代码、科目映射、待确认机制解决的问题

---

## 一、最终结论

本方案调整为：

```text
第一阶段：C + A
  C：升级模型 + JSON Mode
  A：代码分担确定性任务 + 精简主 prompt + 简化 Validator

第二阶段：科目匹配增强
  categoryCandidate
  synonym 映射扩充
  用户确认后学习映射
  高频未匹配词统计

第三阶段：观察真实数据
  只有当某类字段缺失长期存在时，再考虑极小范围 Selective B
```

不再把 Selective B 作为当前实现目标。

一句话概括：

> **先把单次调用做稳，把确定性逻辑交给代码，把长尾科目交给待确认和学习机制；不要提前引入二次 prompt 管线。**

---

## 二、为什么调整上一版方案

上一版方案提出：

```text
C+A 打底，Selective B 兜底
```

GLM 对抗性审查指出一个关键问题：**Selective B 不能解决它最初用来举例的问题。**

典型案例：

```text
家政52
```

如果科目表中不存在“家政”，那么正确结果应该是：

```json
{
  "intent": "record_expense",
  "confidence": 0.9,
  "extractedData": {
    "rawText": "家政52",
    "amount": "52",
    "note": "家政",
    "categoryCandidate": "家政",
    "primaryCategory": null,
    "subCategory": null
  }
}
```

此时二次 prompt 没有收益。无论再问 LLM 几次，“家政”都不会变成一个合法二级科目。正确处理方式是：

```text
记录金额和备注
分类进入待确认
卡片显示 categoryCandidate
用户确认后学习映射
```

因此，上一版中把 `invalidCategory`、`categoryCandidate exists but category is null` 等作为 Selective B 触发条件是不合理的。

---

## 三、目标架构

调整后的目标架构：

```text
用户输入
  ↓
AIInputPreprocessor
  - 金额候选提取
  - 明显多动作分隔符识别
  - 保留 rawText / segment 信息
  ↓
OpenAICompatibleProvider.parseUserInputBatch()
  - 使用更强模型
  - 使用 JSON Mode
  - 使用精简主 prompt
  ↓
AIParseBatchValidator
  - 必填字段校验
  - amount 合法性校验
  - 科目白名单校验
  - query + action 混合拦截
  ↓
NLDateParser / AnalysisPeriodResolver
  - 将 dueDateText / periodText 解析为确定日期
  ↓
AIResponseTextBuilder
  - 代码模板生成确认文案
  ↓
ConversationCoordinator
  ↓
IntentRouter
  ↓
CategoryMatcherService
  - exact
  - synonym
  - 用户学习映射
  - 待确认兜底
  ↓
Repository / Core Data
```

核心原则：

1. **LLM 负责语义理解，不负责最终裁决。**
2. **代码负责确定性计算和执行前校验。**
3. **科目不存在时不强行分类，进入待确认。**
4. **错误分类比待确认更糟糕。**
5. **Selective B 不进入第一阶段实现。**

---

## 四、第一阶段：C，升级模型 + JSON Mode

### 4.1 模型默认值

当前智谱默认模型：

```swift
case .zhipu: return "glm-4-flash"
```

建议改为：

```swift
case .zhipu: return "glm-4"
```

不建议第一步直接依赖 `glm-4-plus` 解决所有问题。`glm-4-plus` 可以作为高级设置项或后续推荐项，但结构性问题仍应由 prompt 精简和代码校验解决。

### 4.2 JSON Mode

在 `ChatCompletionRequest` 中增加：

```swift
struct ResponseFormat: Codable, Equatable {
    let type: String
}

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessageDTO]
    let temperature: Double?
    let maxTokens: Int?
    let stream: Bool?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}
```

仅在 `parseUserInputBatch()` 中传：

```swift
responseFormat: ResponseFormat(type: "json_object")
```

普通聊天、流式分析、洞察生成暂不启用，避免影响已有链路。

### 4.3 Provider 兼容

不同 OpenAI-compatible Provider 对 JSON Mode 的支持不一致，因此需要：

- 保留当前 `extractJSON(from:)` fallback
- 不支持 `response_format` 时自动降级
- 自定义 Provider 不强制开启
- 日志中记录当前是否启用 JSON Mode

---

## 五、第一阶段：A，代码分担确定性任务

### 5.1 新增模块

建议第一阶段新增或调整：

```text
Services/AI/AIInputPreprocessor.swift
Services/AI/NLDateParser.swift
Services/AI/AIParseBatchValidator.swift
Services/AI/AIResponseTextBuilder.swift
```

暂不新增：

```text
SelectiveRefinementService.swift
IntentSpecificPromptFactory.swift
```

### 5.2 `AIInputPreprocessor`

职责：

- 提取金额候选
- 识别明显多动作分隔符
- 保留原文片段
- 将预处理结果作为 system/context 注入给 LLM

示例：

```text
输入：午饭35，提醒我明天买牛奶
```

预处理结果：

```json
{
  "segments": [
    {
      "segmentId": "1",
      "rawText": "午饭35",
      "amountCandidate": "35"
    },
    {
      "segmentId": "2",
      "rawText": "提醒我明天买牛奶"
    }
  ]
}
```

注意：预处理只提供提示，不直接决定 intent。

### 5.3 `NLDateParser`

LLM 不再直接计算最终日期，而是输出：

```json
{
  "dueDateText": "明天下午3点"
}
```

代码解析为：

```text
2026-05-05 15:00
```

第一版支持：

- 今天 / 今日
- 明天 / 明日
- 后天
- 本周 / 下周
- 下周一至下周日
- 本月 X 号
- 上午 / 中午 / 下午 / 晚上 / 凌晨
- N 点 / N 点半

不建议第一版追求极端自然语言覆盖。无法解析时：

```text
保留原始 dueDateText
不设置 dueDate
必要时提示用户确认
```

### 5.4 `AIParseBatchValidator`

上一版 Validator 设计偏重。调整后第一版只做 4 类校验：

1. **必填字段校验**
2. **金额合法性校验**
3. **科目白名单校验**
4. **query + action 混合拦截**

不需要第一版就设计完整 `AIParseValidationIssueCode` 枚举。

必填字段建议：

| Intent | 必填字段 |
|---|---|
| `record_expense` | `amount`, `note` |
| `record_income` | `amount`, `note` |
| `create_task` | `title` |
| `complete_task` | `taskKeyword` |
| `delete_task` | `taskKeyword` |
| `check_in` | `habitName` |
| `create_note` | `noteContent` |
| `record_weight` | `weight` |
| `query_analysis` | `analysisDomain`, `periodText` 或日期范围 |

Validator 的处理原则：

```text
字段缺失 → 澄清或不执行
金额非法 → 澄清或不执行
科目非法 → 清空科目，保留 categoryCandidate，进入待确认
query + action 混合 → 提示拆成两句
```

### 5.5 `AIResponseTextBuilder`

LLM 不再生成 `responseText`。

确认文案由代码模板生成：

```text
已记录支出：35 元，午饭。
已记录支出：52 元，家政，分类待确认。
已创建任务：买牛奶，截止：明天。
已完成任务：买牛奶。
```

好处：

- 稳定
- 低成本
- 多动作聚合一致
- 不受模型语气漂移影响

---

## 六、主 Prompt 调整

### 6.1 主 prompt 的新定位

主 prompt 从“全能执行器”调整为：

```text
结构化意图识别器
```

它负责：

- 判断 `mode`
- 拆分 `items`
- 判断 `intent`
- 提取当前 intent 必需字段
- 给出 `confidence`
- 保留 `rawText`

它不负责：

- 生成回复文案
- 计算最终日期
- 编造科目
- 输出所有 intent 的全部字段
- 决定最终是否可执行

### 6.2 通用输出格式

```json
{
  "mode": "single_action",
  "items": [
    {
      "id": "1",
      "intent": "record_expense",
      "confidence": 0.92,
      "extractedData": {
        "rawText": "家政52",
        "amount": "52",
        "note": "家政",
        "categoryCandidate": "家政",
        "primaryCategory": null,
        "subCategory": null
      }
    }
  ],
  "needsClarification": false,
  "clarificationQuestion": null,
  "fallbackResponseText": null
}
```

### 6.3 字段按 intent 收敛

#### 记账：`record_expense` / `record_income`

```json
{
  "rawText": "午饭35",
  "amount": "35",
  "note": "午饭",
  "categoryCandidate": "午饭",
  "primaryCategory": "餐饮",
  "subCategory": "午餐"
}
```

#### 创建任务：`create_task`

```json
{
  "rawText": "提醒我明天买牛奶",
  "title": "买牛奶",
  "dueDateText": "明天",
  "priority": "1"
}
```

#### 完成 / 删除任务

```json
{
  "rawText": "完成买牛奶",
  "taskKeyword": "买牛奶"
}
```

#### 笔记

```json
{
  "rawText": "记一下今天状态很好",
  "noteContent": "今天状态很好"
}
```

#### 习惯打卡

```json
{
  "rawText": "跑步打卡5公里",
  "habitName": "跑步",
  "habitValue": "5"
}
```

#### 分析查询

```json
{
  "rawText": "分析上个月消费",
  "analysisDomain": "finance",
  "periodText": "上个月"
}
```

### 6.4 科目规则

必须写进主 prompt：

```text
科目只能从给定科目表选择。
如果找不到完全合适的二级科目，不要编造。
无法确定时 primaryCategory 和 subCategory 都填 null。
可以把用户原始消费语义放入 categoryCandidate。
```

few-shot 必须覆盖：

```text
午饭35 → 餐饮 / 午餐
打车去公司30 → 交通 / 打车
咖啡18 → 餐饮 / 咖啡
椅子扶手40 → 居住 / 家具
猫粮80 → 其他 / 宠物
家政52 → categoryCandidate: 家政, primaryCategory: null, subCategory: null
修鞋20 → categoryCandidate: 修鞋, primaryCategory: null, subCategory: null
```

### 6.5 是否保留完整二级科目表

GLM 建议考虑只传一级科目，把二级科目完全交给代码。

本方案建议折中：

```text
主 prompt 保留一级科目 + 高频二级科目示例
完整二级科目合法性由代码校验
prompt 明确：不确定二级科目就留空
```

原因：

- 完全移除二级科目会降低“午饭/打车/咖啡”等高频场景的直接命中率
- 保留完整二级科目又会让 prompt 变长
- 折中方案更适合第一阶段验证

---

## 七、科目匹配增强

### 7.1 `categoryCandidate`

这是本方案必须采纳的字段。

作用：

- 保留用户原始消费语义
- 待确认卡片可显示明确内容
- 为 synonym 和用户学习提供输入

示例：

```json
{
  "note": "家政",
  "categoryCandidate": "家政",
  "primaryCategory": null,
  "subCategory": null
}
```

### 7.2 `CategoryMatcherService` 优先级

建议调整匹配输入优先级：

```text
1. LLM 返回的合法 primaryCategory/subCategory
2. categoryCandidate
3. note
4. rawText
```

采纳分类的条件仍然必须严格：

```text
只接受 exact 或 synonym 命中
否则返回 nil
由调用方进入“待确认”
```

### 7.3 synonym 映射扩充

第一阶段优先扩充高频词：

```text
早饭 → 早餐
午饭 → 午餐
晚饭 → 晚餐
奶茶 → 饮品
网约车 → 打车
滴滴 → 打车
猫粮 → 宠物
狗粮 → 宠物
剪头发 → 理发
充话费 → 话费
```

对于“家政”这类当前没有明确合适分类的词，不建议硬塞到不准确分类。宁可待确认。

### 7.4 用户确认后学习映射

后续可增加：

```text
用户把“家政”手动改到某分类
  ↓
记录本地映射：家政 → 用户选择的分类
  ↓
下次自动命中 synonym/userMapping
```

建议数据结构：

```swift
struct CategoryUserMapping {
    let keyword: String
    let categoryId: UUID
    let transactionType: TransactionType
    let createdAt: Date
    let hitCount: Int
}
```

第一阶段可以先不做完整 UI，只在方案上预留。

### 7.5 高频未匹配词统计

记录：

```text
keyword
出现次数
最近出现时间
用户是否手动确认过
```

用于后续决定：

- 是否新增内置 synonym
- 是否新增默认科目
- 是否优化 prompt 示例

---

## 八、Selective B 的新定位

### 8.1 当前阶段不实现

本方案明确：

```text
不在第一阶段实现 SelectiveRefinementService
不新增 IntentSpecificPromptFactory
不新增专用二次 prompt
```

原因：

- 当前核心问题可由 C+A 解决
- 科目不存在时二次 prompt 无收益
- 触发条件容易过度设计
- 多动作 + 二次调用会增加日志、测试、取消和合并复杂度

### 8.2 未来何时考虑 Selective B

只有上线 C+A 后，有真实数据证明以下问题持续存在，才考虑引入：

```text
某个 intent 的 required field missing 率 > 5%
某个 intent 的字段提取错误率高且无法通过 prompt/few-shot 修复
query_analysis 的 period/domain 解析持续不稳
```

第一批可考虑的 Selective B 场景：

```text
create_task 缺 title
query_analysis 缺 analysisDomain 或 periodText
record_expense 缺 amount
```

不建议作为 Selective B 触发条件：

```text
invalidCategory
categoryCandidate exists but category is null
intent == unknown
amount conflict
普通 low confidence
```

这些更适合通过待确认、澄清、代码校验、synonym 或用户学习解决。

### 8.3 保留扩展口

虽然不实现 Selective B，但可以在 Validator 中保留轻量状态：

```swift
enum ValidationDecision {
    case executable
    case needsClarification(String)
    case executableWithWarnings
}
```

未来如果需要 refinement，可再新增：

```swift
case needsRefinement
```

当前不要提前实现。

---

## 九、关键场景标准行为

### 9.1 `家政52`

LLM 输出：

```json
{
  "intent": "record_expense",
  "confidence": 0.9,
  "extractedData": {
    "rawText": "家政52",
    "amount": "52",
    "note": "家政",
    "categoryCandidate": "家政",
    "primaryCategory": null,
    "subCategory": null
  }
}
```

执行：

```text
记录支出 52 元
分类待确认
显示：家政
不触发二次 prompt
```

### 9.2 `午饭35`

LLM 输出：

```json
{
  "intent": "record_expense",
  "confidence": 0.96,
  "extractedData": {
    "rawText": "午饭35",
    "amount": "35",
    "note": "午饭",
    "categoryCandidate": "午饭",
    "primaryCategory": "餐饮",
    "subCategory": "午餐"
  }
}
```

执行：

```text
直接记录
不触发二次 prompt
```

### 9.3 `提醒我明天下午3点买牛奶`

LLM 输出：

```json
{
  "intent": "create_task",
  "confidence": 0.95,
  "extractedData": {
    "rawText": "提醒我明天下午3点买牛奶",
    "title": "买牛奶",
    "dueDateText": "明天下午3点"
  }
}
```

代码解析：

```text
referenceDate: 2026-05-04
dueDateText: 明天下午3点
dueDate: 2026-05-05 15:00
```

### 9.4 `午饭35，提醒我明天买牛奶`

LLM 输出：

```json
{
  "mode": "multi_action",
  "items": [
    {
      "id": "1",
      "intent": "record_expense",
      "confidence": 0.96,
      "extractedData": {
        "rawText": "午饭35",
        "amount": "35",
        "note": "午饭",
        "categoryCandidate": "午饭",
        "primaryCategory": "餐饮",
        "subCategory": "午餐"
      }
    },
    {
      "id": "2",
      "intent": "create_task",
      "confidence": 0.95,
      "extractedData": {
        "rawText": "提醒我明天买牛奶",
        "title": "买牛奶",
        "dueDateText": "明天"
      }
    }
  ],
  "needsClarification": false
}
```

执行：

```text
顺序执行两个动作
多动作结果聚合
不触发二次 prompt
```

### 9.5 `今天花了多少，提醒我买牛奶`

这是 query + action 混合。

处理：

```text
不直接执行
提示：当前版本暂不支持把查询和执行操作混在一句话里，请拆成两句发送。
```

---

## 十、实施计划

### 阶段 1：JSON Mode + 模型默认值

文件：

```text
Models/AI/AIConfiguration.swift
Models/AI/AIModels.swift
Services/AI/OpenAICompatibleProvider.swift
```

任务：

1. 智谱默认模型改为 `glm-4`
2. `ChatCompletionRequest` 增加 `responseFormat`
3. `parseUserInputBatch()` 启用 JSON Mode
4. 保留 JSON 提取 fallback

验收：

```text
意图识别请求体包含 response_format
普通聊天不受影响
不支持 response_format 时能降级
```

### 阶段 2：精简主 prompt

文件：

```text
Services/AI/PromptManager.swift
```

任务：

1. `intentRecognition` prompt version 提升到 v3
2. 移除 responseText 要求
3. 移除最终日期计算规则
4. 字段按 intent 收敛
5. 增加 categoryCandidate
6. 增加 few-shot 边界案例

验收：

```text
家政52 不编造科目
午饭35 正确分类
提醒我明天买牛奶 title 为“买牛奶”
输出仍兼容 AIParseBatch
```

### 阶段 3：代码分担模块

文件：

```text
Services/AI/AIInputPreprocessor.swift
Services/AI/NLDateParser.swift
Services/AI/AIParseBatchValidator.swift
Services/AI/AIResponseTextBuilder.swift
```

任务：

1. 实现金额候选和 raw segment 提取
2. 实现基础中文日期解析
3. 实现简化 Validator
4. 实现回复模板

验收：

```text
明天 → 当前日期 + 1
明天下午3点 → 正确日期时间
非法科目被清空并保留 categoryCandidate
确认文案不依赖 LLM responseText
```

### 阶段 4：接入 ConversationCoordinator / IntentRouter

文件：

```text
Services/AI/OpenAICompatibleProvider.swift
Services/AI/ConversationCoordinator.swift
Services/AI/IntentRouter.swift
Services/CategoryMatcherService.swift
```

任务：

1. provider 调用预处理并注入 context
2. provider 或 coordinator 执行 Validator
3. coordinator 使用 `AIResponseTextBuilder`
4. IntentRouter 匹配科目时优先考虑 `categoryCandidate`
5. 科目失败时保持“待确认”

验收：

```text
分类不存在时不会错分
待确认卡片能显示 categoryCandidate
多动作流程不退化
query + action 混合仍被拦截
```

### 阶段 5：科目映射增强

文件：

```text
Services/CategoryMatcherService.swift
```

可能新增：

```text
Models/Finance/CategoryUserMapping.swift
Services/CategoryUserMappingService.swift
```

任务：

1. 扩充内置 synonym
2. 记录未匹配 categoryCandidate
3. 预留用户确认后学习映射

验收：

```text
午饭/早饭/晚饭等高频词稳定命中
家政等不明确词不硬分
未匹配词可统计
```

---

## 十一、测试集

### 11.1 记账

```text
午饭35
打车去公司30
咖啡18
工资到账8000
```

断言：

```text
intent 正确
amount 正确
note 正确
科目合法
```

### 11.2 科目边界

```text
家政52
修鞋20
猫粮80
椅子扶手40
```

断言：

```text
不存在的科目不被编造
categoryCandidate 保留
可匹配项正常匹配
不可匹配项待确认
```

### 11.3 任务

```text
提醒我明天买牛奶
明天下午3点提醒我交房租
完成买牛奶
删除买牛奶这个任务
```

断言：

```text
title 去掉“提醒我”
dueDateText 保留自然语言
NLDateParser 解析正确
taskKeyword 正确
```

### 11.4 多动作

```text
午饭35，提醒我明天买牛奶
打车30，咖啡18，完成买牛奶
```

断言：

```text
mode 为 multi_action
items 数量正确
每个 item rawText 独立
顺序执行
```

### 11.5 查询分析

```text
分析上个月消费
对比这个月和上个月的支出
复盘最近一周的任务完成情况
综合分析最近一个月
```

断言：

```text
query_analysis 正确
analysisDomain 正确
periodText 保留
日期范围由代码解析
```

### 11.6 不支持混合场景

```text
今天花了多少，提醒我买牛奶
```

断言：

```text
不执行任务
提示用户拆成两句
```

---

## 十二、观测指标

C+A 上线后建议记录：

```text
JSON decode failure rate
required field missing rate
category unmatched rate
hallucinated category rate
clarification rate
query/action mixed rejection rate
average parse latency
```

重点目标：

```text
hallucinated category rate → 接近 0
JSON decode failure rate → 接近 0
required field missing rate → < 5%
category unmatched rate → 可接受，但需要可解释
平均延迟 → 不显著高于当前单次调用
```

判断是否引入 Selective B 的条件：

```text
如果某个 intent 的 required field missing rate 长期 > 5%
且 prompt/few-shot/代码预处理无法改善
再为该 intent 做专用二次 prompt
```

---

## 十三、风险与应对

### 13.1 JSON Mode 兼容风险

风险：

```text
部分 Provider 不支持 response_format
```

应对：

```text
按 Provider 能力开启
失败时降级
保留 extractJSON fallback
```

### 13.2 日期解析覆盖不足

风险：

```text
代码解析不了复杂自然语言日期
```

应对：

```text
第一版只支持高频表达
无法解析时保留 dueDateText
必要时提示确认
后续用真实输入扩展规则
```

### 13.3 Validator 过严

风险：

```text
正确结果被拦截
```

应对：

```text
第一版只做少量关键校验
科目非法只清空科目，不阻止记账
字段缺失才澄清
```

### 13.4 科目待确认过多

风险：

```text
用户感觉 AI 不够聪明
```

应对：

```text
扩充 synonym
记录高频未匹配词
用户确认后学习映射
不要用错误分类换取表面自动化
```

### 13.5 主 prompt 过度精简

风险：

```text
模型失去足够分类上下文
```

应对：

```text
保留一级科目 + 高频二级示例
测试集覆盖边界案例
逐步调整 prompt
```

---

## 十四、最终建议

当前最优路线：

```text
C + A 扎实落地
Selective B 暂缓
科目问题优先用 categoryCandidate + synonym + 待确认 + 用户学习解决
```

不建议当前实施：

```text
全量两阶段 Pipeline
SelectiveRefinementService
IntentSpecificPromptFactory
所有 intent 专用 prompt
embedding 科目匹配
完整本地规则引擎
```

可以预留但不实现：

```text
ValidationDecision.needsRefinement
专用 prompt 类型
多 LLM 调用日志结构
```

最终目标：

```text
LLM 做语义理解
代码做确定性裁决
科目长尾靠可学习映射
执行层永远保留待确认兜底
```

这条路线比上一版更轻、更稳，也更适合当前 HoloAI 的工程阶段。
