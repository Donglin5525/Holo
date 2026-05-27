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
                // 背景环
                Circle()
                    .stroke(Color.holoDivider, lineWidth: 12)
                    .frame(width: 80, height: 80)

                // 进度环
                Circle()
                    .trim(from: 0, to: min(progress / 100, 1.0))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: progress)

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
            ring(for: snapshot.steps, size: 168, lineWidth: 13)
            ring(for: snapshot.sleep, size: 124, lineWidth: 13)
            ring(for: snapshot.standOrActivity, size: 80, lineWidth: 13)

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

    private func ring(for metric: HealthMetricSnapshot, size: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.holoDivider, lineWidth: lineWidth)
                .frame(width: size, height: size)

            Circle()
                .trim(from: 0, to: metric.progress)
                .stroke(
                    metric.type.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: metric.progress)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: HoloSpacing.lg) {
        TripleHealthRingView(
            snapshot: HealthDashboardSnapshot(
                steps: HealthMetricSnapshot(type: .steps, value: 8400, availability: .available),
                sleep: HealthMetricSnapshot(type: .sleep, value: 7.2, availability: .available),
                standOrActivity: HealthMetricSnapshot(type: .standHours, value: 8, availability: .available),
                dataSourceState: .connected
            )
        )
    }
    .padding()
}
