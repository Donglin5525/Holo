# HoloAI 意图识别 Prompt 优化方案对比

> 创建时间：2026-05-04
> 背景：当前意图识别 prompt 存在结构性问题，需要重新设计
> 用途：供 GPT 做对抗性审查，评估方案合理性并提供独立建议

---

## 一、项目背景

### Holo AI 是什么

Holo 是一款 iOS 个人效率 APP（Swift/SwiftUI/Core Data），核心功能是通过自然语言对话完成记账、任务管理、习惯打卡、笔记、健康记录、数据查询分析等操作。用户输入如 "午饭35"、"提醒我明天买牛奶"、"分析上个月消费"，AI 识别意图并执行对应操作。

**HoloAI 是整个 APP 最核心的功能模块**，不追求极致投产比，愿意投入精力做最好的方案。

### 当前架构

```
用户输入
  ↓
ChatViewModel.sendMessage()
  ↓
ConversationCoordinator.process()
  ↓
OpenAICompatibleProvider.parseUserInputBatch()
  ├── PromptManager 加载 intentRecognition prompt (~170行)
  ├── 组装消息: [system(prompt), system(用户上下文), user(输入)]
  ├── 调用 glm-4-flash API
  └── 解析 JSON 响应 → AIParseBatch
  ↓
ConversationCoordinator 顺序执行每个动作
  ↓
IntentRouter.route() → 各意图处理器 → Core Data 写入
  ↓
聚合结果 → 返回用户
```

### 技术栈

- **LLM 调用**：OpenAI 兼容接口（`/chat/completions`），当前默认 glm-4-flash
- **支持的 Provider**：智谱 (glm-4-flash)、DeepSeek、通义千问、Moonshot、自定义
- **当前模型**：glm-4-flash（可通过设置切换为 glm-4、glm-4-plus 等）
- **JSON 解析**：纯 prompt 约束（"只回复 JSON"），代码层用正则从响应中提取 JSON，**未启用 JSON Mode / response_format**
- **科目匹配**：LLM 返回科目名称 → 代码层 `CategoryMatcherService` 做 exact/synonym 匹配 → 匹配失败归入"待确认"

---

## 二、当前 Prompt 存在的问题

### 2.1 完整 Prompt 结构（~170 行）

当前 `intentRecognition` prompt 在 `PromptManager.swift` 中硬编码，包含以下部分：

1. **角色定义**：意图识别模块
2. **14 种意图定义**：记账(2)、任务(4)、习惯(1)、笔记(1)、健康(2)、查询(4)、记忆回放(1)、兜底(1)
3. **完整科目体系**：支出 9 个一级科目 ~50 个二级科目、收入 4 个一级科目 ~15 个二级科目
4. **JSON 输出格式**：batch 格式，每个 item 包含 20+ 字段（大部分在大多数场景下为 null）
5. **Mode 判断规则**：single_action / multi_action / query / clarification / unknown
6. **多动作拆分规则**
7. **日期解析规则**：今天/明天/下周一等相对日期 → yyyy-MM-dd 的完整映射规则
8. **意图判断规则**：各意图的关键词触发条件
9. **科目匹配规则**：消费场景到科目的映射示例

### 2.2 具体问题

#### 问题 1：科目幻觉

用户输入 "家政52"，模型返回 `subCategory: "家政"`，但科目表中不存在"家政"这个二级科目。模型在找不到匹配项时自行编造了一个不存在的分类。

这说明 glm-4-flash 在处理 ~65 个科目的完整分类表时，匹配能力不足。

#### 问题 2：输出字段冗余

每个 item 都要输出 20+ 个字段（amount, note, primaryCategory, subCategory, title, taskKeyword, priority, dueDate, tags, description, noteContent, habitName, habitValue, mood, weight, date, analysisDomain, startDate, endDate, periodLabel, comparisonStartDate, comparisonEndDate），大部分为 null。

对于 "家政52" 这样简单的记账，只需 amount/note/primaryCategory/subCategory 四个字段。

#### 问题 3：职责过载

一个 prompt 同时承担：意图分类、实体抽取、科目匹配、日期解析、多动作拆分。所有意图的规则（记账科目、任务优先级、习惯打卡、笔记内容）混在一起，互相干扰。

#### 问题 4：日期解析依赖 LLM

"下周一"、"后天"、"本月5号" 等相对日期完全由 LLM 计算。这是确定性逻辑，LLM 算错的风险不小，且浪费 prompt 空间。

#### 问题 5：responseText 由 LLM 生成

每个 item 都要求 LLM 生成一条确认消息（如 "已记录家政服务支出52元"），但这类文本完全可以用代码模板拼接，更稳定、零成本、零延迟。

#### 问题 6：模型能力不足

glm-4-flash 是快速/低成本模型，处理 170 行复杂指令 + 65 个科目 + 20 字段输出的综合任务，错误率偏高。模型可能在 prompt 尾部的规则上注意力不足。

---

## 三、四个优化方案

### 方案 A：精简单次调用 + 代码分担

**核心思路**：保持一次 LLM 调用不变，把 LLM 不该做的事交给代码，精简 prompt。

#### 代码层接管

| 任务 | 当前 | 改为 |
|------|------|------|
| 日期解析（"明天"→ 2026-05-05） | LLM 计算 | 代码 `NLDateParser`，正则+规则处理 |
| 金额提取 | LLM 从文本提取 | 代码正则预提取，结果注入上下文 |
| 回复文本 | LLM 生成 responseText | 代码模板拼接 |
| 科目校验 | LLM 返回什么用什么 | 代码白名单校验，不合法归"待确认" |
| 多动作拆分 | LLM 拆分 | 代码按逗号/分号预拆分 |

#### Prompt 精简

- 砍掉日期解析规则（~15 行）
- 砍掉 responseText 字段要求
- 输出字段按意图分组：record_expense 只返回 4 个字段，create_task 只返回 3-4 个字段
- 加 5-8 个 few-shot examples 覆盖高频场景
- 总行数从 ~170 行缩到 ~90 行

#### 优缺点

| 优点 | 缺点 |
|------|------|
| 延迟不变（~400ms） | prompt 仍包含所有意图的规则，互相干扰没完全解决 |
| 准确率提升（few-shot + 代码校验） | 改动涉及 PromptManager、Provider、Coordinator、新增工具类 |
| 改动量中等 | 后续加新意图仍需修改全局 prompt |
| 向后兼容好 | - |

---

### 方案 B：两阶段 Pipeline

**核心思路**：拆成两次 LLM 调用，第一次只做意图分类，第二次按意图走专用 prompt。

#### 架构

```
输入 → 代码预处理 → [Stage 1: 意图分类 ~30行prompt]
                        ↓ 返回 [{intent, confidence, mode}]
                   [Stage 2: 专用提取 prompt]
                        ↓ 按意图选对应 prompt
                        record_expense → 记账专用 (~60行，含科目表+few-shot)
                        create_task → 任务专用 (~40行，含title提取规则)
                        query_analysis → 分析专用 (~50行，含日期范围规则)
                        ...
                        ↓ 返回 extractedData
                   代码后处理 → 科目校验 + 模板回复
```

#### Stage 1 输出格式

```json
{
  "mode": "single_action",
  "items": [
    {"id": "1", "intent": "record_expense", "confidence": 0.95}
  ]
}
```

#### Stage 2 各意图专用 prompt

- **record_expense**：含科目表 + 5 个 few-shot，只输出 amount/note/primaryCategory/subCategory
- **create_task**：含 title 提取规则（"提醒我明天买水" → "买水"），只输出 title/dueDate/priority
- **query_analysis**：含分析域 + 日期范围规则，只输出 analysisDomain/startDate/endDate
- **其他意图**：各有精简专用 prompt

#### 优缺点

| 优点 | 缺点 |
|------|------|
| 每个 prompt 职责单一，准确率最高 | **延迟翻倍**（~800ms） |
| 各意图独立 prompt，互不干扰 | 两次串行 API 调用 |
| 后续加新意图只需加一个专用 prompt | 改动量大：PromptManager、Provider、Coordinator、AIModels 都要改 |
| 科目匹配可以独立优化 | 代码复杂度增加（两阶段调度逻辑） |
| - | 多动作场景（"午饭35，提醒我买牛奶"）可能需要多次 Stage 2 调用 |

---

### 方案 C：升级模型 + 启用 JSON Mode

**核心思路**：当前问题可能 60% 是模型能力不足导致的，升级模型 + 强制 JSON 输出可能是 ROI 最高的改动。

#### 具体改动

**1. 升级模型**

glm-4-flash → glm-4 或 glm-4-plus。当前代码已支持切换，用户可在设置中修改，或修改 `AIConfiguration.swift` 默认值。

**2. 启用 JSON Mode**

在 `ChatCompletionRequest` 中新增 `response_format` 字段：

```swift
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessageDTO]
    let temperature: Double?
    let maxTokens: Int?
    let stream: Bool?
    let responseFormat: ResponseFormat?  // 新增

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

struct ResponseFormat: Codable {
    let type: String  // "json_object"
}
```

智谱 API 的 `/chat/completions` 端点支持 OpenAI 兼容的 `response_format` 参数。

**3. 适度精简 prompt**

- 砍掉 responseText 要求
- 加 3-5 个 few-shot examples
- prompt 结构基本不变

#### 优缺点

| 优点 | 缺点 |
|------|------|
| **改动量最小**（~3 个文件，1-2 天） | API 成本增加 3-5 倍 |
| 准确率提升显著（模型能力提升） | prompt 结构性问题未根本解决 |
| JSON Mode 消除格式错误 | 不考虑投产比的话，成本不是问题 |
| 向后兼容，风险低 | 后续维护仍需修改全局大 prompt |

---

### 方案 D：本地规则优先 + LLM 兜底

**核心思路**：构建本地规则引擎，高频简单输入直接命中不走 LLM，只有复杂/模糊输入才调用 LLM。

#### 规则引擎设计

```swift
func classify(input: String) -> ParsedResult? {
    // 规则1: "关键词 + 数字" → 记账
    //   "午饭35" → record_expense, amount:35, category:餐饮>午餐
    //   "打车30" → record_expense, amount:30, category:交通>打车

    // 规则2: "打卡/签到 + 习惯名" → 打卡
    // 规则3: "完成了/做完了 + 关键词" → 完成任务
    // 规则4: "提醒我/待办 + 内容" → 创建任务
    // 规则5: "记一下/笔记 + 内容" → 创建笔记

    // 未命中 → 走 LLM（当前完整 prompt）
    return nil
}
```

#### 优缺点

| 优点 | 缺点 |
|------|------|
| 高频简单输入 **0 延迟** | 规则引擎维护成本高 |
| 省大量 API 调用费用 | 覆盖率有限，复杂/模糊输入仍需 LLM |
| 常见场景准确率最高（确定性匹配） | 规则冲突和优先级管理复杂 |
| - | 用户的表达方式在不断变化，规则要持续更新 |
| - | 两套逻辑（规则 + LLM）并存，测试和维护成本高 |

---

## 四、方案组合讨论

### Claude 的推荐：C + A

Claude 推荐先做 C（升级模型 + JSON Mode）立刻见效，再用 A（代码分担 + prompt 精简）逐步加固。

理由：
1. C 解决模型能力问题，A 解决 prompt 结构问题，两者互补不重叠
2. 延迟不变（单次调用 ~500ms），比 B 的 ~1000ms 好
3. 分阶段实施，每步可独立验证
4. 后续如果准确率仍不够，可以在此基础上再考虑 B

### 未推荐的组合：C + B

C+B 意味着更好的模型 + 两次串行调用，延迟约 1000ms。两阶段 pipeline 的意义是"用简单模型做简单事"，但强模型本身就能处理好单 prompt，拆成两步反而浪费了强模型的综合理解能力。

**这是 Claude 的判断，需要对抗审查验证其合理性。**

---

## 五、关键约束和偏好

1. **HoloAI 是核心功能**：不追求极致投产比，愿意投入精力
2. **延迟敏感**：交互式对话场景，用户对响应速度有感知
3. **不考虑 API 成本**：愿意为更好的效果付费
4. **当前可用的 Provider**：智谱(glm-4-flash/glm-4/glm-4-plus)、DeepSeek、通义千问、Moonshot、自定义
5. **现有代码分层清晰**：PromptManager / OpenAICompatibleProvider / ConversationCoordinator / IntentRouter 改动范围可控
6. **科目匹配已有代码层兜底**：`CategoryMatcherService` 做 exact/synonym 匹配，失败归入"待确认"，但 LLM 返回错误科目名会导致匹配走 fallback 流程
7. **prompt 可用户自定义**：`PromptManager` 支持 UserDefaults 覆盖默认 prompt，方案需要保持这个能力

---

## 六、希望对抗审查回答的问题

1. C+A 的推荐是否合理？有没有遗漏更好的组合方案？
2. 两阶段 Pipeline (B) 在什么场景下值得做？是否过度设计？
3. 升级模型 (C) 能在多大程度上解决当前的科目幻觉问题？还是 prompt 结构必须改？
4. 本地规则引擎 (D) 是否值得作为补充手段？还是纯 LLM 方案更可持续？
5. 有没有考虑过 function calling / tool use 的方式替代纯 prompt 方案？
6. JSON Mode + few-shot 是否足够，还是需要更结构化的输出约束（如 JSON Schema）？
7. 对于"家政52"这种不在科目表中的输入，最优的处理策略是什么？
