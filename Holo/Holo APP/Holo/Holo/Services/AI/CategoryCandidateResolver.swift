import Foundation

enum CategoryCandidateResolver {

    static func orderedCandidates(
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String?,
        hour: Int
    ) -> [String] {
        uniqueCategoryCandidates([
            categoryCandidate,
            normalizedCategoryCandidate,
            normalizedMealCandidate(
                categoryCandidate: categoryCandidate,
                normalizedCategoryCandidate: normalizedCategoryCandidate,
                note: note,
                hour: hour
            ),
            semanticCategoryHint
        ])
    }

    private static func normalizedMealCandidate(
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        note: String?,
        hour: Int
    ) -> String? {
        let text = [categoryCandidate, normalizedCategoryCandidate, note]
            .compactMap { $0 }
            .joined(separator: " ")

        if text.contains("早餐") || text.contains("早饭") || text.contains("早点") {
            return "早餐"
        }
        if text.contains("午餐") || text.contains("午饭") || text.contains("中饭") {
            return "午餐"
        }
        if text.contains("晚餐") || text.contains("晚饭") {
            return "晚餐"
        }
        if text.contains("夜宵") || text.contains("宵夜") {
            return "夜宵"
        }

        let genericMealKeywords = ["吃饭", "吃个饭", "饭钱", "外卖", "快餐"]
        guard genericMealKeywords.contains(where: { text.contains($0) }) else {
            return nil
        }

        switch hour {
        case 5..<10: return "早餐"
        case 10..<16: return "午餐"
        case 16..<21: return "晚餐"
        default: return "夜宵"
        }
    }

    private static func uniqueCategoryCandidates(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !candidate.isEmpty else { continue }
            let key = candidate.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(candidate)
        }

        return result
    }
}
