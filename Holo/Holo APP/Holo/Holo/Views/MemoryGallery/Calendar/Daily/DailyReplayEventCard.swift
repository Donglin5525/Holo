//
//  DailyReplayEventCard.swift
//  Holo
//
//  日回放「记忆时刻」卡片：模块色只服务于小面积识别，正文保持安静统一。
//  同一分钟、同模块的多条记录在一张卡内呈现，减少机械重复。
//

import SwiftUI

struct DailyReplayEventCard: View {
    let moment: DailyReplayMoment
    let onSelect: (CalendarEvent) -> Void
    let onSelectGroup: ([CalendarEvent]) -> Void

    /// 兼容「当天记录」等旧调用；新日回放统一走 moment 初始化。
    init(event: CalendarEvent,
         onSelect: @escaping (CalendarEvent) -> Void,
         timeTextOverride: String? = nil) {
        self.moment = DailyReplayPresentation.moments(from: [event])[0]
        self.onSelect = onSelect
        self.onSelectGroup = { events in
            if let first = events.first { onSelect(first) }
        }
    }

    init(moment: DailyReplayMoment,
         onSelect: @escaping (CalendarEvent) -> Void,
         onSelectGroup: @escaping ([CalendarEvent]) -> Void) {
        self.moment = moment
        self.onSelect = onSelect
        self.onSelectGroup = onSelectGroup
    }

    var body: some View {
        if moment.module == .thought, let firstImaged = moment.events.first(where: { !$0.attachmentThumbnails.isEmpty }) {
            // 带图想法走册页风照片堆；照片随首条带图事件，轻点直达想法详情页
            PolaroidMomentCard(moment: moment) {
                onSelect(firstImaged)
            }
        } else {
            replayCard
        }
    }

    private var replayCard: some View {
        Button(action: openMoment) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: HoloSpacing.sm) {
                    moduleBadge
                    Spacer(minLength: 0)
                    if let count = moment.recordCountText {
                        Text(count)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.holoTextPlaceholder)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                    Text(moment.title)
                        .font(titleFont)
                        .foregroundColor(.holoTextPrimary)
                        .multilineTextAlignment(.leading)
                        // 想法的正文就是内容本身，回看时要能直接读到当时的念头，
                        // 因此比其他模块放得宽；仍超长的给出「查看全文」提示。
                        .lineLimit(moment.module == .thought ? 6 : 2)
                    Spacer(minLength: 4)
                    if let valueText {
                        Text(valueText)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(valueColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }

                if let context = moment.contextText, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                }

                if thoughtNeedsFullTextHint {
                    Text("轻点查看全文")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoPrimary.opacity(0.85))
                }

                if moment.events.count > 1 {
                    groupedRecords
                } else if let topics = moment.events.first?.relatedTopics, !topics.isEmpty {
                    topicTags(topics)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.58), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var moduleBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: moment.module.iconName)
                .font(.system(size: 10, weight: .semibold))
            Text(moment.module.displayName)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(moment.module.color)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(moment.module.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var titleFont: Font {
        moment.module == .thought
            ? .system(size: 15, weight: .semibold, design: .serif)
            : .system(size: 15, weight: .semibold)
    }

    /// 想法正文是否长过 6 行：按卡片实际可用宽度量一次文本高度。
    /// 宽度取「屏宽 − 页边距 − 时间列 − 卡内边距」的近似值，误差只会让临界长文少/多出一次提示。
    private var thoughtNeedsFullTextHint: Bool {
        guard moment.module == .thought else { return false }
        let base = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 15) } ?? base
        let availableWidth = UIScreen.main.bounds.width - 116
        let textHeight = (moment.title as NSString).boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        return textHeight > font.lineHeight * 6.5
    }

    @ViewBuilder
    private var groupedRecords: some View {
        if moment.module == .habit {
            HStack(spacing: 7) {
                ForEach(Array(moment.events.prefix(4))) { event in
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                        Text(event.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(Color.holoSuccess.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.holoSuccess.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
        } else {
            VStack(spacing: 7) {
                ForEach(Array(moment.events.prefix(4))) { event in
                    HStack(spacing: HoloSpacing.sm) {
                        Text(event.title)
                            .lineLimit(1)
                        Spacer(minLength: HoloSpacing.sm)
                        if let detail = event.detail {
                            Text(detail)
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                }
                if moment.events.count > 4 {
                    Text("另有 \(moment.events.count - 4) 条")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoTextPlaceholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 9)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.holoBorder.opacity(0.42))
                    .frame(height: 1)
            }
        }
    }

    private func topicTags(_ topics: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(topics.prefix(3)), id: \.self) { topic in
                Text(topic)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.holoNestedCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color.holoCardBackground, moment.module.color.opacity(0.025)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var valueText: String? {
        if let total = moment.signedTotal {
            let sign = total < 0 ? "-" : "+"
            let absolute = total < 0 ? -total : total
            let formatted = NumberFormatter.currency.string(from: NSDecimalNumber(decimal: absolute)) ?? ""
            return sign + formatted
        }
        return moment.module == .finance ? moment.singleValueText : nil
    }

    private var valueColor: Color {
        if let total = moment.signedTotal, total > 0 { return .holoSuccess }
        if moment.events.first?.valueDirection == .positive { return .holoSuccess }
        return .holoTextPrimary
    }

    private var accessibilityText: String {
        var parts = [moment.module.displayName, moment.timeText, moment.title]
        if let valueText { parts.append(valueText) }
        return parts.joined(separator: "，")
    }

    private func openMoment() {
        if moment.events.count == 1, let event = moment.events.first {
            onSelect(event)
        } else {
            onSelectGroup(moment.events)
        }
    }
}
