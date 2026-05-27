# 子任务自动识别功能设计

## 背景

用户通过 AI 对话创建任务时，输入如「去山姆买牛奶和洗手液」，系统应自动识别其中的多个并列事项，拆分为子任务（CheckItem），同时将主任务标题概括为整体意图。

## 需求

- AI 解析用户输入时，识别 2 个及以上并列待办事项
- 自动将主任务 title 概括为整体意图
- 为每个子项创建 CheckItem
- 仅 1 个事项时不触发拆分
- 无需用户确认，自动完成
- 误拆比漏拆更伤害体验，信心不足时不拆

## 方案：Prompt 原生提取

在现有 `create_task` 意图的 LLM 解析中，增加 `subtasks` 字段提取。AI 在同一次调用中完成子任务识别和标题概括，零额外 LLM 开销。

## 改动文件

### 1. PromptManager.swift — Prompt 模板（v6 → v7）

- 将 `promptVersions[.intentRecognition]` 从 `6` 升到 `7`，注释标明"子任务自动识别"
- 确保旧版自定义 prompt（< v7）自动回退默认模板

在 intentRecognition 模板中：

**extractedData 新增字段**：
```
"subtasks": "逗号分隔的子任务列表（仅当识别到2项及以上并列待办事项时提取）"
```

**新增规则段**：
```
子任务识别：
- 只有多个并列"待办动作/事项"才提取 subtasks
- 并列对象不拆（如"给张三和李四发邮件"→不拆）
- 并列人名不拆（如"约小王和小李吃饭"→不拆）
- 介词结构不拆（如"和妈妈打电话"→不拆）
- 信心不足时不提取 subtasks，直接创建普通任务
- 用户输入包含2个及以上并列待办事项时，将每项提取为 subtasks（逗号分隔）
- 同时将 title 概括为整体意图（如"去山姆买牛奶和洗手液"→ title="去山姆购物", subtasks="买牛奶,买洗手液"）
- 仅1个事项时不提取 subtasks 字段
```

**新增示例**：
```json
{"id":"3","intent":"create_task","confidence":0.95,"extractedData":{"title":"去山姆购物","dueDate":"2026-05-17 19:00","subtasks":"买牛奶,买洗手液"}}
```

### 2. TodoRepository.swift — 新增原子创建方法

新增 `createTask(..., checkItems: [String])` 方法：
- 在同一个 Core Data context 中创建 TodoTask 和所有 CheckItem
- 只执行一次 `context.save()`、一次 `loadActiveTasks()`、一次 `notifyDataChange()`
- 失败时 rollback，避免半成功数据

### 3. IntentRouter.swift — handleCreateTask

在任务创建逻辑中：
```
1. 从 extractedData["subtasks"] 读取子任务字符串
2. 调用 SubtaskParser.parse() 解析为 [String]
3. 解析后不足 2 项时，走原有 createTask 路径
4. 解析后 >= 2 项时，调用新的原子方法 createTask(..., checkItems:)
5. 将子任务信息传入 AIResponseTextBuilder
```

### 4. 新增 SubtaskParser helper

独立的字符串解析工具：
- 支持 `,`、`，`、`、`、`;`、`；`、换行作为分隔符
- 每项 trim 空白
- 过滤空项
- 去重
- 最大子任务数量限制（10 项），超出截断
- 单个标题长度限制（50 字符），超出截断
- 解析后不足 2 项时返回空数组

### 5. AIResponseTextBuilder.swift — taskCreated 方法

增加 `subtaskCount` 参数：
- 有子任务时返回"已创建任务「去山姆购物」，包含 2 个子任务"
- 无子任务时行为不变

### 6. 卡片展示对齐（可选）

- `ConversationCoordinator.buildRenderData` 将子任务数量写入 `renderData`
- `TaskCardData` 和 `TaskChatCard` 展示"N 个子任务"，让卡片与回复文案一致

### 7. AIParseBatchValidator.swift

无改动。`subtasks` 为可选字段，不影响 `title` 必填校验。

## 数据流

```
用户输入 "提醒我1小时后去山姆买牛奶和洗手液"
    → AI 解析（PromptManager v7 + 子任务规则）
    → extractedData: { title: "去山姆购物", dueDate: "2026-05-17 22:17", subtasks: "买牛奶,买洗手液" }
    → IntentRouter.handleCreateTask()
        → SubtaskParser.parse("买牛奶,买洗手液") → ["买牛奶", "买洗手液"]
        → TodoRepository.createTask(title: "去山姆购物", ..., checkItems: ["买牛奶", "买洗手液"])
            → 同一 context 创建 TodoTask + 2 个 CheckItem
            → 一次 save + 一次 notify
    → RouteResult(text: "已创建任务「去山姆购物」，包含 2 个子任务")
```

## 边界情况

| 输入 | 预期行为 |
|------|---------|
| 「提醒我买牛奶」 | 无 subtasks，正常创建单任务 |
| 「去买牛奶和面包」 | title="购物", subtasks="买牛奶,买面包" |
| 「早上刷牙洗脸吃饭」 | title="早上准备", subtasks="刷牙,洗脸,吃早饭" |
| 「和妈妈打电话」 | 不拆（"和"是介词不是并列） |
| 「给张三和李四发邮件」 | 不拆（并列对象，非并列待办） |
| 「约小王和小李吃饭」 | 不拆（并列人名） |
| 「买牛奶和给妈妈打电话」 | 拆，subtasks="买牛奶,给妈妈打电话" |
| 「去超市买牛奶、面包、鸡蛋」 | 拆，subtasks="买牛奶,买面包,买鸡蛋" |
| 「提醒我准备护照身份证」 | 信心不足时不拆 |

## 测试计划

| 测试场景 | 验证点 |
|---------|--------|
| 无子任务 | `taskCreated` 返回原文案，不创建 CheckItem |
| 有子任务 | 创建对应数量 CheckItem，order 正确递增 |
| 单项不拆 | subtasks 为空或解析后 < 2 项时走普通任务路径 |
| 分隔符兼容 | 英文逗号、中文逗号、顿号、分号、换行都能正确解析 |
| 去重 | 重复项只保留一个 |
| 长度/数量限制 | 超长标题截断，超过 10 项截断 |
| 误拆边界 | 并列人名、并列对象、介词"和"不拆 |
| Prompt version | v7 升级后旧自定义 prompt 自动回退默认模板 |
| 原子性 | CheckItem 创建失败时主任务也回滚 |

## 实施顺序

1. 新增 `SubtaskParser` helper（纯函数，可独立测试）
2. `TodoRepository` 新增原子方法 `createTask(..., checkItems:)`
3. `PromptManager` 升级 prompt version 到 v7，增加子任务识别规则和示例
4. `IntentRouter.handleCreateTask` 接入子任务解析和创建
5. `AIResponseTextBuilder.taskCreated` 增加 subtaskCount 参数
6. 卡片展示对齐（可选）
7. 补测试

## 不做的事

- 不增加独立的 SubTask 实体，复用现有 CheckItem
- 不做子任务的嵌套（CheckItem 不再拆子任务）
- 不修改 AddTaskSheet UI（手动创建任务的入口不变）
