//
//  TodayMemoryCabinetCard.swift
//  Holo
//
//  今日展柜卡片
//  展示今天各模块的数据快览：支出、习惯、任务、观点
//

import SwiftUI

/// 今日展柜卡片
struct TodayMemoryCabinetCard: View {

    let summary: DailySummaryData?

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            HStack {
                Image(systemName: "tray.full")
                    .font(.system(size: 14))
                    .foregroundColor(.holoPrimary)

                Text("今日展柜")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()
            }

            if let summary = summary, hasData(summary) {
                // 数据展示
                HStack(spacing: HoloSpacing.md) {
                    if let expense = summary.totalExpense {
                        cabinetItem(
                            icon: "yensign.circle",
                            value: formatExpense(expense),
                            label: "支出",
                            color: .holoPrimary
                        )
                    }

                    if summary.habitsTotal > 0 {
                        cabinetItem(
                            icon: "figure.run",
                            value: "\(summary.habitsCompleted)/\(summary.habitsTotal)",
                            label: "习惯",
                            color: .holoSuccess
                        )
                    }

                    if summary.tasksCompleted > 0 {
                        cabinetItem(
                            icon: "checkmark.circle",
                            value: "\(summary.tasksCompleted)",
                            label: "任务",
                            color: .holoInfo
                        )
                    }

                    if summary.thoughtCount > 0 {
                        cabinetItem(
                            icon: "bubble.left",
                            value: "\(summary.thoughtCount)",
                            label: "观点",
                            color: .holoInfo
                        )
                    }
                }
            } else {
                // 无数据
                Text("今天还没有记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, HoloSpacing.sm)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Cabinet Item

    private func cabinetItem(
        icon: String,
        value: String,
        label: String,
        color: Color
    ) -> some View {
        VStack(spacing: HoloSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoTextPrimary)

            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func hasData(_ summary: DailySummaryData) -> Bool {
        summary.totalExpense != nil
            || summary.habitsTotal > 0
            || summary.tasksCompleted > 0
            || summary.thoughtCount > 0
    }

    private func formatExpense(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0"
    }
}
