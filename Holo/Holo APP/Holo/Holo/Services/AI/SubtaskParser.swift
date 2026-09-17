import Foundation

/// 子任务字符串解析器
/// 将 LLM 返回的逗号分隔子任务字符串解析为 [String]
nonisolated enum SubtaskParser {
    static let maxSubtasks = 10
    static let maxTitleLength = 50

    /// - Parameter allowsSingle: 允许解析出单项。
    ///   create_task 沿用默认 false（约定"单项不算清单"）；
    ///   modify_task_items 的 addItems/removeItems 单项完全合法，必须传 true。
    static func parse(_ raw: String?, allowsSingle: Bool = false) -> [String] {
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

        if allowsSingle { return limited }
        return limited.count >= 2 ? limited : []
    }
}

/// 提醒时间槽位解析器
/// 汇总 LLM 返回的用户指定提醒时间：reminderDates（逗号分隔多个）+ reminderDate（单个，兼容）
nonisolated enum ReminderSlotParser {
    static func parse(from data: [String: String]) -> [String] {
        let multi = SubtaskParser.parse(data["reminderDates"], allowsSingle: true)
        let single = data["reminderDate"].map { [$0] } ?? []
        var seen = Set<String>()
        return (multi + single)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
