//
//  TodayOverviewSection.swift
//  Holo
//
//  今日概况：财务+记录摘要（今日看板 Matter 化方案 §5.5/§9.1）
//
//  - 预算正常只显示紧凑摘要；确定性超支提升为 attention signal；
//  - 加载失败显示 --，不误报 ¥0；第一版预算/健康信号不参与 Primary Focus。
//

import SwiftUI

struct TodayOverviewSection: View {

    let overview: HoloTodayOverview
    let sectionState: HoloTodaySectionState?
    var onOpenFinance: (() -> Void)?
    var onAddRecord: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "今日概况"))

            HStack(spacing: 0) {
                // 今日支出（nil = 暂不可用，显示 -- 而不是 ¥0）
                Button {
                    onOpenFinance?()
                } label: {
                    HStack(spacing: 6) {
                        Text(String(localized: "支出"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(spentText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(overview.budgetAtRisk ? Color.holoError : Color.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                divider

                // 预算信号（确定性超支才提升；正常显示「预算正常」弱化）
                Text(budgetText)
                    .font(.subheadline.weight(overview.budgetAtRisk ? .semibold : .regular))
                    .foregroundStyle(overview.budgetAtRisk ? Color.holoError : Color.secondary)
                    .frame(maxWidth: .infinity)

                divider

                // 今日记录快速入口（默认折叠为一行入口）
                Button {
                    onAddRecord?()
                } label: {
                    Label(String(localized: "记录今天"), systemImage: "plus.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.holoPrimary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private var spentText: String {
        guard let spent = overview.spentToday else { return "--" }
        let formatted = NumberFormatter.currencyGrouping.string(from: NSDecimalNumber(decimal: spent)) ?? "\(spent)"
        return "¥\(formatted)"
    }

    private var budgetText: String {
        if overview.budgetAtRisk {
            return String(localized: "预算超支")
        }
        return String(localized: "预算正常")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: 18)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}

nonisolated extension NumberFormatter {
    /// 分组金额（¥1,234）；静态避免每次 body 重建 formatter。
    static let currencyGrouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}