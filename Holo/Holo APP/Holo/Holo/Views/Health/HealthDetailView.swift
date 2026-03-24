//
//  HealthDetailView.swift
//  Holo
//
//  健康详情视图
//  显示单个健康指标的详细信息和趋势
//

import SwiftUI

// MARK: - HealthDetailView

/// 健康详情视图
struct HealthDetailView: View {
    let type: HealthMetricType

    @StateObject private var repository = HealthRepository.shared
    @State private var weeklyData: [DailyHealthData] = []
    @State private var isLoading = true

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 大圆环
                bigRingView

                // 趋势图
                if !isLoading {
                    HealthTrendChart(data: weeklyData, type: type)
                        .padding(.horizontal, HoloSpacing.md)
                }

                // 统计摘要
                if !weeklyData.isEmpty {
                    statsSection
                }
            }
            .padding(HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .navigationTitle(type.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadWeeklyData()
        }
    }

    // MARK: - Big Ring View

    private var bigRingView: some View {
        VStack(spacing: HoloSpacing.lg) {
            ZStack {
                // 背景环
                Circle()
                    .stroke(Color.holoDivider, lineWidth: 20)
                    .frame(width: 180, height: 180)

                // 进度环
                Circle()
                    .trim(from: 0, to: min(currentProgress / 100, 1.0))
                    .stroke(
                        type.color,
                        style: StrokeStyle(lineWidth: 20, lineCap: .round)
                    )
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: currentProgress)

                // 中心内容
                VStack(spacing: HoloSpacing.xs) {
                    Text(type.formatValue(currentValue))
                        .font(.holoAmount)
                        .foregroundColor(type.color)

                    Text("/ \(type.formatValue(type.dailyGoal)) \(type.unit)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            // 目标状态
            Text(currentValue >= type.dailyGoal ? "已达成目标 🎉" : "距离目标还差 \(type.formatValue(type.dailyGoal - currentValue)) \(type.unit)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.lg)
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("统计摘要")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            HStack(spacing: HoloSpacing.md) {
                statCard(
                    title: "7 天平均",
                    value: type.formatValue(weeklyAverage),
                    unit: type.unit
                )

                statCard(
                    title: "最高值",
                    value: type.formatValue(weeklyMax),
                    unit: type.unit
                )

                statCard(
                    title: "达标天数",
                    value: "\(goalDays)",
                    unit: "天"
                )
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    private func statCard(title: String, value: String, unit: String) -> some View {
        VStack(spacing: HoloSpacing.xs) {
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Text(value)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Text(unit)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Computed Properties

    private var currentValue: Double {
        switch type {
        case .steps:
            return repository.todaySteps
        case .sleep:
            return repository.todaySleep
        case .standHours:
            return repository.todayStandHours
        }
    }

    private var currentProgress: Double {
        guard type.dailyGoal > 0 else { return 0 }
        return min(currentValue / type.dailyGoal * 100, 100)
    }

    private var weeklyAverage: Double {
        guard !weeklyData.isEmpty else { return 0 }
        return weeklyData.reduce(0) { $0 + $1.value } / Double(weeklyData.count)
    }

    private var weeklyMax: Double {
        weeklyData.map(\.value).max() ?? 0
    }

    private var goalDays: Int {
        weeklyData.filter { $0.value >= type.dailyGoal }.count
    }

    // MARK: - Data Loading

    private func loadWeeklyData() async {
        isLoading = true
        weeklyData = await repository.fetchWeeklyData(for: type)
        isLoading = false
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HealthDetailView(type: .steps)
    }
}