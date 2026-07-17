//
//  HealthDetailView.swift
//  Holo
//
//  健康详情视图
//

import SwiftUI

// MARK: - HealthDetailView

struct HealthDetailView: View {
    let type: HealthMetricType
    let selectedDate: Date

    @Environment(\.dismiss) private var dismiss
    @StateObject private var repository = HealthRepository.shared
    @State private var weeklyData: [DailyHealthData] = []
    @State private var isLoading = true
    @State private var currentValue: Double = 0
    @State private var currentAvailability: HealthMetricAvailability = .noData
    @State private var sleepDetail: HealthSleepDetail?

    private var metric: HealthMetricSnapshot {
        HealthMetricSnapshot(type: type, value: currentValue, availability: currentAvailability)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    bigRingCard
                    statsSection

                    if type == .sleep, let sleepDetail, sleepDetail.hasStageData {
                        SleepStagesCard(detail: sleepDetail)
                    }

                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        HStack {
                            Text("近 7 天")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Spacer()
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.75)
                            }
                        }

                        HealthTrendChart(data: weeklyData, type: type)
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.lg)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )

                    insightSection
                    relatedSection
                }
                .padding(HoloSpacing.md)
            }
        }
        .background(Color.holoBackground)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            dismiss()
        }
        .task {
            await loadDateData()
            await loadWeeklyData()
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: HoloSpacing.md) {
            backButton

            VStack(alignment: .leading, spacing: 4) {
                Text(type.rawValue)
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)

                Text(detailSubtitleText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Text(metric.statusText)
                .font(.holoLabel)
                .foregroundColor(type.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(type.color.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
    }

    /// 返回按钮（对齐全局 fullScreenCover 模块约定，复用 HealthView 样式）
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

    private var bigRingCard: some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .stroke(Color.holoDivider, lineWidth: 18)
                    .frame(width: 152, height: 152)

                Circle()
                    .trim(from: 0, to: metric.progress)
                    .stroke(
                        type.color,
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .frame(width: 152, height: 152)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.45), value: metric.progress)

                VStack(spacing: 2) {
                    Text(metric.valueText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(type.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Text(metric.type.unit)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(width: 92)
            }

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(detailTitle)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detailSubtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(2)

                Text(metric.statusText)
                    .font(.holoLabel)
                    .foregroundColor(type.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(type.color.opacity(0.12))
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

    private var statsSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            statCard(title: "7 天平均", value: type.formatValue(weeklyAverage), unit: type.unit)
            statCard(title: "最高值", value: type.formatValue(weeklyMax), unit: type.unit)
            statCard(title: "达标天数", value: "\(goalDays)", unit: "天")
        }
    }

    private func statCard(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(unit)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private var insightSection: some View {
        HStack(alignment: .top, spacing: HoloSpacing.md) {
            Text("✦")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(type.color)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(insightTitle)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(insightDetail)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.md)
        .background(type.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(type.color.opacity(0.18), lineWidth: 1)
        )
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("关联线索")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            ForEach(relatedRows, id: \.title) { row in
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Text(row.badge)
                        .font(.holoLabel)
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(row.color)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.holoLabel)
                            .foregroundColor(.holoTextPrimary)
                        Text(row.detail)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
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

    private func loadDateData() async {
        let data = await repository.fetchDayData(for: selectedDate)
        switch type {
        case .steps:
            currentValue = data.steps
            currentAvailability = data.steps > 0 ? .available : .noData
        case .sleep:
            currentValue = data.sleep
            currentAvailability = data.sleep > 0 ? .available : .noData
            // 复用 AI 工具已有的按晚聚合明细，无阶段数据时卡片自动隐藏
            sleepDetail = await repository.fetchSleepDetailRange(from: selectedDate, to: selectedDate).first
        case .standHours:
            currentValue = data.standHours
            currentAvailability = data.standHours > 0 ? .available : (data.activeMinutes > 0 ? .unsupported : .noData)
        case .activeMinutes:
            currentValue = data.activeMinutes
            currentAvailability = data.activeMinutes > 0 ? .available : .noData
        }
    }

    private var weeklyAverage: Double {
        guard !weeklyData.isEmpty else { return 0 }
        return weeklyData.reduce(0) { $0 + $1.value } / Double(weeklyData.count)
    }

    private var detailSubtitleText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) {
            return "近 7 天趋势与关联线索"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: selectedDate)) 及近 7 天趋势"
    }

    private var weeklyMax: Double {
        weeklyData.map(\.value).max() ?? 0
    }

    private var goalDays: Int {
        weeklyData.filter { $0.value >= type.dailyGoal }.count
    }

    private var remainingValue: Double {
        max(type.dailyGoal - currentValue, 0)
    }

    private var detailTitle: String {
        switch type {
        case .steps:
            return remainingValue > 0 ? "还差 \(type.formatValue(remainingValue)) 步" : "步数目标已达成"
        case .sleep:
            return currentValue >= 7 ? "恢复良好" : "今晚优先补睡眠"
        case .standHours:
            return remainingValue > 0 ? "还差 \(type.formatValue(remainingValue)) 小时" : "站立目标已达成"
        case .activeMinutes:
            return "已启用替代环"
        }
    }

    private var detailSubtitle: String {
        switch type {
        case .steps:
            return "晚饭后 15 分钟散步，大概率能补齐今天的活动环。"
        case .sleep:
            return "睡眠接近目标时，第二天更适合安排高专注任务。"
        case .standHours:
            return "久坐通常集中在下午，可以把站立提醒放到 14:00 后。"
        case .activeMinutes:
            return "没有站立数据时，HOLO 用活动分钟替代站立环来估算久坐风险。"
        }
    }

    private var insightTitle: String {
        switch type {
        case .steps:
            return "活动建议"
        case .sleep:
            return "恢复洞察"
        case .standHours, .activeMinutes:
            return "久坐提醒"
        }
    }

    private var insightDetail: String {
        switch type {
        case .steps:
            return "本周低步数日通常也是久坐日，可以把站立提醒和散步目标合并触发。"
        case .sleep:
            return "高睡眠日，任务完成率更稳定；低睡眠日，咖啡支出和压力记录更值得回看。"
        case .standHours:
            return "站立不足时，压力类想法更容易集中出现，下午适合设置轻提醒。"
        case .activeMinutes:
            return "无 Apple Watch 时不隐藏健康模块，而是明确显示替代指标和当前数据精度。"
        }
    }

    private var relatedRows: [(badge: String, title: String, detail: String, color: Color)] {
        switch type {
        case .steps:
            return [
                ("习", "运动习惯正在拉动步数", "连续运动后，步数达标日更稳定。", .holoSuccess),
                ("任", "低步数日适合少排外出任务", "活动不足时，任务安排可以更轻。", .holoChart1)
            ]
        case .sleep:
            return [
                ("任", "任务关联", "高睡眠日，任务完成率更稳定。", .holoChart1),
                ("财", "消费关联", "低睡眠日，咖啡支出更容易上升。", .holoChart8)
            ]
        case .standHours, .activeMinutes:
            return [
                ("想", "压力关联", "久坐日更适合回看压力类想法。", .holoChart7),
                ("习", "习惯关联", "短散步和喝水习惯能帮助打断久坐。", .holoSuccess)
            ]
        }
    }

    private func loadWeeklyData() async {
        isLoading = true
        weeklyData = await repository.fetchWeeklyData(for: type, endingOn: selectedDate)
        isLoading = false
    }

}

#Preview {
    NavigationStack {
        HealthDetailView(type: .sleep, selectedDate: Date())
    }
}
