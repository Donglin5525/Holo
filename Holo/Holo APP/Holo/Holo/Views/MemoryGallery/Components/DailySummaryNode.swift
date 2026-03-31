//
//  DailySummaryNode.swift
//  Holo
//
//  日摘要卡片 — 聚合当日各模块统计
//  信息层级：消费金额 > 习惯环形进度条 > 任务数
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

            // 习惯完成率（环形进度条）
            if showHabit {
                habitProgressView
            }

            // 任务完成数
            if showTask {
                taskView
            }
        }
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
            Text("💰")
                .font(.system(size: 14))
            Text(formatExpense(expense))
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
        }
    }

    /// 习惯环形进度条
    private var habitProgressView: some View {
        HStack(spacing: 6) {
            MiniRingProgress(
                completed: data.habitsCompleted,
                total: data.habitsTotal
            )

            if data.habitsTotal > 0 {
                Text("习惯")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    /// 任务完成数
    private var taskView: some View {
        HStack(spacing: 4) {
            Text("📋")
                .font(.system(size: 14))
            Text("\(data.tasksCompleted)")
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

    private func formatExpense(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0"
    }
}

// MARK: - MiniRingProgress

/// 迷你环形进度条（直径 28pt，线宽 2.5pt，前景色 holoPrimary）
struct MiniRingProgress: View {
    let completed: Int
    let total: Int

    private let size: CGFloat = 28
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            // 背景环
            Circle()
                .stroke(Color.holoBorder, lineWidth: lineWidth)

            // 前景环
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.holoPrimary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // 中心文字
            if total > 0 {
                if completed >= total {
                    Text("✓")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.holoPrimary)
                } else {
                    Text("\(completed)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var progress: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(completed) / CGFloat(total)
    }
}
