# 子任务自动识别功能设计

## 背景

用户通过 AI 对话创建任务时，输入如「去山姆买牛奶和洗手液」，系统应自动识别其中的多个并列事项，拆分为子任务（CheckItem），同时将主任务标题概括为整体意图。

## 需求

- AI 解析用户输入时，识别 2 个及以上并列事项
- 自动将主任务 title 概括为整体意图
- 为每个子项创建 CheckItem
- 仅 1 个事项时不触发拆分
- 无需用户确认，自动完成

## 方案：Prompt 原生提取

在现有 `create_task` 意图的 LLM 解析中，增加 `subtasks` 字段提取。AI 在同一次调用中完成子任务识别和标题概括，零额外 LLM 开销。

## 改动文件

### 1. PromptManager.swift — Prompt 模板

在 intentRecognition 模板中：

**extractedData 新增字段**：
```
"subtasks": "逗号分隔的子任务列表（仅当识别到2项及以上并列事项时提取）"
```

**新增规则段**：
```
子任务识别：
- 用户输入包含2个及以上并列待办事项时，将每项提取为 subtasks（逗号分隔）
- 同时将 title 概括为整体意图（如"去山姆买牛奶和洗手液"→ title="去山姆购物", subtasks="买牛奶,买洗手液"）
- 仅1个事项时不提取 subtasks 字段
```

**新增示例**：
```json
{"id":"3","intent":"create_task","confidence":0.95,"extractedData":{"title":"去山姆购物","dueDate":"2026-05-17 19:00","subtasks":"买牛奶,买洗手液"}}
```

### 2. IntentRouter.swift — handleCreateTask

在任务创建后、返回结果前，增加子任务创建逻辑：

```
1. 从 extractedData["subtasks"] 读取子任务字符串
2. 按逗号分隔，过滤空项
3. 若结果 >= 2 项，逐个调用 TodoRepository.addCheckItem() 创建 CheckItem
4. 将子任务信息附加到 RouteResult 的响应文本中
```

### 3. AIResponseTextBuilder.swift — taskCreated 方法

增加 subtasks 参数。有子任务时返回如：
```
"已创建任务「去山姆购物」，包含 2 个子任务"
```

无子任务时行为不变。

### 4. AIParseBatchValidator.swift

无改动。`subtasks` 为可选字段，不影响 `title` 必填校验。

## 数据流

```
用户输入 "提醒我1小时后去山姆买牛奶和洗手液"
    → AI 解析（PromptManager v6 + 子任务规则）
    → extractedData: { title: "去山姆购物", dueDate: "2026-05-17 22:17", subtasks: "买牛奶,买洗手液" }
    → IntentRouter.handleCreateTask()
        → TodoRepository.createTask(title: "去山姆购物", ...)
        → TodoRepository.addCheckItem(title: "买牛奶", order: 0)
        → TodoRepository.addCheckItem(title: "买洗手液", order: 1)
    → RouteResult(text: "已创建任务「去山姆购物」，包含 2 个子任务")
```

## 边界情况

| 输入 | 预期行为 |
|------|---------|
| 「提醒我买牛奶」 | 无 subtasks，正常创建单任务 |
| 「去买牛奶和面包」 | title="买牛奶和面包"→"购物", subtasks="买牛奶,买面包" |
| 「早上刷牙洗脸吃饭」 | title="早上准备", subtasks="刷牙,洗脸,吃早饭" |
| 「和妈妈打电话」 | 无 subtasks（"和"不是并列连词，是介词） |

## 不做的事

- 不增加独立的 SubTask 实体，复用现有 CheckItem
- 不做子任务的嵌套（CheckItem 不再拆子任务）
- 不修改 AddTaskSheet UI（手动创建任务的入口不变）
