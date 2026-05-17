# 子任务自动识别功能 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AI 创建任务时自动识别并列事项，拆分为 CheckItem 子任务

**Architecture:** 在现有 `create_task` 意图的 LLM 解析中新增 `subtasks` 字段，通过 SubtaskParser 解析后原子创建 TodoTask + CheckItem

**Tech Stack:** SwiftUI, Swift 5+, Core Data, XCTest

---

## 文件结构

| 操作 | 文件 | 职责 |
|------|------|------|
| 创建 | `Services/AI/SubtaskParser.swift` | 子任务字符串解析（纯函数） |
| 修改 | `Models/TodoRepository.swift:252-291` | createTask 新增 checkItemTitles 参数 |
| 修改 | `Services/AI/PromptManager.swift:78,269-274,310,326` | Prompt v7 升级 + 子任务规则 |
| 修改 | `Services/AI/IntentRouter.swift:274-305` | handleCreateTask 接入子任务 |
| 修改 | `Services/AI/AIResponseTextBuilder.swift:52-68` | taskCreated 增加子任务文案 |
| 创建 | `HoloTests/Services/AI/SubtaskParserTests.swift` | SubtaskParser 单元测试 |

根路径：`/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo/`

---

### Task 1: SubtaskParser 纯函数（TDD）

**Files:**
- Create: `Services/AI/SubtaskParser.swift`
- Test: `HoloTests/Services/AI/SubtaskParserTests.swift`

- [ ] **Step 1: 编写测试文件**

创建 `HoloTests/Services/AI/SubtaskParserTests.swift`：

```swift
import XCTest
@testable import Holo

final class SubtaskParserTests: XCTestCase {

    // MARK: - 基本解析

    func testParseNilReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse(nil).isEmpty)
    }

    func testParseEmptyStringReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse("").isEmpty)
    }

    func testParseSingleItemReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse("买牛奶").isEmpty)
    }

    func testParseTwoCommaSeparatedItems() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶,买洗手液"), ["买牛奶", "买洗手液"])
    }

    // MARK: - 分隔符兼容

    func testParseChineseComma() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶，买洗手液"), ["买牛奶", "买洗手液"])
    }

    func testParseDunHao() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶、买面包、买鸡蛋"), ["买牛奶", "买面包", "买鸡蛋"])
    }

    func testParseSemicolon() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶；买洗手液"), ["买牛奶", "买洗手液"])
    }

    func testParseMixedSeparators() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶，买面包、买鸡蛋"), ["买牛奶", "买面包", "买鸡蛋"])
    }

    // MARK: - 清理逻辑

    func testParseTrimsWhitespace() {
        XCTAssertEqual(SubtaskParser.parse(" 买牛奶 , 买洗手液 "), ["买牛奶", "买洗手液"])
    }

    func testParseDeduplicates() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶,买牛奶,买洗手液"), ["买牛奶", "买洗手液"])
    }

    func testParseFiltersEmptyItems() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶,,买洗手液，"), ["买牛奶", "买洗手液"])
    }

    // MARK: - 限制

    func testParseTruncatesLongTitle() {
        let longTitle = String(repeating: "买", count: 60)
        let result = SubtaskParser.parse("\(longTitle),买洗手液")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].count, SubtaskParser.maxTitleLength)
    }

    func testParseLimitsToMaxSubtasks() {
        let items = (1...15).map { "任务\($0)" }.joined(separator: ",")
        let result = SubtaskParser.parse(items)
        XCTAssertEqual(result.count, SubtaskParser.maxSubtasks)
    }

    func testParseOneItemAfterDedupReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse("买牛奶,买牛奶").isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `xcodebuild test -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/SubtaskParserTests 2>&1 | tail -5`
Expected: 编译失败，SubtaskParser 不存在

- [ ] **Step 3: 编写 SubtaskParser 实现**

创建 `Services/AI/SubtaskParser.swift`：

```swift
import Foundation

/// 子任务字符串解析器
/// 将 LLM 返回的逗号分隔子任务字符串解析为 [String]
enum SubtaskParser {
    static let maxSubtasks = 10
    static let maxTitleLength = 50

    static func parse(_ raw: String?) -> [String] {
        guard let raw = raw, !raw.isEmpty else { return [] }

        let separators = CharacterSet(charactersIn: ",，、;；")
        let items = raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let deduped = items.filter { seen.insert($0).inserted }

        let truncated = deduped.map { title in
            title.count > maxTitleLength ? String(title.prefix(maxTitleLength)) : title
        }

        let limited = Array(truncated.prefix(maxSubtasks))

        return limited.count >= 2 ? limited : []
    }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `xcodebuild test -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoloTests/SubtaskParserTests 2>&1 | tail -5`
Expected: 所有 15 个测试 PASS

- [ ] **Step 5: 提交**

```bash
git add Services/AI/SubtaskParser.swift HoloTests/Services/AI/SubtaskParserTests.swift
git commit -m "feat(iOS): 新增 SubtaskParser 子任务解析器"
```

---

### Task 2: TodoRepository 原子创建方法

**Files:**
- Modify: `Models/TodoRepository.swift:252-291`

- [ ] **Step 1: 修改 createTask 方法签名和实现**

在 `createTask` 方法中新增 `checkItemTitles` 参数（默认值 `nil`，向后兼容），在 `context.save()` 之前批量创建 CheckItem。

将 TodoRepository.swift 第 252 行的方法签名从：

```swift
func createTask(
    title: String,
    description: String? = nil,
    list: TodoList? = nil,
    priority: TaskPriority = .medium,
    dueDate: Date? = nil,
    isAllDay: Bool = false,
    tags: [TodoTag] = [],
    reminders: Set<TaskReminder>? = nil
) throws -> TodoTask {
```

改为：

```swift
func createTask(
    title: String,
    description: String? = nil,
    list: TodoList? = nil,
    priority: TaskPriority = .medium,
    dueDate: Date? = nil,
    isAllDay: Bool = false,
    tags: [TodoTag] = [],
    reminders: Set<TaskReminder>? = nil,
    checkItemTitles: [String]? = nil
) throws -> TodoTask {
```

在 `try context.save()` 之前（约第 282 行），添加：

```swift
    // 创建子任务（原子操作，与主任务同一次 save）
    if let checkItemTitles = checkItemTitles {
        for (index, title) in checkItemTitles.enumerated() {
            CheckItem.create(in: context, title: title, task: task, order: Int16(index))
        }
    }
```

完整方法应为：

```swift
    @discardableResult
    func createTask(
        title: String,
        description: String? = nil,
        list: TodoList? = nil,
        priority: TaskPriority = .medium,
        dueDate: Date? = nil,
        isAllDay: Bool = false,
        tags: [TodoTag] = [],
        reminders: Set<TaskReminder>? = nil,
        checkItemTitles: [String]? = nil
    ) throws -> TodoTask {
        let task = TodoTask.create(
            in: context,
            title: title,
            desc: description,
            list: list,
            priority: priority,
            dueDate: dueDate,
            isAllDay: isAllDay,
            reminders: reminders
        )

        for tag in tags {
            task.addToTags(tag)
        }

        if let reminders = reminders, !reminders.isEmpty, dueDate != nil {
            Task {
                try? await TodoNotificationService.shared.scheduleReminder(for: task, reminders: Array(reminders))
            }
        }

        // 创建子任务（原子操作，与主任务同一次 save）
        if let checkItemTitles = checkItemTitles {
            for (index, title) in checkItemTitles.enumerated() {
                CheckItem.create(in: context, title: title, task: task, order: Int16(index))
            }
        }

        try context.save()
        loadActiveTasks()
        notifyDataChange()
        return task
    }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild build -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED（新参数有默认值 nil，所有现有调用点无需改动）

- [ ] **Step 3: 提交**

```bash
git add Models/TodoRepository.swift
git commit -m "feat(iOS): createTask 支持 checkItemTitles 原子创建子任务"
```

---

### Task 3: PromptManager v7 升级 + 子任务规则

**Files:**
- Modify: `Services/AI/PromptManager.swift`

- [ ] **Step 1: 升级 prompt version**

将第 78 行：

```
        .intentRecognition: 6,          // v6: Prompt 移除完整科目表，科目由后端 catalog + 本地分类匹配
```

改为：

```
        .intentRecognition: 7,          // v7: 子任务自动识别；v6: Prompt 移除完整科目表，科目由后端 catalog + 本地分类匹配
```

- [ ] **Step 2: extractedData 新增 subtasks 字段**

在第 274 行 `"description": "任务描述",` 之后添加一行：

```
              "subtasks": "逗号分隔的子任务列表（2项及以上并列待办事项时提取）",
```

- [ ] **Step 3: 新增子任务识别规则**

在第 310 行 `- 如果一句话同时包含执行动作和分析查询，返回 clarification，不要混合执行` 之后，添加：

```
        - 子任务识别：用户输入包含2个及以上并列待办事项时，将每项提取为 subtasks（逗号分隔），同时将 title 概括为整体意图
        - 只有并列"待办动作/事项"才拆：并列对象（给张三和李四发邮件）、并列人名（约小王和小李吃饭）、介词结构（和妈妈打电话）不拆
        - 信心不足时不提取 subtasks，仅1个事项时不提取 subtasks 字段
```

- [ ] **Step 4: 新增子任务示例**

在最后一个示例（第 337 行 `只回复 JSON。` 之前）添加：

```
        输入：「提醒我1小时后去山姆买牛奶和洗手液」
        ```json
        {"mode":"single_action","items":[{"id":"1","intent":"create_task","confidence":0.95,"extractedData":{"title":"去山姆购物","dueDate":"2026-05-17 22:17","subtasks":"买牛奶,买洗手液"}}],"needsClarification":false,"clarificationQuestion":null}
        ```
```

- [ ] **Step 5: 编译验证**

Run: `xcodebuild build -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: 提交**

```bash
git add Services/AI/PromptManager.swift
git commit -m "feat(iOS): Prompt v7 升级，新增子任务自动识别规则"
```

---

### Task 4: IntentRouter.handleCreateTask 接入子任务

**Files:**
- Modify: `Services/AI/IntentRouter.swift:274-305`

- [ ] **Step 1: 修改 handleCreateTask 方法**

将第 274-305 行的 `handleCreateTask` 方法替换为：

```swift
    private func handleCreateTask(_ result: ParsedResult) throws -> RouteResult {
        guard let data = result.extractedData,
              let title = data["title"], !title.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我任务内容")
        }

        let todoRepo = TodoRepository.shared
        let dueDate = parseDate(from: data["dueDate"])
        let priority = parsePriority(data["priority"])
        let hasTime = data["dueDate"].map { NLDateParser.containsTimeComponent($0) } ?? false
        let checkItemTitles = SubtaskParser.parse(data["subtasks"])

        // 有具体时间时，自动添加提前 15 分钟提醒
        let reminders: Set<TaskReminder>? = (hasTime && dueDate != nil)
            ? [TaskReminder(offsetMinutes: 15)]
            : nil

        let task = try todoRepo.createTask(
            title: title,
            priority: priority ?? .medium,
            dueDate: dueDate,
            isAllDay: !hasTime,
            reminders: reminders,
            checkItemTitles: checkItemTitles.isEmpty ? nil : checkItemTitles
        )

        logger.info("任务已创建：\(title)")

        return RouteResult(
            text: AIResponseTextBuilder.taskCreated(title: title, dueDate: dueDate, hasTime: hasTime, subtaskCount: checkItemTitles.count),
            taskId: task.id,
            linkedEntity: LinkedEntity(type: .task, id: task.id)
        )
    }
```

相比原方法的改动：
1. 新增 `let checkItemTitles = SubtaskParser.parse(data["subtasks"])`
2. `createTask` 调用增加 `checkItemTitles:` 参数
3. `AIResponseTextBuilder.taskCreated` 调用增加 `subtaskCount:` 参数

- [ ] **Step 2: 编译验证**

Run: `xcodebuild build -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED（此时 AIResponseTextBuilder 签名不匹配会报错，进入 Task 5 修复）

> 注意：此步骤会编译失败直到 Task 5 完成。如果需要分步验证，可以同时执行 Task 5。

---

### Task 5: AIResponseTextBuilder 增加子任务文案

**Files:**
- Modify: `Services/AI/AIResponseTextBuilder.swift:52-68`

- [ ] **Step 1: 修改 taskCreated 方法**

将第 52-68 行的 `taskCreated` 方法替换为：

```swift
    static func taskCreated(title: String, dueDate: Date?, hasTime: Bool, subtaskCount: Int = 0) -> String {
        var text = "已创建任务：\(title)"

        if subtaskCount > 0 {
            text += "，包含 \(subtaskCount) 个子任务"
        }

        if hasTime, let date = dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            text += "（\(formatter.string(from: date))，将提前 15 分钟提醒你）"
        } else if let date = dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            text += "（\(formatter.string(from: date))）"
        }

        return text
    }
```

改动：新增 `subtaskCount: Int = 0` 参数（默认值 0，所有现有调用点无需改动）。有子任务时在标题后追加"，包含 N 个子任务"。

- [ ] **Step 2: 编译验证（Task 4 + Task 5 一起）**

Run: `xcodebuild build -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交 Task 4 + Task 5**

```bash
git add Services/AI/IntentRouter.swift Services/AI/AIResponseTextBuilder.swift
git commit -m "feat(iOS): 任务创建接入子任务自动识别与展示"
```

---

### Task 6: 端到端验证

- [ ] **Step 1: 运行全量测试**

Run: `xcodebuild test -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10`
Expected: 所有测试 PASS

- [ ] **Step 2: 手工验证清单**

在模拟器或真机上测试以下场景：

| 输入 | 预期结果 |
|------|---------|
| 「提醒我买牛奶」 | 普通任务，无子任务 |
| 「提醒我1小时后去山姆买牛奶和洗手液」 | title="去山姆购物"，2个子任务 |
| 「去买牛奶、面包、鸡蛋」 | title 概括，3个子任务 |
| 「和妈妈打电话」 | 普通任务，不拆分 |
| 「约小王和小李吃饭」 | 普通任务，不拆分 |

- [ ] **Step 3: 最终提交**

```bash
git add -A
git commit -m "feat(iOS): 子任务自动识别功能完成"
```

更新 `docs/CHANGELOG.md` 新增条目。
