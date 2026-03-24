//
//  HealthMetricCard.swift
//  Holo
//
//  健康指标卡片组件
//  显示单个健康指标的详细信息和进度条
//

import SwiftUI

// MARK: - HealthMetricCard

/// 健康指标卡片
struct HealthMetricCard: View {
    let type: HealthMetricType
    let value: Double
    let goal: Double
    let onTap: () -> Void

    // MARK: - Computed Properties

    /// 完成百分比（0-100）
    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(value / goal * 100, 100)
    }

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    Circle()
                        .fill(type.color.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: type.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(type.color)
                }

                // 信息
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text(type.rawValue)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text("\(type.formatValue(value)) / \(type.formatValue(goal)) \(type.unit)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 进度指示
                VStack(alignment: .trailing, spacing: HoloSpacing.xs) {
                    Text("\(Int(progress))%")
                        .font(.holoBody)
                        .foregroundColor(type.color)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: HoloSpacing.md) {
        HealthMetricCard(
            type: .steps,
            value: 7200,
            goal: 10000,
            onTap: {}
        )

        HealthMetricCard(
            type: .sleep,
            value: 7.5,
            goal: 8,
            onTap: {}
        )

        HealthMetricCard(
            type: .standHours,
            value: 10,
            goal: 12,
            onTap: {}
        )
    }
    .padding()
    .background(Color.holoBackground)
}