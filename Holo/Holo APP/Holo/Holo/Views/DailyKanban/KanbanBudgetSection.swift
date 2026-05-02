//
//  KanbanBudgetSection.swift
//  Holo
//
//  今日看板 — 月度预算摘要卡片
//

import SwiftUI

struct KanbanBudgetSection: View {

    @State private var budgetSummary: GlobalBudgetSummary?

    var body: some View {
        if let summary = budgetSummary {
            section
                .onAppear { loadBudget() }
        } else {
            EmptyView()
                .onAppear { loadBudget() }
        }
    }

    private var section: some View {
        VStack(spacing: 8) {
            sectionHeader

            VStack(spacing: 12) {
                budgetOverview(summary: budgetSummary!)
                budgetBar(progress: budgetSummary!.progress)
                budgetDetails(summary: budgetSummary!)
            }
            .padding(16)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
            .shadow(color: HoloShadow.card, radius: 4, y: 1)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Label("月度预算", systemImage: "wallet.pass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func budgetOverview(summary: GlobalBudgetSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("本月剩余")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                HStack(spacing: 4) {
                    Text(summary.totalRemainingAmountFormatted)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)
                    Text("/ \(summary.totalBudgetFormatted)")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            Spacer()
        }
    }

    private func budgetBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoDivider)
                    .frame(height: 6)

                Capsule()
                    .fill(budgetBarColor(progress: progress))
                    .frame(width: max(geo.size.width * min(progress, 1.0), 0), height: 6)
                    .animation(.spring(response: 0.5), value: progress)
            }
        }
        .frame(height: 6)
    }

    private func budgetDetails(summary: GlobalBudgetSummary) -> some View {
        HStack(spacing: 10) {
            budgetDetailItem(
                label: "今日支出",
                value: "¥--",
                color: .holoError
            )
            budgetDetailItem(
                label: "日均可用",
                value: summary.dailyBudgetFormatted,
                color: .holoInfo
            )
            budgetDetailItem(
                label: "剩余天数",
                value: "\(summary.remainingDays)天",
                color: .holoSuccess
            )
        }
    }

    private func budgetDetailItem(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Helpers

    private func budgetBarColor(progress: Double) -> Color {
        if progress >= 1.0 { return .holoError }
        if progress >= 0.8 { return .holoPrimary }
        if progress >= 0.6 { return Color.orange }
        return .holoSuccess
    }

    private func loadBudget() {
        Task { @MainActor in
            budgetSummary = BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)
        }
    }
}

private extension GlobalBudgetSummary {
    var totalBudgetFormatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: NSDecimalNumber(decimal: totalBudgetAmount)) ?? "¥0"
    }

    var totalRemainingAmountFormatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: NSDecimalNumber(decimal: totalRemainingAmount)) ?? "¥0"
    }

    var dailyBudgetFormatted: String {
        guard remainingDays > 0 else { return "¥0" }
        let daily = totalRemainingAmount / Decimal(remainingDays)
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: NSDecimalNumber(decimal: daily)) ?? "¥0"
    }
}
