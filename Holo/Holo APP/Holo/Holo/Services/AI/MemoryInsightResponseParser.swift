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

    // MARK: - Post-Process

    /// 为卡片填充 moduleHint / patternType（基于 card.type + 关键词匹配）
    /// 不改 Prompt 输出 schema，纯本地后处理
    static func fillModuleHints(_ payload: MemoryInsightPayload) -> MemoryInsightPayload {
        let processedCards = payload.cards.map { card -> MemoryInsightCard in
            // 已有 moduleHint 的不覆盖
            if card.moduleHint != nil { return card }

            let hint = deriveModuleHint(for: card)
            let pattern = derivePatternType(for: card)

            if hint != nil || pattern != nil {
                return MemoryInsightCard(
                    id: card.id,
                    type: card.type,
                    title: card.title,
                    body: card.body,
                    evidence: card.evidence,
                    suggestedQuestion: card.suggestedQuestion,
                    anomalySeverity: card.anomalySeverity,
                    moduleHint: hint,
                    patternType: pattern,
                    memoryCandidate: card.memoryCandidate
                )
            }
            return card
        }

        return MemoryInsightPayload(
            title: payload.title,
            summary: payload.summary,
            cards: processedCards,
            suggestedQuestions: payload.suggestedQuestions
        )
    }

    // MARK: - Hint Derivation

    private static func deriveModuleHint(for card: MemoryInsightCard) -> String? {
        switch card.type {
        case .habit, .finance, .task, .thought, .milestone:
            return nil // 直接映射类型无需 hint
        case .overview:
            return deriveOverviewHint(text: card.title + " " + card.body)
        case .crossDomain:
            return "crossDomain"
        case .anomaly:
            return deriveAnomalyHint(text: card.title + " " + card.body)
        }
    }

    private static func deriveOverviewHint(text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("睡眠") || lower.contains("步数") || lower.contains("运动") || lower.contains("站立") {
            return "health"
        }
        return nil
    }

    private static func deriveAnomalyHint(text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("消费") || lower.contains("支出") || lower.contains("餐饮") || lower.contains("预算") {
            return "finance"
        }
        if lower.contains("习惯") || lower.contains("打卡") || lower.contains("断连") {
            return "habit"
        }
        if lower.contains("任务") || lower.contains("逾期") || lower.contains("待办") {
            return "task"
        }
        return nil
    }

    private static func derivePatternType(for card: MemoryInsightCard) -> String? {
        let lower = (card.title + " " + card.body).lowercased()
        if lower.contains("消费突增") || lower.contains("支出升高") { return "spending_increase" }
        if lower.contains("习惯断连") || lower.contains("打卡中断") { return "habit_break" }
        if lower.contains("任务堆积") || lower.contains("逾期") { return "task_backlog" }
        if lower.contains("恢复") { return "recovery" }
        return nil
    }
}
