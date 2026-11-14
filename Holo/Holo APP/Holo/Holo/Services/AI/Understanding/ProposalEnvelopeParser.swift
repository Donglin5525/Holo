//
//  ProposalEnvelopeParser.swift
//  Holo
//
//  提案输出解析器（从 RealClient 拆出：轻量独立，standalone 可测不拖 Provider 依赖）。
//  容忍 ```json 围栏与前后噪声（对齐生产口径 HoloPersonalContextValidator.extractJSON）。
//

import Foundation

nonisolated struct ProposalEnvelope: Codable, Equatable, Sendable {
    var candidates: [ProposalCandidate] = []
    var noValueReason: String?
}

/// 提案输出解析器（从 RealClient 拆出：standalone 测试可直编，不拖 Provider 依赖）。
/// 容忍 ```json 围栏与前后噪声（对齐生产口径 HoloPersonalContextValidator.extractJSON）。
nonisolated enum ProposalEnvelopeParser {
    enum ParseError: Error { case notJSON(String) }

    static func parse(from raw: String) throws -> ProposalEnvelope {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "```\\s*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 首个 { 到最后一个 } 的包围（提案对象无尾随内容场景的最简平衡提取）。
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            text = String(text[first...last])
        }
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ProposalEnvelope.self, from: data) else {
            throw ParseError.notJSON(text.prefix(80).description)
        }
        return envelope
    }
}

