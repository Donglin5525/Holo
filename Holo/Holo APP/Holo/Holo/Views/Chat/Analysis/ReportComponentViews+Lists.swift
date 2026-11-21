//
//  ReportComponentViews+Lists.swift
//  Holo
//
//  深度报告数据组件视图（列表类）：习惯热力条 / 前后对比 / 缺口卡 / 里程碑。
//

import SwiftUI

// MARK: - 习惯热力条（每格 1 天、每组 1 周）

struct ReportHabitStripView: View {
    let strip: HoloReportComponent.HabitStrip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = strip.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(1)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoTextSecondary.opacity(0.04))
                Divider().opacity(0.5)
            }
            ForEach(Array(strip.rows.enumerated()), id: \.offset) { index, row in
                rowView(row)
                if index < strip.rows.count - 1 {
                    Divider().opacity(0.5)
                }
            }
            if let folded = strip.foldedNote, !folded.isEmpty {
                Divider().opacity(0.5)
                Text(folded)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            if strip.startLabel != nil || strip.endLabel != nil {
                HStack {
                    Text(strip.startLabel ?? "")
                    Spacer()
                    Text(strip.endLabel ?? "")
                }
                .font(.system(size: 9.5))
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ReportComponentStyle.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ReportComponentStyle.cornerRadius, style: .continuous)
            .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1))
    }

    private func rowView(_ row: HoloReportComponent.HabitStrip.Row) -> some View {
        let tone = row.tone ?? .neutral
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                    if let sub = row.sub, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 10.5))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let rate = row.rateText {
                    Text(rate)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.holoTextPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let status = row.statusLabel {
                    ReportStatusChip(text: status, tone: tone)
                }
            }
            if !row.days.isEmpty {
                ReportDayGrid(days: row.days, tint: tone == .good ? .holoSuccess : .holoPrimary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// 逐日格：≥14 天按「每周一组」压缩成热力条；不足 14 天放大成点阵（新目标场景）
struct ReportDayGrid: View {
    let days: [Int]
    var tint: Color = .holoPrimary

    var body: some View {
        if days.count >= 14 {
            HStack(spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 1.5) {
                        // 固定格高：只给比例不给尺寸时，格子在父布局里会被压成 0 高度（渲染自检实锤）
                        ForEach(Array(week.enumerated()), id: \.offset) { _, value in
                            cell(value, radius: 1.5)
                                .frame(maxWidth: .infinity)
                                .frame(height: 5)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, value in
                    cell(value, radius: 3).frame(width: 14, height: 14)
                }
            }
        }
    }

    private var weeks: [[Int]] {
        stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    private func cell(_ value: Int, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(value > 0 ? tint : Color.holoTextSecondary.opacity(0.12))
    }
}

// MARK: - 前后对比

struct ReportPeriodCompareView: View {
    let compare: HoloReportComponent.PeriodCompare

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                side(compare.left, tint: .holoSuccess)
                side(compare.right, tint: ReportComponentStyle.amber)
            }
            if let caption = compare.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func side(_ side: HoloReportComponent.PeriodCompare.Side, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(side.label)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(2)
                .padding(.bottom, 4)
            ForEach(Array(side.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.label)
                        .font(.system(size: 12.5))
                        .foregroundColor(.holoTextSecondary)
                    Spacer(minLength: 4)
                    Text(row.value)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.12)))
    }
}

// MARK: - 缺口卡

struct ReportGapCardsView: View {
    let cards: [HoloReportComponent.GapCards.Card]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(cards.prefix(3).enumerated()), id: \.offset) { _, card in
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: Self.symbol(for: card.icon))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.holoTextSecondary.opacity(0.07)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.holoTextPrimary)
                        Text(card.body)
                            .font(.system(size: 12.5))
                            .foregroundColor(.holoTextSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let action = card.action, !action.isEmpty {
                            Text(action)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.holoPrimary)
                                .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(13)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.holoTextSecondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }
}

extension ReportGapCardsView {
    /// 后端下发 emoji 语义 → SF Symbol（不依赖彩色 emoji 字体，分享图/导出渲染一致）
    static func symbol(for icon: String?) -> String {
        switch icon {
        case "🍱": return "fork.knife"
        case "⏸️": return "pause.circle"
        case "📝": return "square.and.pencil"
        case "🎯": return "target"
        case "🔗": return "link"
        case "🌱": return "leaf"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - 里程碑（再记录多久能看出什么）

struct ReportMilestonesView: View {
    let milestones: HoloReportComponent.Milestones

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = milestones.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.bottom, 8)
            }
            ForEach(Array(milestones.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(item.done == true ? Color.holoPrimary : Color.holoCardBackground)
                            .overlay(Circle().stroke(item.done == true ? Color.holoPrimary : Color.holoTextSecondary, lineWidth: 2))
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        if index < milestones.items.count - 1 {
                            Rectangle()
                                .fill(Color.holoTextSecondary.opacity(0.25))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    (Text(item.label).bold().foregroundColor(.holoTextPrimary) + Text(" · \(item.body)"))
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}
