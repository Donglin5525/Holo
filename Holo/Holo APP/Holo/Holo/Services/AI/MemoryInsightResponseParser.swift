//
//  MemoryInsightResponseParser.swift
//  Holo
//
//  记忆洞察 AI 响应解析器
//  三层 JSON 提取 + Schema 校验
//

import Foundation
import os.log

/// 解析 AI 返回的洞察 JSON
enum MemoryInsightResponseParser {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightResponseParser")

    // MARK: - Parse

    /// 三层降级解析：直接解析 → 代码块提取 → 花括号提取
    static func parse(_ raw: String) -> MemoryInsightPayload? {
        // 1. 直接解析
        if let payload = tryParse(raw) {
            return validate(payload) ? payload : nil
        }

        // 2. 提取 ```json ... ``` 代码块
        if let extracted = extractCodeBlock(raw),
           let payload = tryParse(extracted),
           validate(payload) {
            return payload
        }

        // 3. 提取第一个 { ... }
        if let extracted = extractFirstBraces(raw),
           let payload = tryParse(extracted),
           validate(payload) {
            return payload
        }

        logger.error("洞察 JSON 解析全部失败，原始响应前 200 字：\(raw.prefix(200))")
        return nil
    }

    // MARK: - Direct Parse

    private static func tryParse(_ text: String) -> MemoryInsightPayload? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(MemoryInsightPayload.self, from: data)
    }

    // MARK: - Extract Code Block

    private static func extractCodeBlock(_ text: String) -> String? {
        guard let range = text.range(of: "```json") else { return nil }
        let afterMarker = text[range.upperBound...]
        guard let endRange = afterMarker.range(of: "```") else { return nil }
        return String(afterMarker[..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extract First Braces

    private static func extractFirstBraces(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[start...end])
    }

    // MARK: - Schema Validation

    /// 校验载荷基本结构完整性
    static func validate(_ payload: MemoryInsightPayload) -> Bool {
        // title 和 summary 非空
        guard !payload.title.isEmpty,
              !payload.summary.isEmpty,
              payload.summary.count <= 100,
              payload.cards.count >= 1,
              payload.cards.count <= 8 else {
            return false
        }

        // 验证每张卡的 type 在枚举范围内
        for card in payload.cards {
            guard !card.title.isEmpty,
                  !card.body.isEmpty,
                  MemoryInsightCardType(rawValue: card.type.rawValue) != nil else {
                return false
            }
        }

        return true
    }
}
