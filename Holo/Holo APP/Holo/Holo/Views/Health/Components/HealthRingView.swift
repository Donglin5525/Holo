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

// MARK: - Preview

#Preview {
    HStack(spacing: HoloSpacing.lg) {
        HealthRingView(
            progress: 72,
            color: .holoPrimary,
            icon: "figure.walk",
            label: "步数"
        )

        HealthRingView(
            progress: 85,
            color: .holoChart1,
            icon: "bed.double.fill",
            label: "睡眠"
        )

        HealthRingView(
            progress: 50,
            color: .holoPurple,
            icon: "figure.stand",
            label: "站立"
        )
    }
    .padding()
}