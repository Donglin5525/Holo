//
//  ThoughtTaskExtractor.swift
//  Holo
//
//  AI 从想法文本里提取待办任务（标题 + 日期/优先级预填）
//  走后端专用 purpose（thought_task_extraction），读一篇笔记 → 返回 JSON 任务数组。
//

import Foundation
import OSLog

/// AI 从想法里提取出的单条任务：标题 + 可选的日期/优先级预填
struct ExtractedThoughtTask: Equatable {
    let title: String
    /// AI 识别出的截止日期（已按 dueTime 合并钟点）；未识别为 nil
    let dueDate: Date?
    /// AI 是否给了具体钟点（决定落库时的全天/定时）
    let dueDateHasTime: Bool
    let priority: TaskPriority?

    init(title: String, dueDate: Date? = nil, dueDateHasTime: Bool = false, priority: TaskPriority? = nil) {
        self.title = title
        self.dueDate = dueDate
        self.dueDateHasTime = dueDateHasTime
        self.priority = priority
    }
}

/// AI 从想法里提取出的任务列表
struct ThoughtTaskExtractionResult: Equatable {
    let tasks: [ExtractedThoughtTask]
}

/// 从想法文本提取任务的服务。
///
/// 设计说明：照搬 `ThoughtOrganizationService` 的范式——
/// 把想法正文编码成 JSON 放进 user 消息（数据/指令分离，避免正文自然语言被当成指令），
/// 走后端专用 `thought_task_extraction` purpose，由后端注入专用 prompt。
/// 后端 v2 契约返回 `{"tasks":[{"title":"…","dueDate":"yyyy-MM-dd","dueTime":"HH:mm","priority":"high"}]}`，
/// 兼容旧契约 `{"tasks":["标题1","标题2"]}`（此时没有日期/优先级预填）。
@MainActor
final class ThoughtTaskExtractor {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtTaskExtractor")
    private let aiProvider: HoloBackendAIProvider

    init(aiProvider: HoloBackendAIProvider? = nil) {
        self.aiProvider = aiProvider ?? HoloBackendAIProvider()
    }

    /// 从一段想法文本里提取待办任务。
    ///
    /// - Parameter content: 想法的纯文本内容（保留段落换行）
    /// - Returns: 提取出的任务列表；若 AI 未识别出待办则返回空数组
    func extract(from content: String) async throws -> ThoughtTaskExtractionResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ThoughtTaskExtractionResult(tasks: [])
        }

        let payload = buildPayload(thoughtContent: trimmed)
        let messages: [ChatMessageDTO] = [.user(payload)]

        let raw = try await aiProvider.chat(messages: messages, purpose: .thoughtTaskExtraction)

        guard let tasks = parseTasks(from: raw), !tasks.isEmpty else {
            logger.info("想法提取任务：AI 未识别出待办")
            return ThoughtTaskExtractionResult(tasks: [])
        }

        logger.info("想法提取任务：识别出 \(tasks.count) 项")
        return ThoughtTaskExtractionResult(tasks: tasks)
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

    /// 解析 AI 返回的 `{"tasks":[…]}`；元素兼容字符串（旧契约）与对象（v2 契约）
    private func parseTasks(from text: String) -> [ExtractedThoughtTask]? {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 兼容 tasks / items / todos 几种可能的字段名
        let objects = (json["tasks"] as? [[String: Any]])
            ?? (json["items"] as? [[String: Any]])
            ?? (json["todos"] as? [[String: Any]])
        let strings = (json["tasks"] as? [String])
            ?? (json["items"] as? [String])
            ?? (json["todos"] as? [String])

        let rawItems: [[String: Any]]
        if let objects {
            rawItems = objects
        } else if let strings {
            rawItems = strings.map { ["title": $0] }
        } else {
            return nil
        }

        return rawItems.compactMap { item in
            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, title.count <= 120 else { return nil }
            return ExtractedThoughtTask(
                title: title,
                dueDate: Self.parseDueDate(item["dueDate"] as? String, time: item["dueTime"] as? String),
                dueDateHasTime: ((item["dueTime"] as? String) ?? "").isEmpty == false,
                priority: Self.parsePriority(item["priority"] as? String)
            )
        }
    }

    /// AI 输出是外部边界，日期/时间只认标准格式，不合规就整体放弃预填
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func parseDueDate(_ dateText: String?, time timeText: String?) -> Date? {
        guard let dateText, dateText.count >= 10,
              let date = isoDateFormatter.date(from: String(dateText.prefix(10))) else {
            return nil
        }
        guard let timeText,
              let time = timeFormatter.date(from: String(timeText.prefix(5))) else {
            return date
        }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        return calendar.date(from: components) ?? date
    }

    static func parsePriority(_ raw: String?) -> TaskPriority? {
        switch raw?.lowercased() {
        case "urgent": return .urgent
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        default: return nil
        }
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
