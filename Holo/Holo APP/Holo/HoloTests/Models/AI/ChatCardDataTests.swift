//
//  ChatCardDataTests.swift
//  HoloTests
//
//  测试 ChatCardData 枚举和数据模型
//

import XCTest
@testable import Holo

final class ChatCardDataTests: XCTestCase {

    // MARK: - ChatCardData.from() 工厂方法

    // MARK: 记账卡片

    func testFromRecordExpense() {
        let data: [String: String] = [
            "amount": "35.5",
            "note": "午饭",
            "primaryCategory": "餐饮",
            "subCategory": "午餐",
            "type": "expense"
        ]

        let result = ChatCardData.from(intent: .recordExpense, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("应为 .transaction 类型")
            return
        }

        XCTAssertEqual(cardData.amount, "35.5")
        XCTAssertEqual(cardData.note, "午饭")
        XCTAssertEqual(cardData.primaryCategory, "餐饮")
        XCTAssertEqual(cardData.subCategory, "午餐")
        XCTAssertTrue(cardData.isExpense)
    }

    func testFromRecordIncome() {
        let data: [String: String] = [
            "amount": "10000",
            "note": nil,
            "primaryCategory": "工资收入",
            "subCategory": "工资"
        ]

        let result = ChatCardData.from(intent: .recordIncome, data: data)

        guard case .transaction(let cardData) = result else {
            XCTFail("应为 .transaction 类型")
            return
        }

        XCTAssertEqual(cardData.amount, "10000")
        XCTAssertFalse(cardData.isExpense)
    }

    func testFromRecordExpenseMissingAmount() {
        let data: [String: String] = [
            "note": "午饭"
        ]

        let result = ChatCardData.from(intent: .recordExpense, data: data)
        XCTAssertNil(result, "缺少 amount 应返回 nil")
    }

    func testFromRecordExpenseNilData() {
        let result = ChatCardData.from(intent: .recordExpense, data: nil)
        XCTAssertNil(result, "data 为 nil 应返回 nil")
    }

    // MARK: 任务卡片

    func testFromCreateTask() {
        let data: [String: String] = [
            "title": "完成项目报告",
            "dueDate": "今天",
            "priority": "high"
        ]

        let result = ChatCardData.from(intent: .createTask, data: data)

        guard case .task(let cardData) = result else {
            XCTFail("应为 .task 类型")
            return
        }

        XCTAssertEqual(cardData.title, "完成项目报告")
        XCTAssertEqual(cardData.dueDate, "今天")
        XCTAssertEqual(cardData.priority, "high")
    }

    func testFromCreateTaskEmptyTitle() {
        let data: [String: String] = [
            "title": ""
        ]

        let result = ChatCardData.from(intent: .createTask, data: data)
        XCTAssertNil(result, "空标题应返回 nil")
    }

    func testFromCreateTaskMissingTitle() {
        let data: [String: String] = [:]

        let result = ChatCardData.from(intent: .createTask, data: data)
        XCTAssertNil(result, "缺少 title 应返回 nil")
    }

    // MARK: 习惯打卡卡片

    func testFromCheckIn() {
        let data: [String: String] = [
            "habitName": "跑步",
            "streak": "7",
            "completed": "true"
        ]

        let result = ChatCardData.from(intent: .checkIn, data: data)

        guard case .habitCheckIn(let cardData) = result else {
            XCTFail("应为 .habitCheckIn 类型")
            return
        }

        XCTAssertEqual(cardData.habitName, "跑步")
        XCTAssertEqual(cardData.streak, 7)
        XCTAssertTrue(cardData.completed)
    }

    func testFromCheckInMissingStreak() {
        let data: [String: String] = [
            "habitName": "跑步",
            "completed": "true"
        ]

        let result = ChatCardData.from(intent: .checkIn, data: data)

        guard case .habitCheckIn(let cardData) = result else {
            XCTFail("应为 .habitCheckIn 类型")
            return
        }

        XCTAssertNil(cardData.streak, "缺少 streak 应为 nil")
    }

    func testFromCheckInDefaultCompleted() {
        let data: [String: String] = [
            "habitName": "冥想"
        ]

        let result = ChatCardData.from(intent: .checkIn, data: data)

        guard case .habitCheckIn(let cardData) = result else {
            XCTFail("应为 .habitCheckIn 类型")
            return
        }

        XCTAssertTrue(cardData.completed, "默认 completed 应为 true")
    }

    // MARK: 心情卡片

    func testFromRecordMood() {
        let data: [String: String] = [
            "mood": "开心",
            "content": "今天天气不错，心情很好"
        ]

        let result = ChatCardData.from(intent: .recordMood, data: data)

        guard case .mood(let cardData) = result else {
            XCTFail("应为 .mood 类型")
            return
        }

        XCTAssertEqual(cardData.mood, "开心")
        XCTAssertEqual(cardData.content, "今天天气不错，心情很好")
    }

    func testFromRecordMoodEmptyContent() {
        let data: [String: String] = [
            "mood": "开心",
            "content": ""
        ]

        let result = ChatCardData.from(intent: .recordMood, data: data)
        XCTAssertNil(result, "空 content 应返回 nil")
    }

    // MARK: 体重卡片

    func testFromRecordWeight() {
        let data: [String: String] = [
            "weight": "65.5",
            "unit": "kg"
        ]

        let result = ChatCardData.from(intent: .recordWeight, data: data)

        guard case .weight(let cardData) = result else {
            XCTFail("应为 .weight 类型")
            return
        }

        XCTAssertEqual(cardData.weight, "65.5")
        XCTAssertEqual(cardData.unit, "kg")
    }

    func testFromRecordWeightDefaultUnit() {
        let data: [String: String] = [
            "weight": "70"
        ]

        let result = ChatCardData.from(intent: .recordWeight, data: data)

        guard case .weight(let cardData) = result else {
            XCTFail("应为 .weight 类型")
            return
        }

        XCTAssertEqual(cardData.unit, "kg", "默认单位应为 kg")
    }

    // MARK: 不应产生卡片的意图

    func testFromChatReturnsNil() {
        let result = ChatCardData.from(intent: .unknown, data: ["foo": "bar"])
        XCTAssertNil(result, "unknown 不应产生卡片")
    }

    func testFromQueryReturnsNil() {
        let result = ChatCardData.from(intent: .query, data: ["foo": "bar"])
        XCTAssertNil(result, ".query 不应产生卡片")
    }

    func testFromUnknownReturnsNil() {
        let result = ChatCardData.from(intent: .unknown, data: ["foo": "bar"])
        XCTAssertNil(result, ".unknown 不应产生卡片")
    }

    // MARK: - TransactionCardData 计算属性

    func testDisplayTitleWithNote() {
        let data = TransactionCardData(
            amount: "35", note: "午饭",
            primaryCategory: "餐饮", subCategory: "午餐",
            type: "expense", date: nil
        )
        XCTAssertEqual(data.displayTitle, "午饭")
    }

    func testDisplayTitleWithoutNote() {
        let data = TransactionCardData(
            amount: "35", note: nil,
            primaryCategory: "餐饮", subCategory: "午餐",
            type: "expense", date: nil
        )
        XCTAssertEqual(data.displayTitle, "午餐", "无 note 时应用子分类名")
    }

    func testDisplayTitleWithoutNoteAndSubCategory() {
        let data = TransactionCardData(
            amount: "35", note: nil,
            primaryCategory: "餐饮", subCategory: nil,
            type: "expense", date: nil
        )
        XCTAssertEqual(data.displayTitle, "餐饮", "无 note 和子分类时应用一级分类名")
    }

    func testDisplayTitleEmptyNote() {
        let data = TransactionCardData(
            amount: "35", note: "",
            primaryCategory: "餐饮", subCategory: "午餐",
            type: "expense", date: nil
        )
        XCTAssertEqual(data.displayTitle, "午餐", "空 note 时应用子分类名")
    }

    func testCategoryPathWithBoth() {
        let data = TransactionCardData(
            amount: "35", note: "午饭",
            primaryCategory: "餐饮", subCategory: "午餐",
            type: "expense", date: nil
        )
        XCTAssertEqual(data.categoryPath, "餐饮 · 午餐")
    }

    func testCategoryPathPrimaryOnly() {
        let data = TransactionCardData(
            amount: "35", note: "午饭",
            primaryCategory: "餐饮", subCategory: nil,
            type: "expense", date: nil
        )
        XCTAssertEqual(data.categoryPath, "餐饮")
    }

    func testCategoryPathNilPrimary() {
        let data = TransactionCardData(
            amount: "35", note: "午饭",
            primaryCategory: nil, subCategory: nil,
            type: "expense", date: nil
        )
        XCTAssertNil(data.categoryPath)
    }

    // MARK: - linkedEntityId

    func testLinkedEntityIdTransaction() {
        let data = ["transactionId": "12345678-1234-1234-1234-123456789012"]
        let id = ChatCardData.linkedEntityId(from: data)
        XCTAssertEqual(id, "12345678-1234-1234-1234-123456789012")
    }

    func testLinkedEntityIdTask() {
        let data = ["taskId": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]
        let id = ChatCardData.linkedEntityId(from: data)
        XCTAssertEqual(id, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testLinkedEntityIdPriority() {
        let data = [
            "transactionId": "11111111-1111-1111-1111-111111111111",
            "taskId": "22222222-2222-2222-2222-222222222222"
        ]
        let id = ChatCardData.linkedEntityId(from: data)
        XCTAssertEqual(id, "11111111-1111-1111-1111-111111111111", "应优先返回 transactionId")
    }

    func testLinkedEntityIdNil() {
        XCTAssertNil(ChatCardData.linkedEntityId(from: nil))
        XCTAssertNil(ChatCardData.linkedEntityId(from: [:]))
        XCTAssertNil(ChatCardData.linkedEntityId(from: ["amount": "35"]))
    }
}
