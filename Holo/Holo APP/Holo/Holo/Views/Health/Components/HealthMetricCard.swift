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
    let metric: HealthMetricSnapshot
    let onTap: () -> Void

    init(metric: HealthMetricSnapshot, onTap: @escaping () -> Void) {
        self.metric = metric
        self.onTap = onTap
    }

    init(type: HealthMetricType, value: Double, goal: Double, onTap: @escaping () -> Void) {
        self.metric = HealthMetricSnapshot(
            type: type,
            value: value,
            availability: value > 0 ? .available : .noData
        )
        self.onTap = onTap
    }

    // MARK: - Computed Properties

    /// 完成百分比（0-100）
    private var progress: Double {
        Double(metric.progressPercent)
    }

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    Circle()
                        .fill(metric.type.color.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: metric.type.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(metric.type.color)
                }

                // 信息
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text(metric.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(metricSubtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 进度指示
                VStack(alignment: .trailing, spacing: HoloSpacing.xs) {
                    Text(metric.statusText)
                        .font(.holoBody)
                        .foregroundColor(metric.type.color)

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

    private var metricSubtitle: String {
        switch metric.availability {
        case .available:
            return "\(metric.type.formatValueWithUnit(metric.value)) · \(metric.targetText)"
        case .unauthorized:
            return "需要在系统设置中授权"
        case .noData:
            return "等待 Apple Health 数据"
        case .unsupported:
            return "当前设备不支持"
        }
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
