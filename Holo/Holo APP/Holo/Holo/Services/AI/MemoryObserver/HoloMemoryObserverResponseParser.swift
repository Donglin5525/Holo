//
//  HoloMemoryObserverResponseParser.swift
//  Holo
//
//  Observer LLM 输出解析器：提取 JSON、解码为结构化类型
//

import Foundation
import OSLog

struct HoloMemoryObserverOutput: Codable {
    var newEpisodicMemories: [NewEpisodicMemoryEntry]
    var memoryHits: [MemoryHitEntry]
    var weakenedOrExpiredMemories: [WeakenedEntry]
}

struct NewEpisodicMemoryEntry: Codable {
    var title: String
    var memoryText: String
    var confidence: Double
    var sensitivity: String
    var visibility: String
    var evidenceRefs: [String]
    var reasoningSummary: String
    var expiresInDays: Int
}

struct MemoryHitEntry: Codable {
    var episodicMemoryID: String
    var hitReasoning: String
}

struct WeakenedEntry: Codable {
    var episodicMemoryID: String
    var reason: String
}

enum HoloMemoryObserverResponseParser {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryObserverParser")

    /// 解析 Observer LLM 输出
    /// - Returns: 解析成功返回 output，失败返回 nil（不 throw，失败兜底）
    static func parse(_ rawResponse: String) -> HoloMemoryObserverOutput? {
        let json = extractJSON(from: rawResponse)
        guard let jsonData = json.data(using: .utf8) else {
            logger.error("JSON 字符串转 Data 失败")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(HoloMemoryObserverOutput.self, from: jsonData)
        } catch {
            logger.error("Observer 输出解码失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 从可能的 markdown code block 中提取 JSON
    private static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试提取 ```json ... ``` 包裹的内容
        if let jsonBlockRange = extractCodeBlock(from: trimmed) {
            return String(trimmed[jsonBlockRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 尝试直接找 { ... } 包裹的内容
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            return String(trimmed[firstBrace...lastBrace])
        }

        return trimmed
    }

    private static func extractCodeBlock(from text: String) -> Range<String.Index>? {
        // 匹配 ```json ... ``` 或 ``` ... ```
        let patterns = ["```json\n", "```\n", "```"]
        for prefix in patterns {
            if let blockStart = text.range(of: prefix) {
                let contentStart = blockStart.upperBound
                if let blockEnd = text.range(of: "```", range: contentStart..<text.endIndex) {
                    return contentStart..<blockEnd.lowerBound
                }
            }
        }
        return nil
    }
}
