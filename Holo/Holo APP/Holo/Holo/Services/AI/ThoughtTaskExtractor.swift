//
//  ThoughtTaskExtractor.swift
//  Holo
//
//  AI 从想法文本里提取待办任务标题
//  走后端专用 purpose（thought_task_extraction），读一篇笔记 → 返回 JSON 任务标题数组。
//

import Foundation
import OSLog

/// AI 从想法里提取出的任务标题列表
struct ThoughtTaskExtractionResult: Equatable {
    let titles: [String]
}

/// 从想法文本提取任务的服务。
///
/// 设计说明：照搬 `ThoughtOrganizationService` 的范式——
/// 把想法正文编码成 JSON 放进 user 消息（数据/指令分离，避免正文自然语言被当成指令），
/// 走后端专用 `thought_task_extraction` purpose，由后端注入专用 prompt，
/// 返回 `{"tasks":["标题1","标题2"]}` 形式的 JSON。
@MainActor
final class ThoughtTaskExtractor {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtTaskExtractor")
    private let aiProvider: HoloBackendAIProvider

    init(aiProvider: HoloBackendAIProvider? = nil) {
        self.aiProvider = aiProvider ?? HoloBackendAIProvider()
    }

    /// 从一段想法文本里提取待办任务标题。
    ///
    /// - Parameter content: 想法的纯文本内容（保留段落换行）
    /// - Returns: 提取出的任务标题列表；若 AI 未识别出待办则返回空数组
    func extract(from content: String) async throws -> ThoughtTaskExtractionResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ThoughtTaskExtractionResult(titles: [])
        }

        let payload = buildPayload(thoughtContent: trimmed)
        let messages: [ChatMessageDTO] = [.user(payload)]

        let raw = try await aiProvider.chat(messages: messages, purpose: .thoughtTaskExtraction)

        guard let titles = parseTitles(from: raw), !titles.isEmpty else {
            logger.info("想法提取任务：AI 未识别出待办")
            return ThoughtTaskExtractionResult(titles: [])
        }

        logger.info("想法提取任务：识别出 \(titles.count) 项")
        return ThoughtTaskExtractionResult(titles: titles)
    }

    // MARK: - JSON 构造与解析

    /// 把想法文本包进 JSON，避免正文被后端误当成指令执行
    private func buildPayload(thoughtContent: String) -> String {
        let payload: [String: Any] = [
            "thoughtContent": thoughtContent
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"thoughtContent\":\"\"}"
        }
        return json
    }

    /// 解析 AI 返回的 `{"tasks": ["...", "..."]}`
    private func parseTitles(from text: String) -> [String]? {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 兼容 tasks / items / todos 几种可能的字段名
        let rawTitles = (json["tasks"] as? [String])
            ?? (json["items"] as? [String])
            ?? (json["todos"] as? [String])
            ?? ((json["tasks"] as? [[String: Any]])?.compactMap { $0["title"] as? String })

        return rawTitles?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
    }

    /// 从 AI 输出中提取 JSON 字符串（处理 markdown code fence 和前后缀）
    private func extractJSON(from text: String) -> String {
        if let range = text.range(of: "```json") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let range = text.range(of: "```") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
