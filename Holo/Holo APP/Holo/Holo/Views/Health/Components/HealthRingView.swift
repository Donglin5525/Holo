//
//  HealthRingView.swift
//  Holo
//
//  健康圆环进度组件
//  显示单个健康指标的完成进度
//

import SwiftUI

// MARK: - HealthRingView

/// 健康圆环视图
struct HealthRingView: View {
    let progress: Double  // 0-100
    let color: Color
    let icon: String
    let label: String

    // MARK: - Body

    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            ZStack {
                HoloProgress(value: progress / 100, color: color, shape: .ring, lineWidth: 12)
                    .frame(width: 80, height: 80)

                // 图标
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(color)
            }

            // 标签
            Text(label)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }
}

// MARK: - TripleHealthRingView

/// 健康首页三环主视觉
struct TripleHealthRingView: View {
    let snapshot: HealthDashboardSnapshot


    var body: some View {
        ZStack {
            ring(for: snapshot.steps, size: 168, lineWidth: 13, sweepDelay: 0)
            ring(for: snapshot.sleep, size: 124, lineWidth: 13, sweepDelay: 0.08)
            ring(for: snapshot.standOrActivity, size: 80, lineWidth: 13, sweepDelay: 0.16)

            Circle()
                .fill(Color.holoCardBackground)
                .frame(width: 58, height: 58)
                .overlay(
                    Circle()
                        .stroke(Color.holoBorder, lineWidth: 1)
                )

            VStack(spacing: 2) {
                Text(snapshot.bodyScoreText)
                    .font(.system(size: snapshot.bodyScore == nil ? 12 : 24, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                    .contentTransition(.numericText())
                    .animation(HoloAnimation.smooth, value: snapshot.bodyScore)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text("身体")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(width: 52)
        }
        .frame(width: 168, height: 168)
    }

    private func ring(for metric: HealthMetricSnapshot, size: CGFloat, lineWidth: CGFloat, sweepDelay: Double) -> some View {
        HoloProgress(value: metric.availability == .available ? metric.progress : nil,
                     color: metric.type.color, shape: .ring, lineWidth: lineWidth)
            .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: HoloSpacing.lg) {
        TripleHealthRingView(
            snapshot: HealthDashboardSnapshot(
                steps: HealthMetricSnapshot(type: .steps, value: 8400, availability: .available),
                sleep: HealthMetricSnapshot(type: .sleep, value: 7.2, availability: .available),
                workout: HealthMetricSnapshot(type: .workout, value: 45, availability: .available),
                standOrActivity: HealthMetricSnapshot(type: .standHours, value: 8, availability: .available),
                dataSourceState: .connected
            )
        )
    }
    .padding()
}
