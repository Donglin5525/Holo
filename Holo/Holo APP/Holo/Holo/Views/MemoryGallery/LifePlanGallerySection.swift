//
//  LifePlanGallerySection.swift
//  Holo
//
//  长廊「一起做的计划」区块：计划历史 + 成长统计（理解档案第三块）。
//  无计划时不占位（新用户长廊保持干净）。
//

import SwiftUI

struct LifePlanGallerySection: View {
    @State private var plans: [LifePlanSnapshot] = []
    @State private var statistics: (totalPlans: Int, avgAcceptedActions: Double) = (0, 0)

    var body: some View {
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Text("它和你一起做的")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Text("\(statistics.totalPlans) 份计划 · 平均接受 \(String(format: "%.1f", statistics.avgAcceptedActions)) 张行动卡")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                ForEach(plans.prefix(4)) { plan in
                    planRow(plan)
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .task {
                loadPlans()
            }
        }
    }

    private func planRow(_ plan: LifePlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(periodText(plan))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(rowBadge(plan))
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            if let first = plan.priorities.first {
                Text("重点：\(first.outcome)" + (plan.priorities.count > 1 ? " 等 \(plan.priorities.count) 项" : ""))
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func periodText(_ plan: LifePlanSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return "\(formatter.string(from: plan.periodStart)) – \(formatter.string(from: plan.periodEnd))"
    }

    private func rowBadge(_ plan: LifePlanSnapshot) -> String {
        let accepted = plan.acceptedActionCount
        let done = plan.completedActionCount
        switch plan.status {
        case "active": return "进行中 · \(done)/\(accepted) 完成"
        default: return "已接受 \(accepted) 张 · 完成 \(done)"
        }
    }

    private func loadPlans() {
        let repository = LifePlanRepository.shared
        repository.supersedeExpiredPlans()
        if let active = repository.fetchActivePlan() {
            plans = [active]
            statistics = repository.statistics()
            // 历史计划按周期倒序
            let now = Date()
            if let activeStart = plans.first?.periodStart {
                plans += repository.fetchPlans(
                    periodStartIn: Date.distantPast, activeStart.addingTimeInterval(-1)
                )
            }
            _ = now
        } else {
            plans = repository.fetchPlans(periodStartIn: .distantPast, Date())
            statistics = repository.statistics()
        }
    }
}
