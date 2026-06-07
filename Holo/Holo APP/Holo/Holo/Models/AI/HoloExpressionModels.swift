//
//  HoloExpressionModels.swift
//  Holo
//
//  Holo 表达强度模型。用于告诉 AI 应该看见、归纳、提醒还是给行动建议。
//

import Foundation

enum HoloExpressionLevel: String, Codable, Equatable {
    case observe
    case summarize
    case remind
    case suggestAction
    case celebrate
}

struct HoloExpressionDecision: Codable, Equatable {
    let level: HoloExpressionLevel
    let confidence: Double
    let evidenceCount: Int
    let allowedVerbs: [String]
    let bannedPhrases: [String]
    let reason: String

    var promptSummary: String {
        """
        本次表达强度：\(level.rawValue)
        允许：\(allowedVerbs.joined(separator: "、"))
        禁止：\(bannedPhrases.joined(separator: "、"))
        证据数量：\(evidenceCount)
        原因：\(reason)
        """
    }
}

