import Foundation

/// 子任务字符串解析器
/// 将 LLM 返回的逗号分隔子任务字符串解析为 [String]
nonisolated enum SubtaskParser {
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
