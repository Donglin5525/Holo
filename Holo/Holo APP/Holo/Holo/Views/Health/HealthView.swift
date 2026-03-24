//
//  HealthView.swift
//  Holo
//
//  健康主视图
//  显示今日健康数据概览
//

import SwiftUI

// MARK: - HealthView

/// 健康主视图
struct HealthView: View {
    @StateObject private var repository = HealthRepository.shared
    @State private var showPermissionView = false
    @State private var selectedMetric: HealthMetricType?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !repository.hasRequestedPermission {
                    HealthPermissionView(
                        onAuthorize: requestPermission,
                        onDismiss: { showPermissionView = false }
                    )
                } else if !repository.isAuthorized {
                    unauthorizedView
                } else {
                    healthContent
                }
            }
            .navigationDestination(item: $selectedMetric) { metric in
                HealthDetailView(type: metric)
            }
        }
        .task {
            if repository.isAuthorized {
                await repository.fetchTodayData()
            }
        }
    }

    // MARK: - Health Content

    private var healthContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 日期标题
                dateHeaderView

                // 三个圆环
                ringsView

                // 指标卡片
                metricsSection
            }
            .padding(HoloSpacing.md)
        }
        .background(Color.holoBackground)
    }

    // MARK: - Date Header

    private var dateHeaderView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日健康")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text(formatDate(Date()))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()
        }
    }

    // MARK: - Rings View

    private var ringsView: some View {
        HStack(spacing: HoloSpacing.xl) {
            HealthRingView(
                progress: calculateProgress(value: repository.todaySteps, goal: HealthMetricType.steps.dailyGoal),
                color: HealthMetricType.steps.color,
                icon: HealthMetricType.steps.icon,
                label: HealthMetricType.steps.rawValue
            )

            HealthRingView(
                progress: calculateProgress(value: repository.todaySleep, goal: HealthMetricType.sleep.dailyGoal),
                color: HealthMetricType.sleep.color,
                icon: HealthMetricType.sleep.icon,
                label: HealthMetricType.sleep.rawValue
            )

            HealthRingView(
                progress: calculateProgress(value: repository.todayStandHours, goal: HealthMetricType.standHours.dailyGoal),
                color: HealthMetricType.standHours.color,
                icon: HealthMetricType.standHours.icon,
                label: HealthMetricType.standHours.rawValue
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.lg)
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        VStack(spacing: HoloSpacing.md) {
            HealthMetricCard(
                type: .steps,
                value: repository.todaySteps,
                goal: HealthMetricType.steps.dailyGoal
            ) {
                selectedMetric = .steps
            }

            HealthMetricCard(
                type: .sleep,
                value: repository.todaySleep,
                goal: HealthMetricType.sleep.dailyGoal
            ) {
                selectedMetric = .sleep
            }

            HealthMetricCard(
                type: .standHours,
                value: repository.todayStandHours,
                goal: HealthMetricType.standHours.dailyGoal
            ) {
                selectedMetric = .standHours
            }
        }
    }

    // MARK: - Unauthorized View

    private var unauthorizedView: some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: "heart.slash.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("无法访问健康数据")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Text("请在系统设置中允许 Holo 访问健康数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)

            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.holoBody)
            .foregroundColor(.holoPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground)
    }

    // MARK: - Helper Methods

    private func calculateProgress(value: Double, goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return min(value / goal * 100, 100)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private func requestPermission() {
        repository.requestAuthorization()
    }
}

// MARK: - Preview

#Preview {
    HealthView()
}