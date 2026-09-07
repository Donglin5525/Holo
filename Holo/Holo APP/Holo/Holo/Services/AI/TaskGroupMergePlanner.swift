//
//  TaskGroupMergePlanner.swift
//  Holo
//
//  同一句话里多条待办的合并判定（1 主任务 + 子条目）。
//
//  一句话里连续报出的多件事（出差五天，摩卡找物业来照顾，提醒我拿快递，
//  换水，关水电）是同一个场景，拆成一堆碎片任务会污染待办列表且丢失归属。
//  本文件只做判定与装配：日期相容（都无日期或同一天）→ 合并；日期各异的
//  条目是时间锚定的独立提醒，保持独立。纯逻辑，可 standalone 测试。
//

import Foundation

nonisolated enum TaskGroupMergePlanner {
    /// 合并判定的最小输入：只关心「是不是 create_task」和结构化字段，
    /// 不依赖意图识别的完整模型链，可脱离 App 编译测试。
    struct Candidate: Equatable, Sendable {
        let isCreateTask: Bool
        let extractedData: [String: String]?
    }

    struct MergePlan: Equatable, Sendable {
        /// 合并后确认卡的 renderData（title = 主任务标题，subtasks = 「、」串联）。
        var renderData: [String: String]
        /// 参与合并的条目数。
        var memberCount: Int
    }

    /// 在一轮候选里定位可合并的 create_task 组。
    /// 返回值 `anchorIndex` 是组的第一个成员下标（由它产出合并确认卡），
    /// `memberIndices` 是全部成员下标（其余成员跳过单独出卡）。
    /// 不可合并时返回 nil，全部条目保持独立确认卡。
    static func mergePlan(
        for candidates: [Candidate],
        originalText: String
    ) -> (anchorIndex: Int, plan: MergePlan, memberIndices: Set<Int>)? {
        let taskEntries = candidates.enumerated().filter { $0.element.isCreateTask }
        guard taskEntries.count >= 2 else { return nil }

        let titles = taskEntries.compactMap { $0.element.extractedData?["title"] }
        guard titles.count == taskEntries.count, titles.allSatisfy({ !$0.isEmpty }) else { return nil }
        // 标题自身含子条目分隔符：合并后子条目拆分会错位，保持独立
        let subtaskSeparators = CharacterSet(charactersIn: "，,、;；")
        guard !titles.contains(where: { title in
            title.unicodeScalars.contains { subtaskSeparators.contains($0) }
        }) else { return nil }
        // 模型已按子条目拆好的（带 subtasks 字段）尊重原结构，不二次合并
        guard taskEntries.allSatisfy({ ($0.element.extractedData?["subtasks"] ?? "").isEmpty }) else { return nil }

        let dates = Set(taskEntries.compactMap {
            $0.element.extractedData?["dueDate"] ?? $0.element.extractedData?["reminderDate"]
        })
        guard dates.count <= 1 else { return nil }

        var renderData = taskEntries[0].element.extractedData ?? [:]
        renderData["title"] = mergedGroupTitle(from: originalText)
        renderData["subtasks"] = titles.joined(separator: "、")
        if let commonDate = dates.first {
            renderData["dueDate"] = commonDate
        }
        renderData.removeValue(forKey: "reminderDate")
        return (
            anchorIndex: taskEntries[0].offset,
            plan: MergePlan(renderData: renderData, memberCount: taskEntries.count),
            memberIndices: Set(taskEntries.map(\.offset))
        )
    }

    /// 合并主任务标题：取原话第一个分句（去掉「帮我/请/麻烦」开头），限 16 字。
    /// 分句符不含「、」：枚举式原话（买牛奶、取快递、交电费）整体做主任务标题更达意。
    static func mergedGroupTitle(from text: String) -> String {
        let clauseSeparators = CharacterSet(charactersIn: "，,。；;？?！!\n")
        var title = text.components(separatedBy: clauseSeparators).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = text }
        for prefix in ["帮我", "请帮忙", "麻烦", "请"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if title.isEmpty { title = text }
        return String(title.prefix(16))
    }
}
