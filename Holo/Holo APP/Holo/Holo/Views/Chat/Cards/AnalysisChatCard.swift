//
//  AnalysisChatCard.swift
//  Holo
//
//  AI 分析查询卡片 UI
//

import SwiftUI

// MARK: - Summary Card

struct AnalysisSummaryChatCard: View {

    let data: AnalysisSummaryCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: domainIcon,
                title: String(localized: "\(domainLabel)概览"),
                subtitle: data.periodLabel
            )

            if let primary = data.metrics.first {
                let supportingMetrics = data.metrics.dropFirst().prefix(2)
                HoloAIHeroMetric(
                    label: primary.label,
                    value: primary.value,
                    note: supportingMetrics.map { "\($0.label) \($0.value)" }.joined(separator: " · "),
                    tint: .holoTextPrimary
                )
            }
        }
    }

    private var domainLabel: String {
        switch data.domain {
        case .finance: return String(localized: "财务")
        case .habit: return String(localized: "习惯")
        case .task: return String(localized: "任务")
        case .thought: return String(localized: "想法")
        case .crossModule: return String(localized: "综合")
        case .health: return String(localized: "健康")
        case .goal: return String(localized: "目标")
        }
    }

    private var domainIcon: String {
        switch data.domain {
        case .finance: return "yensign.circle.fill"
        case .habit: return "flame.fill"
        case .task: return "checklist"
        case .thought: return "lightbulb.fill"
        case .crossModule: return "chart.bar.xaxis"
        case .health: return "heart.fill"
        case .goal: return "flag.fill"
        }
    }
}

// MARK: - Breakdown Card

struct AnalysisBreakdownChatCard: View {

    let data: AnalysisBreakdownCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "chart.pie.fill",
                title: data.title,
                subtitle: String(localized: "分类构成")
            )

            VStack(spacing: 10) {
                ForEach(Array(data.rows.prefix(4).enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.holoPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(1)

                            if let percent = row.percent {
                                Text(String(format: String(localized: "占比 %.0f%%"), percent * 100))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }

                        Spacer()

                        Text(row.value)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.holoTextPrimary)
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Trend Card

struct AnalysisTrendChatCard: View {

    let data: AnalysisTrendCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "chart.line.uptrend.xyaxis",
                title: data.title,
                subtitle: String(localized: "趋势变化")
            )

            if let max = data.points.max(by: { $0.value < $1.value }),
               let min = data.points.min(by: { $0.value < $1.value }) {
                let lastValue = data.points.last?.value ?? 0
                let firstValue = data.points.first?.value ?? 0
                let isUp = lastValue >= firstValue

                HoloAIHeroMetric(
                    label: isUp ? String(localized: "整体上升") : String(localized: "整体下降"),
                    value: data.points.last?.displayValue ?? max.displayValue,
                    note: String(localized: "最高 \(max.displayValue)（\(max.label)） · 最低 \(min.displayValue)（\(min.label)）"),
                    tint: isUp ? .holoError : .holoSuccess
                )
            }

            if data.points.count > 2 {
                Text("\(data.points.count) 个数据点")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }
}

// MARK: - Comparison Card

struct AnalysisComparisonChatCard: View {

    let data: AnalysisComparisonCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "arrow.left.arrow.right",
                title: data.title,
                subtitle: String(localized: "对比")
            )

            HoloAIHeroMetric(
                label: String(localized: "当前"),
                value: data.currentValue,
                note: data.previousValue.map { String(localized: "上期 \($0)") },
                tint: .holoTextPrimary
            )

            HStack(spacing: 10) {
                if let change = data.change {
                    let isPositive = change.hasPrefix("+")
                    CardBadge(text: change, color: isPositive ? .holoError : .holoSuccess)
                }
                if let previous = data.previousValue {
                    CardBadge(text: String(localized: "上期 \(previous)"), color: .holoTextSecondary)
                }
            }
        }
    }
}

// MARK: - Highlights Card

struct AnalysisHighlightsChatCard: View {

    let data: AnalysisHighlightsCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: "star.fill",
                title: String(localized: "亮点与提醒"),
                subtitle: String(localized: "\(data.highlights.count) 条亮点 · \(data.warnings.count) 条提醒")
            )

            ForEach(data.highlights, id: \.self) { highlight in
                HoloAIFactItem(kicker: String(localized: "亮点"), bodyText: highlight, tint: .holoSuccess)
            }

            ForEach(data.warnings, id: \.self) { warning in
                HoloAIFactItem(
                    kicker: String(localized: "提醒"),
                    bodyText: warning,
                    tint: Color(red: 245/255, green: 158/255, blue: 11/255)
                )
            }
        }
    }
}
