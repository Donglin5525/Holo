//
//  DailySummaryNode.swift
//  Holo
//
//  日摘要卡片 — 聚合当日各模块统计
//  信息层级：消费金额 > 习惯完成率 > 任务数
//

import SwiftUI

struct DailySummaryNode: View {
    let data: DailySummaryData
    let moduleFilter: MemoryModuleFilter

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                Text("日摘要")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            if summaryItems.isEmpty {
                Text("这一天没有匹配当前筛选的记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPlaceholder)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: HoloSpacing.sm)], spacing: HoloSpacing.sm) {
                    ForEach(summaryItems) { item in
                        summaryPill(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - Subviews

    private func summaryPill(_ item: SummaryPillItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(item.color)

                Text(item.label)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
                    .lineLimit(1)
            }

            Text(item.value)
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, HoloSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    // MARK: - Helpers

    private var summaryItems: [SummaryPillItem] {
        var items: [SummaryPillItem] = []

        if let expense = data.totalExpense, showFinance {
            items.append(SummaryPillItem(
                icon: "creditcard.fill",
                value: formatExpense(expense),
                label: "支出",
                color: .holoPrimary
            ))
        }

        if showHabit && data.habitsTotal > 0 {
            items.append(SummaryPillItem(
                icon: "checkmark.circle.fill",
                value: "\(data.habitsCompleted)/\(data.habitsTotal)",
                label: "习惯",
                color: .holoSuccess
            ))
        }

        if showTask && data.tasksCompleted > 0 {
            items.append(SummaryPillItem(
                icon: "checklist",
                value: "\(data.tasksCompleted)",
                label: "任务",
                color: .holoPrimary
            ))
        }

        if showThought && data.thoughtCount > 0 {
            items.append(SummaryPillItem(
                icon: "lightbulb.fill",
                value: "\(data.thoughtCount)",
                label: "观点",
                color: .holoPurple
            ))
        }

        return items
    }

    /// 根据筛选决定是否显示各模块
    private var showFinance: Bool {
        moduleFilter == .all || moduleFilter == .transaction
    }

    private var showHabit: Bool {
        moduleFilter == .all || moduleFilter == .habitRecord
    }

    private var showTask: Bool {
        moduleFilter == .all || moduleFilter == .task
    }

    private var showThought: Bool {
        moduleFilter == .all || moduleFilter == .thought
    }

    private func formatExpense(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0"
    }
}

private struct SummaryPillItem: Identifiable {
    let id = UUID()
    let icon: String
    let value: String
    let label: String
    let color: Color
}
