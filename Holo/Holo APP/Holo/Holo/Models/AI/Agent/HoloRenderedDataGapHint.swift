//
//  HoloRenderedDataGapHint.swift
//  Holo
//
//  Agent 分析结果中「可能遗漏数据」提示的展示模型。
//

import Foundation

/// 分析卡片向用户展示的一组可能遗漏数据。
///
/// 字段保持为值类型，便于随 Agent 结果一起 Codable 持久化；`id` 使用稳定的
/// 语义组合值，避免每次从历史消息恢复时生成新的 UUID 导致 SwiftUI 重复渲染。
nonisolated struct HoloRenderedDataGapHint: Codable, Equatable, Identifiable, Sendable {
    let description: String
    let complexity: String
    let suggestedKeywords: [String]
    let sampleExcerpts: [String]

    var id: String {
        "\(complexity)|\(description)"
    }
}
