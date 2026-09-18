//
//  GoalWorkshopPromptBuilder.swift
//  Holo
//
//  目标共创请求体构建（方案任务 4 / §2.2）
//
//  模型调用的 user message 是版本化 JSON 请求（GoalWorkshopRequestV1）：
//  范围受限的会话快照 + 经授权的上下文引用，不塞完整 UserContext 或聊天原文。
//  系统 Prompt 由后端 goal_workshop purpose 注入（iOS 端 PromptManager.goalWorkshop
//  仅为本地开发后备，语义与后端 v1 对齐）。
//

import Foundation

enum GoalWorkshopPromptBuilder {

    /// 构建发给模型的 JSON 请求体（user message 内容）
    static func requestBody(
        session: GoalWorkshopSessionV1,
        operation: GoalWorkshopRequestV1.Operation,
        input: String? = nil,
        skippedQuestion: Bool = false,
        contextRefs: [GoalWorkshopContextRef] = [],
        timeZone: TimeZone = .current
    ) -> String {
        let request = GoalWorkshopRequestV1(
            sessionID: session.id,
            revision: session.revision,
            operation: operation,
            input: input,
            skippedQuestion: skippedQuestion,
            sessionSnapshot: session.buildSnapshot(timeZone: timeZone),
            contextRefs: contextRefs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(request),
              let json = String(data: data, encoding: .utf8) else {
            // 契约类型全 Codable；编码失败属程序错误，给可诊断的空体让校验层报错
            return "{}"
        }
        return json
    }

    /// 从模型输出提取 JSON 文本（容错围栏/前后缀；正文不是 JSON 时返回原文交由解码报错）
    static func extractResponseBody(_ text: String) -> String {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            // ```json ... ``` 围栏：剥掉首尾行
            if let firstNewline = candidate.firstIndex(of: "\n") {
                candidate = String(candidate[candidate.index(after: firstNewline)...])
            }
            if let fenceEnd = candidate.range(of: "```", options: .backwards) {
                candidate = String(candidate[..<fenceEnd.lowerBound])
            }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}") {
            return String(candidate[start...end])
        }
        return candidate
    }
}
