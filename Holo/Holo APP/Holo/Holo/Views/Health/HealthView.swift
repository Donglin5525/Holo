//
//  HealthView.swift
//  Holo
//
//  健康主视图
//

import SwiftUI

// MARK: - HealthView

struct HealthView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var repository = HealthRepository.shared
    @State private var selectedMetric: HealthMetricType?
    @State private var weeklySleepData: [DailyHealthData] = []
    @State private var isRefreshing = false
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var dayData: (steps: Double, sleep: Double, standHours: Double, activeMinutes: Double) = (0, 0, 0, 0)

    private var snapshot: HealthDashboardSnapshot {
        let stepsAvail: HealthMetricAvailability = dayData.steps > 0 ? .available : .noData
        let sleepAvail: HealthMetricAvailability = dayData.sleep > 0 ? .available : .noData
        let standAvail: HealthMetricAvailability
        if dayData.standHours > 0 {
            standAvail = .available
        } else if dayData.activeMinutes > 0 {
            standAvail = .unsupported
        } else {
            standAvail = .noData
        }

        return HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: dayData.steps, availability: stepsAvail),
            sleep: HealthMetricSnapshot(type: .sleep, value: dayData.sleep, availability: sleepAvail),
            standOrActivity: HealthDashboardSnapshot.standOrActivitySnapshot(
                standHours: dayData.standHours,
                activeMinutes: dayData.activeMinutes,
                standAvailability: standAvail
            ),
            dataSourceState: repository.dataSourceState
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if shouldShowPermissionView {
                    topBackBar
                    HealthPermissionView(
                        onAuthorize: requestPermission,
                        onDismiss: { dismiss() }
                    )
                } else if shouldShowUnavailableView {
                    topBackBar
                    unavailableView
                } else {
                    healthContent
                }
            }
            .navigationDestination(item: $selectedMetric) { metric in
                HealthDetailView(type: metric, selectedDate: selectedDate)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .swipeBackToDismiss {
            if selectedMetric != nil {
                selectedMetric = nil
            } else {
                dismiss()
            }
        }
        .task {
            await refreshAll()
        }
        .onChange(of: selectedDate) {
            Task { await loadDateData() }
        }
    }

    private var shouldShowPermissionView: Bool {
        !repository.hasRequestedPermission && repository.dataSourceState == .notRequested
    }

    private var shouldShowUnavailableView: Bool {
        repository.dataSourceState == .denied || repository.dataSourceState == .unavailable
    }

    private var healthContent: some View {
        VStack(spacing: 0) {
            headerView
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    heroCard
                    metricSummaryRow
                    dataSourceCard
                    coreInsightCard
                    lifestyleInsightCard
                    weeklyTrendCard
                }
                .padding(HoloSpacing.md)
            }
        }
        .background(Color.holoBackground)
    }

    /// 返回首页按钮（对齐全局 fullScreenCover 模块约定，复用于各分支）
    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
                .frame(width: 40, height: 40)
                .background(Color.holoCardBackground)
                .clipShape(Circle())
                .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// 权限引导 / 不可用兜底分支的固定返回栏
    private var topBackBar: some View {
        HStack {
            backButton
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.sm)
    }

    private var headerView: some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                backButton

                VStack(alignment: .leading, spacing: 4) {
                    Text("健康")
                        .font(.holoTitle)
                        .foregroundColor(.holoTextPrimary)

                    Text(syncStatusText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                syncButton
            }

            dateNavigationBar
        }
        .padding(.top, HoloSpacing.sm)
    }

    private var dateNavigationBar: some View {
        ZStack {
            HStack {
                Spacer()

                if !Calendar.current.isDateInToday(selectedDate) {
                    todayButton
                }
            }

            HStack(spacing: HoloSpacing.sm) {
                dateNavigationButton(systemName: "chevron.left", isDisabled: false) {
                    navigateDate(-1)
                }

                Text(dateDisplayText)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: 118)

                dateNavigationButton(
                    systemName: "chevron.right",
                    isDisabled: Calendar.current.isDateInToday(selectedDate)
                ) {
                    navigateDate(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.holoCardBackground.opacity(0.55))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.holoBorder.opacity(0.7), lineWidth: 1)
            )
        }
        .padding(.horizontal, HoloSpacing.md)
    }

    private func dateNavigationButton(
        systemName: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isDisabled ? .holoTextSecondary.opacity(0.32) : .holoTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var todayButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedDate = Calendar.current.startOfDay(for: Date())
            }
        } label: {
            Text("今天")
                .font(.holoLabel)
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var dateDisplayText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let calendar = Calendar.current

        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: selectedDate)

        if calendar.isDateInToday(selectedDate) {
            return "今天 · \(dateStr)"
        } else if calendar.isDateInYesterday(selectedDate) {
            return "昨天 · \(dateStr)"
        } else {
            formatter.dateFormat = "EEEE"
            let weekday = formatter.string(from: selectedDate)
            return "\(dateStr) \(weekday)"
        }
    }

    private func navigateDate(_ direction: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let newDate = calendar.date(byAdding: .day, value: direction, to: selectedDate),
              newDate <= today else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = calendar.startOfDay(for: newDate)
        }
    }

    private var syncButton: some View {
        Button {
            Task {
                await runRefresh()
            }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .stroke(Color.holoPrimary.opacity(0.18), lineWidth: 2)
                        .frame(width: 18, height: 18)

                    Circle()
                        .trim(from: 0.12, to: 0.82)
                        .stroke(
                            Color.holoPrimary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )

                    Circle()
                        .fill(Color.holoPrimary)
                        .frame(width: 4, height: 4)
                }

                Text(isRefreshing ? "同步中" : "同步")
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.holoPrimary.opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.holoPrimary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
    }

    private var heroCard: some View {
        HStack(spacing: HoloSpacing.md) {
            TripleHealthRingView(snapshot: snapshot)

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(snapshot.statusTitle)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(snapshot.statusSubtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(2)

                Text(snapshot.ringBadgeText)
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 6, y: 2)
    }

    private var metricSummaryRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            ForEach(snapshot.metrics) { metric in
                Button {
                    selectedMetric = metric.type
                } label: {
                    metricSummaryChip(metric)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func metricSummaryChip(_ metric: HealthMetricSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(metric.title)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Image(systemName: metric.type.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(metric.type.color)
            }

            Text(metric.valueText)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider)
                    Capsule()
                        .fill(metric.type.color)
                        .frame(width: proxy.size.width * metric.progress)
                }
            }
            .frame(height: 5)

            Text(metric.targetText)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private var dataSourceCard: some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoTextPrimary)
                    .frame(width: 42, height: 42)

                Image(systemName: "apple.logo")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.holoCardBackground)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(repository.dataSourceState.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(repository.dataSourceState.subtitle)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Text(repository.dataSourceState.badgeText)
                .font(.holoLabel)
                .foregroundColor(repository.dataSourceState.badgeColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(repository.dataSourceState.badgeColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private var coreInsightCard: some View {
        insightCard(
            iconText: "✦",
            title: snapshot.coreInsight.title,
            detail: snapshot.coreInsight.detail,
            color: snapshot.coreInsight.color
        )
    }

    private var lifestyleInsightCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack {
                Text("生活闭环")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("\(snapshot.lifestyleInsights.count) 条关联")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            VStack(spacing: HoloSpacing.sm) {
                ForEach(snapshot.lifestyleInsights) { insight in
                    HStack(alignment: .top, spacing: HoloSpacing.sm) {
                        Text(insight.domain)
                            .font(.holoLabel)
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(insight.color)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.title)
                                .font(.holoLabel)
                                .foregroundColor(.holoTextPrimary)

                            Text(insight.detail)
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private var weeklyTrendCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("7 天睡眠")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("详情")
                    .font(.holoLabel)
                    .foregroundColor(.holoChart1)
            }

            HealthTrendChart(data: weeklySleepData, type: .sleep)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .onTapGesture {
            selectedMetric = .sleep
        }
    }

    private func insightCard(iconText: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.md) {
            Text(iconText)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(color)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(detail)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoPrimary.opacity(0.18), lineWidth: 1)
        )
    }

    private var unavailableView: some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: repository.dataSourceState == .denied ? "heart.slash.fill" : "iphone.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.55))

            VStack(spacing: HoloSpacing.sm) {
                Text(repository.dataSourceState.title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text(repository.dataSourceState.subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
            }

            if repository.dataSourceState == .denied {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.holoBody)
                .foregroundColor(.holoPrimary)
            }
        }
        .padding(HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground)
    }

    private var syncStatusText: String {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(selectedDate)

        switch repository.dataSourceState {
        case .connected:
            return isToday ? "同步自 Apple Health · 刚刚" : "查看历史健康数据"
        case .partiallyConnected:
            return isToday ? "Apple Health 部分同步" : "查看历史健康数据"
        case .notRequested:
            return "等待 Apple Health 授权"
        case .denied:
            return "健康权限已关闭"
        case .unavailable:
            return "此设备不支持 HealthKit"
        }
    }

    private func requestPermission() {
        repository.requestAuthorization()
    }

    private func refreshAll() async {
        await repository.refresh()
        await loadDateData()
    }

    private func loadDateData() async {
        dayData = await repository.fetchDayData(for: selectedDate)
        weeklySleepData = await repository.fetchWeeklyData(for: .sleep, endingOn: selectedDate)
    }

    @MainActor
    private func runRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await refreshAll()
        isRefreshing = false
    }

}

#Preview {
    HealthView()
}
