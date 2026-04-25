//
//  RecentDayCoverView.swift
//  Holo
//
//  最近日子封面流
//  水平滚动展示最近 3-7 天的日期封面卡片
//

import SwiftUI

/// 最近日子封面卡片
struct RecentDayCoverView: View {

    let sections: [TimelineSection]

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("最近的日子")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if sections.isEmpty {
                emptyHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: HoloSpacing.sm) {
                        ForEach(sections.prefix(7)) { section in
                            dayCoverCard(section)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Day Cover Card

    private func dayCoverCard(_ section: TimelineSection) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            // 日期标签
            HStack {
                Text(section.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Text(section.formattedDate)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            // 当天数据摘要
            let summary = section.nodes
                .compactMap { node -> DailySummaryData? in
                    if case .summary(let data) = node.data { return data }
                    return nil
                }
                .first

            if let summary = summary {
                summaryChips(summary)
            } else {
                Text("无记录")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
        .padding(HoloSpacing.md)
        .frame(width: 140, alignment: .topLeading)
        .frame(minHeight: 120)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Summary Chips

    @ViewBuilder
    private func summaryChips(_ summary: DailySummaryData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let expense = summary.totalExpense {
                chipRow(icon: "yensign.circle", text: formatExpense(expense), color: .holoPrimary)
            }
            if summary.habitsTotal > 0 {
                chipRow(
                    icon: "figure.run",
                    text: "\(summary.habitsCompleted)/\(summary.habitsTotal)",
                    color: .holoSuccess
                )
            }
            if summary.tasksCompleted > 0 {
                chipRow(
                    icon: "checkmark.circle",
                    text: "\(summary.tasksCompleted) 个任务",
                    color: .holoInfo
                )
            }
            if summary.thoughtCount > 0 {
                chipRow(
                    icon: "bubble.left",
                    text: "\(summary.thoughtCount) 条观点",
                    color: .holoInfo
                )
            }
        }
    }

    private func chipRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)

            Text(text)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Empty

    private var emptyHint: some View {
        Text("暂无最近记录")
            .font(.holoCaption)
            .foregroundColor(.holoTextPlaceholder)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, HoloSpacing.md)
    }

    // MARK: - Formatter

    private func formatExpense(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0"
    }
}
