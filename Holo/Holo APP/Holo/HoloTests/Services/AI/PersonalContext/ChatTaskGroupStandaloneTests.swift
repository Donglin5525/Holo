//
//  ChatTaskGroupStandaloneTests.swift
//  HoloTests
//
//  聊天写链路纯逻辑验证：同轮多待办合并判定（TaskGroupMergePlanner）与
//  记忆引用署名兜底（HoloMemoryAttributionReconciler）。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ChatTaskGroupStandaloneTests.main()
    }
}
#endif
struct ChatTaskGroupStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        testMergePlanMergesUndatedTasks()
        testMergePlanKeepsDistinctDatesSeparate()
        testMergePlanKeepsSeparatorTitlesSeparate()
        testMergePlanRespectsExistingSubtasks()
        testMergePlanCommonDateCarriedToParent()
        testMergePlanSingleTaskStaysAlone()
        testMergedGroupTitleStripsPolitenessAndCaps()
        testAttributionReconcilerMatchesContentWords()
        testAttributionReconcilerEmptyInputs()
        print("ChatTaskGroupStandaloneTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 工厂

    private static func task(_ title: String, dueDate: String? = nil, subtasks: String = "") -> TaskGroupMergePlanner.Candidate {
        var data: [String: String] = ["title": title]
        if let dueDate { data["dueDate"] = dueDate }
        if !subtasks.isEmpty { data["subtasks"] = subtasks }
        return TaskGroupMergePlanner.Candidate(isCreateTask: true, extractedData: data)
    }

    private static func other(_ intentIsCreate: Bool = false) -> TaskGroupMergePlanner.Candidate {
        TaskGroupMergePlanner.Candidate(isCreateTask: intentIsCreate, extractedData: nil)
    }

    // MARK: 合并判定

    private static func testMergePlanMergesUndatedTasks() {
        let candidates = [
            other(),
            task("出差五天"),
            task("摩卡找物业来照顾"),
            task("提醒我拿快递"),
            task("换水"),
            task("关水电"),
        ]
        let plan = TaskGroupMergePlanner.mergePlan(for: candidates, originalText: "出差五天，摩卡找物业来照顾，提醒我拿快递，换水，关水电")
        expect(plan != nil, "无日期同轮待办应合并")
        expect(plan?.anchorIndex == 1, "锚点是第一条待办")
        expect(plan?.plan.memberCount == 5, "五个成员全并入")
        expect(plan?.memberIndices == Set([1, 2, 3, 4, 5]), "成员下标完整")
        let subtasks = plan?.plan.renderData["subtasks"] ?? ""
        expect(subtasks == "出差五天、摩卡找物业来照顾、提醒我拿快递、换水、关水电", "子条目按序串联，实际：\(subtasks)")
        expect(plan?.plan.renderData["title"] == "出差五天", "主任务标题取原话首分句")
        expect(plan?.plan.renderData["reminderDate"] == nil, "reminderDate 折叠进 dueDate 后移除")
    }

    private static func testMergePlanKeepsDistinctDatesSeparate() {
        let candidates = [
            task("明天买牛奶", dueDate: "明天"),
            task("周末给车充电", dueDate: "周六"),
        ]
        let plan = TaskGroupMergePlanner.mergePlan(for: candidates, originalText: "明天提醒我买牛奶，周末给车充电")
        expect(plan == nil, "日期各异的条目是独立时间锚点，不合并")
    }

    private static func testMergePlanKeepsSeparatorTitlesSeparate() {
        let candidates = [
            task("给摩卡换水，刷牙"),
            task("取快递"),
        ]
        let plan = TaskGroupMergePlanner.mergePlan(for: candidates, originalText: "给摩卡换水，刷牙，取快递")
        expect(plan == nil, "标题含分隔符合并后会错拆子条目，保持独立")
    }

    private static func testMergePlanRespectsExistingSubtasks() {
        let candidates = [
            task("大扫除", subtasks: "客厅、卧室"),
            task("倒垃圾"),
        ]
        let plan = TaskGroupMergePlanner.mergePlan(for: candidates, originalText: "安排大扫除和倒垃圾")
        expect(plan == nil, "模型已给 subtasks 的条目尊重原结构")
    }

    private static func testMergePlanCommonDateCarriedToParent() {
        let candidates = [
            task("交物业费", dueDate: "下周一"),
            task("停快递", dueDate: "下周一"),
        ]
        let plan = TaskGroupMergePlanner.mergePlan(for: candidates, originalText: "下周一交物业费和停快递")
        expect(plan != nil, "同日条目相容可合并")
        expect(plan?.plan.renderData["dueDate"] == "下周一", "共同日期上提为主任务日期")
    }

    private static func testMergePlanSingleTaskStaysAlone() {
        let candidates = [task("买牛奶"), other()]
        let plan = TaskGroupMergePlanner.mergePlan(for: candidates, originalText: "提醒我买牛奶")
        expect(plan == nil, "单条待办不合并")
    }

    private static func testMergedGroupTitleStripsPolitenessAndCaps() {
        expect(
            TaskGroupMergePlanner.mergedGroupTitle(from: "帮我安排下周出差的事，摩卡找物业来照顾") == "安排下周出差的事",
            "首分句做标题并去掉「帮我」开头"
        )
        expect(
            TaskGroupMergePlanner.mergedGroupTitle(from: "买牛奶、取快递、交电费") == "买牛奶、取快递、交电费",
            "枚举式原话整体做标题"
        )
        expect(
            TaskGroupMergePlanner.mergedGroupTitle(from: "这个月的工作总结和下季度的目标规划要安排一下") == "这个月的工作总结和下季度的目标规",
            "长首分句截断到 16 字"
        )
    }

    // MARK: 署名兜底

    private static func testAttributionReconcilerMatchesContentWords() {
        let entries = [
            HoloMemoryAttributionReconciler.Entry(id: "m1", text: "摩卡\n用户养了一只猫，出差时担心没人喂"),
            HoloMemoryAttributionReconciler.Entry(id: "m2", text: "昆明\n用户上个月去过昆明出差"),
        ]
        let matched = HoloMemoryAttributionReconciler.matchedMemoryIDs(
            reply: "家里主要是摩卡的事，你上次去昆明就担心没人喂。",
            entries: entries
        )
        expect(matched == ["m1", "m2"], "回复内容命中两条记忆，实际：\(matched)")

        let unmatched = HoloMemoryAttributionReconciler.matchedMemoryIDs(
            reply: "今天天气不错，适合出门走走。",
            entries: entries
        )
        expect(unmatched.isEmpty, "无关回复不误署名")
    }

    private static func testAttributionReconcilerEmptyInputs() {
        expect(
            HoloMemoryAttributionReconciler.matchedMemoryIDs(reply: "", entries: [
                HoloMemoryAttributionReconciler.Entry(id: "m1", text: "摩卡")
            ]).isEmpty,
            "空回复不署名"
        )
        expect(
            HoloMemoryAttributionReconciler.matchedMemoryIDs(reply: "摩卡", entries: []).isEmpty,
            "无注入条目不署名"
        )
    }
}
