//
//  HoloMemorySharedUI.swift
//  Holo
//
//  记忆中心共用小组件（减法版契约 = 记忆重构-核心画面原型-减法版.html ①③⑤）：
//  - 行标签徽章（「过去的记忆/已停用」次级页仍用；主列表已改一行灰字）
//  - 四类分组（偏好与约束 / 当前关注 / 重要经历 / 生活规律）
//  - 一行来源灰字（你告诉我的 / 你确认过的 / 来自你的 N 条记录）
//  - 来源异常小圆点（已修改/已删除/待同步，点开一句解释）
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

/// 投影 → 行标签的统一翻译（次级页仍用；主列表与详情已改一行灰字，不再挂胶囊）。
enum HoloMemoryRowTags {
    static func tags(for projection: HoloMemoryManagementProjection) -> [HoloMemoryTagBadge.Tag] {
        var tags: [HoloMemoryTagBadge.Tag] = []
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

// MARK: - 四类分组（原型 ①：分组标题保留，彩色胶囊删除）

/// 已记住列表的四类分组。口径：明确表达的偏好/约束 → 偏好与约束；
/// 周期规律 → 生活规律；生活事件 → 重要经历；其余观察事实/阶段变化 → 当前关注。
enum HoloMemoryListGroup: Int, CaseIterable, Sendable {
    case preference
    case focus
    case milestone
    case rhythm

    var title: String {
        switch self {
        case .preference: return "偏好与约束"
        case .focus: return "当前关注"
        case .milestone: return "重要经历"
        case .rhythm: return "生活规律"
        }
    }

    static func group(for record: HoloMemoryRecord) -> HoloMemoryListGroup {
        switch record.claimKind {
        case .explicitPreference: return .preference
        case .lifeEvent: return .milestone
        case .recurringPattern: return .rhythm
        case .observedFact, .phaseShift, .association, .tension, .hypothesis: return .focus
        }
    }
}

// MARK: - 一行来源灰字（原型 ①③：来源感一行，精确数字在详情）

enum HoloMemorySourceLine {

    /// 列表行灰字：形成方式 + 来源感。
    static func listSubline(origin: HoloMemoryManagementOrigin, record: HoloMemoryRecord) -> String {
        switch origin {
        case .userAdded:
            return hasUserQuote(record) ? "你告诉我的 · 1 句原话" : "你告诉我的"
        case .userCorrected:
            return "你告诉我的 · 你改过一次"
        case .userConfirmed:
            if isRhythm(record) { return "你确认过的 · \(windowPhrase(record))" }
            return "你确认过的"
        case .autoFormed:
            if let weeks = aggregateWindowWeeks(record) {
                return "来自你的 \(weeks) 周记录"
            }
            let count = record.evidenceRefs.count
            return count > 0 ? "来自你的 \(count) 条记录" : "来自你的记录"
        }
    }

    /// 详情页大标题下的灰字（原型 ③「你告诉我的 · 一直有效」/ ④「你确认过的理解」）。
    static func detailSubline(origin: HoloMemoryManagementOrigin, record: HoloMemoryRecord) -> String {
        if isRhythm(record) && origin == .userConfirmed { return "你确认过的理解" }
        let originText: String
        switch origin {
        case .userAdded, .userCorrected: originText = "你告诉我的"
        case .userConfirmed: originText = "你确认过的"
        case .autoFormed: originText = "来自你的记录"
        }
        let duration = durationText(record)
        return duration.isEmpty ? originText : "\(originText) · \(duration)"
    }

    /// 无记录元数据时的兜底（只报形成方式，不编数字）。
    static func originOnlyText(_ origin: HoloMemoryManagementOrigin) -> String {
        switch origin {
        case .userAdded, .userCorrected: return "你告诉我的"
        case .userConfirmed: return "你确认过的"
        case .autoFormed: return "来自你的记录"
        }
    }

    /// 有效期人话（一直有效 / 当前阶段有效 / 适用至 M月d日）。
    static func durationText(_ record: HoloMemoryRecord) -> String {
        if let validTo = record.validTo { return "适用至 \(shortDate(validTo))" }
        switch record.persistenceClass {
        case .currentState, .phase: return "当前阶段有效"
        case .durable, .permanentFact: return "一直有效"
        }
    }

    /// 是否规律型：证据里含一段时间的汇总。
    static func isRhythm(_ record: HoloMemoryRecord) -> Bool {
        record.evidenceRefs.contains { $0.kind == .aggregateSnapshot }
    }

    /// 窗口跨度自然语言（如「6 周记录」）；非规律型返回 nil。
    static func windowPhrase(_ record: HoloMemoryRecord) -> String {
        if let weeks = aggregateWindowWeeks(record) { return "\(weeks) 周记录" }
        return "记录"
    }

    /// 汇总证据观察窗折算的整周数（≥1）；无窗口返回 nil。
    static func aggregateWindowWeeks(_ record: HoloMemoryRecord) -> Int? {
        guard let aggregate = record.evidenceRefs.first(where: { $0.kind == .aggregateSnapshot }) else {
            return nil
        }
        switch (aggregate.validFrom ?? aggregate.observedAt, aggregate.validTo ?? aggregate.observedAt) {
        case let (from, to) where to > from:
            return max(1, Int((to.timeIntervalSince(from) / 86_400 / 7).rounded()))
        default:
            return nil
        }
    }

    private static func hasUserQuote(_ record: HoloMemoryRecord) -> Bool {
        record.evidenceRefs.contains { $0.kind == .explicitUserStatement }
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

// MARK: - 来源异常小圆点（原型 ⑤：行尾小圆点 + 两字，点开一句解释）

/// 三态标记：已修改=琥珀、已删除=红、待同步=灰；点击在行内展开一句解释。
struct HoloMemorySourceStatusMark: View {
    let status: HoloKnowledgeSourceStatus
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                withAnimation(HoloAnimation.quick) { showsExplanation.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                }
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label)来源")

            if showsExplanation {
                Text(explanation)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 两字标记（已修改/已删除/待同步）。
    private var label: String {
        switch status {
        case .revised: return "已修改"
        case .deleted, .excluded, .permissionRevoked: return "已删除"
        case .unknown: return "待同步"
        case .verified: return ""
        }
    }

    private var color: Color {
        switch status {
        case .revised: return Color.holoToolWarning
        case .deleted, .excluded, .permissionRevoked: return Color.holoToolError
        case .unknown: return Color.holoToolTextSecondary
        case .verified: return Color.clear
        }
    }

    /// 点开的一句解释（三态文案契约见完整版⑤；文字承载状态，不靠颜色）。
    private var explanation: String {
        switch status {
        case .revised:
            return "这条来源后来被修改过，Holo 会重新核对后再使用这里的理解。"
        case .deleted:
            return "这条来源记录已被删除，Holo 不再把它当作依据。"
        case .excluded:
            return "这条来源被设为不参与 AI，不再作为这条理解的依据。"
        case .permissionRevoked:
            return "这条来源的授权已收回，暂时无法核对。"
        case .unknown:
            return "这条来源暂时无法核验，可能在等其他设备同步，并没有被删除。"
        case .verified:
            return ""
        }
    }
}
