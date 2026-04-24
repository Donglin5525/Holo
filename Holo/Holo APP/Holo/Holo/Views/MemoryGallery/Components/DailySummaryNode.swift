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
        HStack(spacing: 18) {
            // 消费金额
            if let expense = data.totalExpense, showFinance {
                expenseView(expense)
            }

            Spacer(minLength: 0)

            // 习惯完成率
            if showHabit && data.habitsTotal > 0 {
                habitProgressView
            }

            // 任务完成数
            if showTask {
                taskView
            }

            // 观点数
            if showThought && data.thoughtCount > 0 {
                thoughtView
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

    /// 消费金额视图（最醒目）
    @ViewBuilder
    private func expenseView(_ expense: Decimal) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 14))
                .foregroundColor(.holoPrimary)
            Text(formatExpense(expense))
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
        }
    }

    /// 习惯完成率
    private var habitProgressView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.holoPrimary)
            Text("\(data.habitsCompleted)/\(data.habitsTotal)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    /// 任务完成数
    private var taskView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checklist")
                .font(.system(size: 14))
                .foregroundColor(.holoPrimary)
            Text("\(data.tasksCompleted)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    /// 观点数
    private var thoughtView: some View {
        HStack(spacing: 4) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14))
                .foregroundColor(.holoPrimary)
            Text("\(data.thoughtCount)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Helpers

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
