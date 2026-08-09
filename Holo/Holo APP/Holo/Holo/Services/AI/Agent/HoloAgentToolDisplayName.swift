//
//  HoloAgentToolDisplayName.swift
//  Holo
//
//  Agent 工具名 → 用户可见中文名映射。
//  用于「AI 正在翻阅账单 / 回顾记忆」这类思考过程可见化提示。
//  中文命名与 HoloMetricSemanticCatalog.topic() 保持一致，保证用词统一。
//

import Foundation

nonisolated enum HoloAgentToolDisplayName {

    /// 把工具内部名（finance / memory / thought …）翻译成中文动词短语。
    /// - Parameter toolName: checkpoint 里记录的 `tool` 字段（HoloToolRequest.tool / HoloDataToolResult.tool）。
    /// - Returns: 用户可见的「正在 …」短语；未知工具返回 nil（调用方自行兜底）。
    static func phrase(forTool toolName: String) -> String? {
        switch toolName {
        case "finance":
            return "翻阅账单"
        case "memory":
            return "回顾记忆"
        case "thought":
            return "查阅想法"
        case "task":
            return "核对任务"
        case "goal":
            return "查看目标"
        case "habit":
            return "查看习惯打卡"
        case "health":
            return "读取健康数据"
        case "insight":
            return "回顾洞察"
        case "profile":
            return "读取个人档案"
        case "conversation":
            return "回顾对话历史"
        // 内部辅助工具：不直接对应单一用户数据域，对外不展示具体动作。
        case "discover", "cross_domain", "project", "feedback", "thought_reference":
            return nil
        default:
            return nil
        }
    }

    /// 把一组工具名聚合成一句中文，如 ["finance", "memory"] → "正在翻阅账单、回顾记忆"。
    /// 未知工具自动过滤；去重并保持首次出现顺序；全部未知时返回 nil。
    static func readingPhrase(forTools toolNames: [String]) -> String? {
        var seen = Set<String>()
        var phrases: [String] = []
        for name in toolNames {
            guard let phrase = phrase(forTool: name), !seen.contains(phrase) else { continue }
            seen.insert(phrase)
            phrases.append(phrase)
        }
        guard !phrases.isEmpty else { return nil }
        return "正在" + phrases.joined(separator: "、")
    }
}
