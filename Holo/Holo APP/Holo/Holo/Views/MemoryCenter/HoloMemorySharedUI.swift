//
//  HoloMemorySharedUI.swift
//  Holo
//
//  记忆中心共用小组件：行标签徽章 + 投影→标签翻译（列表与详情共用同一套，§4.4）
//

import SwiftUI

struct HoloMemoryTagBadge: View {
    struct Tag: Hashable {
        enum Tone { case success, info, warning, neutral }
        let text: String
        let tone: Tone
    }

    let tag: Tag

    var body: some View {
        Text(tag.text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
    }

    private var foreground: Color {
        switch tag.tone {
        case .success: return Color.holoToolSuccess
        case .info: return Color.holoToolInfo
        case .warning: return Color.holoToolWarning
        case .neutral: return Color.holoToolTextSecondary
        }
    }

    private var background: Color {
        switch tag.tone {
        case .success: return Color.holoToolSuccess.opacity(0.1)
        case .info: return Color.holoToolInfo.opacity(0.1)
        case .warning: return Color.holoToolWarning.opacity(0.1)
        case .neutral: return Color.holoToolInset
        }
    }
}

/// 投影 → 行标签的统一翻译（顺序即展示顺序；文字承载状态，颜色只是辅助）。
enum HoloMemoryRowTags {
    static func tags(for projection: HoloMemoryManagementProjection) -> [HoloMemoryTagBadge.Tag] {
        var tags: [HoloMemoryTagBadge.Tag] = []
        // 观察中桶不显示「你确认过/Holo 推断」：桶语义已说明拿不准，
        // 再挂确认标识会自相矛盾；用户亲手改写/添加的标识仍保留。
        let showOrigin: Bool
        switch projection.originLabel {
        case .userConfirmed, .autoFormed:
            showOrigin = projection.bucket != .observing
        case .userCorrected, .userAdded:
            showOrigin = true
        }
        if showOrigin {
            switch projection.originLabel {
            case .userConfirmed: tags.append(.init(text: "你确认过", tone: .success))
            case .userCorrected: tags.append(.init(text: "你纠正过", tone: .success))
            case .userAdded: tags.append(.init(text: "你添加", tone: .success))
            case .autoFormed: tags.append(.init(text: "Holo 推断", tone: .neutral))
            }
        }
        if projection.useLabel == .referenceOnly {
            tags.append(.init(text: "仅作参考", tone: .info))
        }
        if projection.isPausedForAnswering {
            tags.append(.init(text: "已保存 · 暂不使用", tone: .neutral))
        }
        if case .bounded(let until) = projection.effectiveRange {
            tags.append(.init(text: "适用至 \(shortDate(until))", tone: .neutral))
        }
        if let cause = projection.observingCause {
            tags.append(.init(text: observingText(cause), tone: .warning))
        }
        if let cause = projection.historyCause {
            tags.append(.init(text: historyText(cause), tone: .neutral))
        }
        if let cause = projection.stoppedCause {
            tags.append(.init(text: stoppedText(cause), tone: .warning))
        }
        return tags
    }

    static func observingText(_ cause: HoloMemoryManagementObservingCause) -> String {
        switch cause {
        case .awaitingEvidence: return "依据待积累"
        case .conflictPending: return "待厘清"
        case .observeOnly: return "仅可限定参考"
        case .awaitingClarification: return "待澄清"
        case .blockedByPolicy: return "暂不用于回答"
        case .unknownDecisionVersion: return "暂不可用"
        }
    }

    static func historyText(_ cause: HoloMemoryManagementHistoryCause) -> String {
        switch cause {
        case .expired: return "已过期"
        case .superseded: return "已被替代"
        case .sourceInvalidated: return "来源已失效"
        case .archived: return "已过时"
        }
    }

    static func stoppedText(_ cause: HoloMemoryManagementStoppedCause) -> String {
        switch cause {
        case .userStopped: return "你标记 · 不再使用"
        case .markedInaccurate: return "你标记 · 不准确"
        case .legacyUnknown: return "此前已停用"
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
