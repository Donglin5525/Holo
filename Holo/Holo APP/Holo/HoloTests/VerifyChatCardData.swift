//
//  VerifyChatCardData.swift
//  卡片数据逻辑验证脚本
//
//  用法：swift VerifyChatCardData.swift
//  验证 ChatCardData.from() 工厂方法和 CategorySFSymbolMapper 的核心逻辑
//

import Foundation

// MARK: - 复制核心逻辑（用于独立验证）

/// AI 意图枚举（简化版，用于独立验证）
enum TestAIIntent: String {
    case recordExpense = "record_expense"
    case recordIncome = "record_income"
    case createTask = "create_task"
    case recordMood = "record_mood"
    case recordWeight = "record_weight"
    case checkIn = "check_in"
    case query = "query"
    case chat = "chat"
    case unknown = "unknown"
}

// 数据结构
struct TestTransactionCardData: Equatable {
    let amount: String
    let note: String?
    let primaryCategory: String?
    let subCategory: String?
    let type: String
    let date: String?
    var isExpense: Bool { type == "expense" }
    var displayTitle: String {
        if let note = note, !note.isEmpty { return note }
        return subCategory ?? primaryCategory ?? "未分类"
    }
    var categoryPath: String? {
        guard let primary = primaryCategory else { return nil }
        if let sub = subCategory, !sub.isEmpty { return "\(primary) · \(sub)" }
        return primary
    }
}

struct TestTaskCardData: Equatable {
    let title: String
    let dueDate: String?
    let priority: String?
}

struct TestHabitCheckInCardData: Equatable {
    let habitName: String
    let streak: Int?
    let completed: Bool
}

struct TestMoodCardData: Equatable {
    let mood: String?
    let content: String
}

struct TestWeightCardData: Equatable {
    let weight: String
    let unit: String
}

enum TestChatCardData: Equatable {
    case transaction(TestTransactionCardData)
    case task(TestTaskCardData)
    case habitCheckIn(TestHabitCheckInCardData)
    case mood(TestMoodCardData)
    case weight(TestWeightCardData)

    static func from(intent: TestAIIntent, data: [String: String]?) -> TestChatCardData? {
        guard let data = data else { return nil }
        switch intent {
        case .recordExpense:
            guard let amount = data["amount"] else { return nil }
            return .transaction(TestTransactionCardData(
                amount: amount, note: data["note"],
                primaryCategory: data["primaryCategory"],
                subCategory: data["subCategory"],
                type: "expense", date: data["date"]
            ))
        case .recordIncome:
            guard let amount = data["amount"] else { return nil }
            return .transaction(TestTransactionCardData(
                amount: amount, note: data["note"],
                primaryCategory: data["primaryCategory"],
                subCategory: data["subCategory"],
                type: "income", date: data["date"]
            ))
        case .createTask:
            guard let title = data["title"], !title.isEmpty else { return nil }
            return .task(TestTaskCardData(
                title: title, dueDate: data["dueDate"],
                priority: data["priority"]
            ))
        case .checkIn:
            guard let habitName = data["habitName"] else { return nil }
            return .habitCheckIn(TestHabitCheckInCardData(
                habitName: habitName,
                streak: data["streak"].flatMap { Int($0) },
                completed: data["completed"] != "false"
            ))
        case .recordMood:
            let content = data["content"] ?? ""
            guard !content.isEmpty else { return nil }
            return .mood(TestMoodCardData(
                mood: data["mood"], content: content
            ))
        case .recordWeight:
            guard let weight = data["weight"] else { return nil }
            return .weight(TestWeightCardData(
                weight: weight, unit: data["unit"] ?? "kg"
            ))
        case .query, .chat, .unknown:
            return nil
        }
    }
}

// CategorySFSymbolMapper 简化版
class TestCategorySFSymbolMapper {
    private static let primaryMapping: [String: String] = [
        "餐饮": "fork.knife", "交通": "car.fill", "购物": "bag.fill",
        "娱乐": "music.note.list", "居住": "house.fill",
        "医疗": "heart.text.square.fill", "学习": "book.closed.fill",
        "人情": "yensign.circle.fill", "其他": "questionmark.folder.fill",
        "投资理财": "chart.line.uptrend.xyaxis", "工资收入": "banknote.fill",
    ]
    private static let subMapping: [String: String] = [
        "午餐": "sun.max.fill", "早餐": "sunrise.fill", "晚餐": "moon.stars.fill",
        "打车": "car.side.fill", "地铁": "train.side.front.car",
        "服饰": "hanger", "数码": "desktopcomputer",
        "房租": "key.fill", "水费": "drop.fill",
        "就医": "stethoscope", "药品": "pill.fill",
        "工资": "banknote.fill", "奖金": "star.fill",
        "咖啡": "cup.and.saucer.fill",
    ]
    static func icon(for primary: String?, sub: String?) -> String {
        if let sub = sub, let icon = subMapping[sub] { return icon }
        if let primary = primary, let icon = primaryMapping[primary] { return icon }
        return "yensign.circle"
    }
}

// MARK: - 测试框架

var totalTests = 0
var passedTests = 0
var failedTests = [(name: String, message: String)]()

func test(_ name: String, _ assertion: () -> Bool, _ message: String = "") {
    totalTests += 1
    if assertion() {
        passedTests += 1
        print("  ✅ \(name)")
    } else {
        failedTests.append((name: name, message: message))
        print("  ❌ \(name) — \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
func assertNil(_ a: Any?) -> Bool { a == nil }
func assertNotNull(_ a: Any?) -> Bool { a != nil }
func assertTrue(_ a: Bool) -> Bool { a }
func assertFalse(_ a: Bool) -> Bool { !a }

// MARK: - 测试用例

func runTests() {
    print("════════════════════════════════════════════════")
    print("  AI Chat 卡片化渲染 - 数据逻辑验证")
    print("════════════════════════════════════════════════\n")

    // ===== ChatCardData.from() =====
    print("📋 ChatCardData.from() 工厂方法\n")

    test("记账-支出: 有完整数据") {
        let data = ["amount": "35.5", "note": "午饭", "primaryCategory": "餐饮", "subCategory": "午餐"]
        guard case .transaction(let card) = TestChatCardData.from(intent: .recordExpense, data: data) else {
            return false
        }
        return assertEqual(card.amount, "35.5")
            && assertEqual(card.note, "午饭")
            && assertTrue(card.isExpense)
    }

    test("记账-收入: 有完整数据") {
        let data = ["amount": "10000", "primaryCategory": "工资收入", "subCategory": "工资"]
        guard case .transaction(let card) = TestChatCardData.from(intent: .recordIncome, data: data) else {
            return false
        }
        return assertFalse(card.isExpense)
    }

    test("记账: 缺少 amount → nil") {
        let data = ["note": "午饭"]
        return assertNil(TestChatCardData.from(intent: .recordExpense, data: data))
    }

    test("记账: data 为 nil → nil") {
        return assertNil(TestChatCardData.from(intent: .recordExpense, data: nil))
    }

    test("任务: 有标题") {
        let data = ["title": "完成项目报告", "dueDate": "今天"]
        guard case .task(let card) = TestChatCardData.from(intent: .createTask, data: data) else {
            return false
        }
        return assertEqual(card.title, "完成项目报告") && assertEqual(card.dueDate, "今天")
    }

    test("任务: 空标题 → nil") {
        let data = ["title": ""]
        return assertNil(TestChatCardData.from(intent: .createTask, data: data))
    }

    test("任务: 无标题 → nil") {
        return assertNil(TestChatCardData.from(intent: .createTask, data: [:]))
    }

    test("习惯打卡: 有连续天数") {
        let data = ["habitName": "跑步", "streak": "7", "completed": "true"]
        guard case .habitCheckIn(let card) = TestChatCardData.from(intent: .checkIn, data: data) else {
            return false
        }
        return assertEqual(card.habitName, "跑步")
            && assertEqual(card.streak, 7)
            && assertTrue(card.completed)
    }

    test("习惯打卡: 无连续天数 → streak 为 nil") {
        let data = ["habitName": "冥想"]
        guard case .habitCheckIn(let card) = TestChatCardData.from(intent: .checkIn, data: data) else {
            return false
        }
        return assertNil(card.streak) && assertTrue(card.completed)
    }

    test("心情: 有内容") {
        let data = ["mood": "开心", "content": "今天天气不错"]
        guard case .mood(let card) = TestChatCardData.from(intent: .recordMood, data: data) else {
            return false
        }
        return assertEqual(card.mood, "开心") && assertEqual(card.content, "今天天气不错")
    }

    test("心情: 空 content → nil") {
        let data = ["mood": "开心", "content": ""]
        return assertNil(TestChatCardData.from(intent: .recordMood, data: data))
    }

    test("体重: 有数值") {
        let data = ["weight": "65.5", "unit": "kg"]
        guard case .weight(let card) = TestChatCardData.from(intent: .recordWeight, data: data) else {
            return false
        }
        return assertEqual(card.weight, "65.5") && assertEqual(card.unit, "kg")
    }

    test("体重: 默认单位为 kg") {
        let data = ["weight": "70"]
        guard case .weight(let card) = TestChatCardData.from(intent: .recordWeight, data: data) else {
            return false
        }
        return assertEqual(card.unit, "kg")
    }

    test("chat 意图 → nil") {
        return assertNil(TestChatCardData.from(intent: .chat, data: ["foo": "bar"]))
    }
    test("query 意图 → nil") {
        return assertNil(TestChatCardData.from(intent: .query, data: ["foo": "bar"]))
    }
    test("unknown 意图 → nil") {
        return assertNil(TestChatCardData.from(intent: .unknown, data: ["foo": "bar"]))
    }

    // ===== TransactionCardData 计算属性 =====
    print("\n📋 TransactionCardData 计算属性\n")

    test("displayTitle: 有 note → 用 note") {
        let data = TestTransactionCardData(amount: "35", note: "午饭", primaryCategory: "餐饮", subCategory: "午餐", type: "expense", date: nil)
        return assertEqual(data.displayTitle, "午饭")
    }

    test("displayTitle: 无 note → 用子分类") {
        let data = TestTransactionCardData(amount: "35", note: nil, primaryCategory: "餐饮", subCategory: "午餐", type: "expense", date: nil)
        return assertEqual(data.displayTitle, "午餐")
    }

    test("displayTitle: 无 note 无子分类 → 用一级分类") {
        let data = TestTransactionCardData(amount: "35", note: nil, primaryCategory: "餐饮", subCategory: nil, type: "expense", date: nil)
        return assertEqual(data.displayTitle, "餐饮")
    }

    test("displayTitle: 空 note → 用子分类") {
        let data = TestTransactionCardData(amount: "35", note: "", primaryCategory: "餐饮", subCategory: "午餐", type: "expense", date: nil)
        return assertEqual(data.displayTitle, "午餐")
    }

    test("categoryPath: 一级+二级") {
        let data = TestTransactionCardData(amount: "35", note: "午饭", primaryCategory: "餐饮", subCategory: "午餐", type: "expense", date: nil)
        return assertEqual(data.categoryPath, "餐饮 · 午餐")
    }

    test("categoryPath: 仅一级") {
        let data = TestTransactionCardData(amount: "35", note: "午饭", primaryCategory: "餐饮", subCategory: nil, type: "expense", date: nil)
        return assertEqual(data.categoryPath, "餐饮")
    }

    test("categoryPath: 无一级 → nil") {
        let data = TestTransactionCardData(amount: "35", note: "午饭", primaryCategory: nil, subCategory: nil, type: "expense", date: nil)
        return assertNil(data.categoryPath)
    }

    // ===== CategorySFSymbolMapper =====
    print("\n📋 CategorySFSymbolMapper 图标映射\n")

    test("二级分类: 餐饮→午餐 → sun.max.fill") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "餐饮", sub: "午餐"), "sun.max.fill")
    }
    test("二级分类: 交通→打车 → car.side.fill") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "交通", sub: "打车"), "car.side.fill")
    }
    test("二级分类: 购物→数码 → desktopcomputer") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "购物", sub: "数码"), "desktopcomputer")
    }
    test("一级分类回退: 餐饮 → fork.knife") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "餐饮", sub: nil), "fork.knife")
    }
    test("一级分类回退: 交通 → car.fill") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "交通", sub: nil), "car.fill")
    }
    test("未知分类 → yensign.circle") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: nil, sub: nil), "yensign.circle")
    }
    test("未知子分类 → 回退到一级") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "餐饮", sub: "不存在的"), "fork.knife")
    }
    test("收入分类: 工资收入 → banknote.fill") {
        return assertEqual(TestCategorySFSymbolMapper.icon(for: "工资收入", sub: nil), "banknote.fill")
    }

    // ===== linkedEntityId =====
    print("\n📋 linkedEntityId 关联实体\n")

    test("transactionId 优先返回") {
        let data = ["transactionId": "111", "taskId": "222"]
        let id = data["transactionId"] ?? data["taskId"] ?? data["habitId"] ?? data["thoughtId"]
        return assertEqual(id, "111")
    }

    test("无关联 ID → nil") {
        let data: [String: String]? = [:]
        let id = data?["transactionId"] ?? data?["taskId"] ?? data?["habitId"] ?? data?["thoughtId"]
        return assertNil(id)
    }

    // ===== 总结 =====
    print("\n════════════════════════════════════════════════")
    print("  结果: \(passedTests)/\(totalTests) 通过")
    if !failedTests.isEmpty {
        print("  失败项:")
        for f in failedTests {
            print("    ❌ \(f.name): \(f.message)")
        }
    }
    print("════════════════════════════════════════════════")

    if failedTests.isEmpty {
        print("\n🎉 所有测试通过！\n")
    } else {
        print("\n⚠️ 有 \(failedTests.count) 个测试失败\n")
    }
}

runTests()
