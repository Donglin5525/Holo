//
//  AnalysisChatCard.swift
//  Holo
//
//  AI 分析查询卡片 UI
//  包含 Summary / Trend / Breakdown / Comparison / Highlights 五种卡片
//

import SwiftUI

// MARK: - Summary Card

struct AnalysisSummaryChatCard: View {

    let data: AnalysisSummaryCardData

    var body: some View {
        ChatCardView {
            CardHeaderView(
                icon: domainIcon,
                title: "\(domainLabel)概览"
            )

            CardBadge(text: data.periodLabel, color: .holoPrimary)

            CardDivider()

            ForEach(data.metrics, id: \.label) { metric in
                HStack {
                    Text(metric.label)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Text(metric.value)
                        .font(.holoBody.bold())
                        .foregroundColor(.holoTextPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
        }
    }

    private var domainLabel: String {
        switch data.domain {
        case .finance: return "财务"
        case .habit: return "习惯"
        case .task: return "任务"
        case .thought: return "想法"
        case .crossModule: return "综合"
        }
    }

    private var domainIcon: String {
        switch data.domain {
        case .finance: return "yensign.circle.fill"
        case .habit: return "flame.fill"
        case .task: return "checklist"
        case .thought: return "lightbulb.fill"
        case .crossModule: return "chart.bar.xaxis"
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
                title: data.title
            )

            CardDivider()

            ForEach(data.rows, id: \.label) { row in
                HStack {
                    Text(row.label)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)

                    Spacer()

                    Text(row.value)
                        .font(.holoBody.bold())
                        .foregroundColor(.holoTextPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    if let percent = row.percent {
                        Text(String(format: "%.0f%%", percent * 100))
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
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
                title: data.title
            )

            CardDivider()

            // 简化趋势展示：最大值 + 最小值 + 趋势方向
            if let max = data.points.max(by: { $0.value < $1.value }),
               let min = data.points.min(by: { $0.value < $1.value }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最高")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                        Text(max.displayValue)
                            .font(.holoBody.bold())
                            .foregroundColor(.holoTextPrimary)
                        Text(max.label)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    VStack(alignment: .center, spacing: 4) {
                        let lastValue = data.points.last?.value ?? 0
                        let firstValue = data.points.first?.value ?? 0
                        Image(systemName: lastValue >= firstValue ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 20))
                            .foregroundColor(lastValue >= firstValue ? .holoError : .holoSuccess)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("最低")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                        Text(min.displayValue)
                            .font(.holoBody.bold())
                            .foregroundColor(.holoTextPrimary)
                        Text(min.label)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            // 数据点数
            if data.points.count > 2 {
                Text("\(data.points.count) 个数据点")
                    .font(.holoTinyLabel)
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
                title: data.title
            )

            CardDivider()

            HStack(spacing: 16) {
                // 当前
                VStack(alignment: .center, spacing: 4) {
                    Text("当前")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text(data.currentValue)
                        .font(.holoBody.bold())
                        .foregroundColor(.holoTextPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                // 变化
                if let change = data.change {
                    VStack(alignment: .center, spacing: 4) {
                        let isPositive = change.hasPrefix("+")
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 16))
                            .foregroundColor(isPositive ? .holoError : .holoSuccess)
                        Text(change)
                            .font(.holoCaption.bold())
                            .foregroundColor(isPositive ? .holoError : .holoSuccess)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }

                // 上期
                if let previous = data.previousValue {
                    VStack(alignment: .center, spacing: 4) {
                        Text("上期")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                        Text(previous)
                            .font(.holoBody.bold())
                            .foregroundColor(.holoTextSecondary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
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
                title: "亮点与提醒"
            )

            if !data.highlights.isEmpty {
                ForEach(data.highlights, id: \.self) { highlight in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12))
                            .foregroundColor(.holoSuccess)
                            .frame(width: 16, height: 16)
                            .padding(.top, 2)

                        Text(highlight)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !data.warnings.isEmpty {
                if !data.highlights.isEmpty {
                    CardDivider()
                }

                ForEach(data.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 245/255, green: 158/255, blue: 11/255))
                            .frame(width: 16, height: 16)
                            .padding(.top, 2)

                        Text(warning)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
