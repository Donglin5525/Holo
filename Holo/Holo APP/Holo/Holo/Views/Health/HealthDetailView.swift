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
    @Binding var selectedDate: Date

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repository = HealthRepository.shared
    @State private var weeklyData: [DailyHealthData] = []
    @State private var isLoading = true
    /// 日/周加载共享代数（R10，2026-10-04 体检）：快速切天时过期请求不发布、不提前关加载态
    @State private var detailLoadGeneration = 0
    @State private var currentValue: Double = 0
    @State private var currentAvailability: HealthMetricAvailability = .noData
    @State private var sleepDetail: HealthSleepDetail?
    @State private var sleepTimeline: HealthSleepTimeline?
    /// 按晚还原结果（方案第三步：详情与首页、「今日」同一晚同源）
    @State private var nightRecord: HealthNightSleepRecord?
    @State private var nightVitals: HealthNightVitals?
    @State private var hourlySteps: HourlyStepsData?
    @State private var workoutSessions: [WorkoutSessionData] = []
    @State private var selectedSession: WorkoutSessionData?
    /// 左右滑动切天的实时手势标记：快速轻扫时点击回调需同步读取，防止误触进运动详情
    @State private var daySwipeState = DaySwipeGestureState()

    private var metric: HealthMetricSnapshot {
        HealthMetricSnapshot(type: type, value: currentValue, availability: currentAvailability)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            // 左右滑动切天（与看板页共用容器）：左缘 24pt 让位给右滑返回手势
            DaySwipeContainer(
                state: daySwipeState,
                onDayChange: { forward in switchDay(forward: forward) },
                canSwipeForward: !Calendar.current.isDateInToday(selectedDate),
                edgeExclusionWidth: 24
            ) {
                ScrollView(showsIndicators: false) {
                    // 阅读动线：当日大环 → 当日结构（为什么）→ 周统计 → 周趋势 → 解读（洞察/关联），
                    // 同粒度内容相邻，避免日/周来回跳
                    VStack(spacing: HoloSpacing.md) {
                        if type == .sleep {
                            sleepSummaryCard
                        } else {
                            bigRingCard
                        }

                        if type == .sleep {
                            // 阶段三态：有分期=总量卡+时间轴卡；无分期但有时长=引导卡；无数据=不显示
                            if let sleepDetail, sleepDetail.hasStageData {
                                if let sleepTimeline {
                                    SleepTimelineCard(timeline: sleepTimeline, detail: sleepDetail)
                                        .daySwipeExcluded()
                                }
                                SleepStagesCard(detail: sleepDetail)
                            } else if let sleepDetail, sleepDetail.totalHours > 0 {
                                SleepStageGuideCard()
                            }

                            // 按晚结果补充：来源与状态、额外睡眠段（小睡/待确认候选）、睡眠体征
                            if let record = nightRecord {
                                nightSourcesCard(record)
                                nightExtrasCard(record)
                                if let vitals = nightVitals {
                                    HealthNightVitalsCard(vitals: vitals)
                                }
                            }
                        }

                        if type == .steps, let hourlySteps {
                            DailyActivityPatternCard(hourly: hourlySteps)
                                .daySwipeExcluded()
                        }

                        if type == .workout {
                            if workoutSessions.isEmpty {
                                workoutEmptyCard
                            } else {
                                WorkoutSessionListCard(sessions: workoutSessions) { session in
                                    guard !daySwipeState.isSwiping else { return }
                                    selectedSession = session
                                }
                            }
                        }

                        statsSection

                        trendSection

                        insightSection
                        if !relatedRows.isEmpty { relatedSection }
                    }
                    .padding(HoloSpacing.md)
                    // 纵读详情页在 iPad 限宽居中（通宵冲刺 D1，B-P1-3）；iPhone 直通
                    .holoContentColumn(paintsBackground: false)
                }
            }
        }
        .background(Color.holoToolBackground)
        #if canImport(UIKit)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            dismiss()
        }
        .sheet(item: $selectedSession) { session in
            WorkoutSessionDetailSheet(session: session)
        }
        .task {
            await loadDateData(for: selectedDate)
            await loadWeeklyData(for: selectedDate)
        }
        .onChange(of: selectedDate) {
            Task {
                await loadDateData(for: selectedDate)
                await loadWeeklyData(for: selectedDate)
            }
        }
    }

    /// 无运动记录的诚实空态（当日没有运动是正常状态，不伪装成异常）
    private var workoutEmptyCard: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "figure.run")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))
            Text("这一天没有运动记录")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .holoSurface()
    }

    /// 近 7 天趋势（图内自带标题与均值行，外层不再重复标题）
    private var trendSection: some View {
        ZStack(alignment: .topTrailing) {
            HealthTrendChart(data: weeklyData, type: type, endingOn: selectedDate)
            if isLoading {
                ProgressView()
                    .scaleEffect(0.75)
                    .padding(6)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
        .daySwipeExcluded()
    }

    private var detailHeader: some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack(alignment: .top, spacing: HoloSpacing.md) {
                backButton

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HoloSpacing.sm) {
                        detailHeaderText
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: HoloSpacing.sm)

                        if type != .sleep { detailStatusBadge }
                    }

                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        detailHeaderText
                        if type != .sleep { detailStatusBadge }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }

            HealthDateNavigator(selectedDate: $selectedDate)
        }
        .padding(.horizontal, HoloSpacing.page)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
    }

    private var detailHeaderText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(type.displayName)
                .holoText(.pageTitle)
                .foregroundColor(.holoToolText)
                .lineLimit(1)

            Text(detailSubtitleText)
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
                .lineLimit(1)
        }
    }

    private var detailStatusBadge: some View {
        Text(metric.statusText)
            .holoText(.metadata)
            .foregroundColor(type.color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(type.color.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    /// 返回按钮（对齐全局 fullScreenCover 模块约定，复用 HealthView 样式）
    private var backButton: some View {
        HoloIconButton(systemName: "chevron.left", title: "返回", showsSurface: true) {
            dismiss()
        }
    }

    private var bigRingCard: some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                HoloProgress(value: metric.availability == .available ? metric.progress : nil,
                             color: type.color, shape: .ring, lineWidth: 18)
                    .frame(width: 152, height: 152)

                VStack(spacing: 2) {
                    Text(metric.valueText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(type.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Text(metric.type.unit)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)
                }
                .frame(width: 92)
            }

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(detailTitle)
                    .holoText(.sectionTitle)
                    .foregroundColor(.holoToolText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detailSubtitle)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineSpacing(2)

                Text(metric.statusText)
                    .holoText(.metadata)
                    .foregroundColor(type.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(type.color.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .stroke(Color.holoToolBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 6, y: 2)
    }

    /// 睡眠优先展示记录与时长目标，避免把达标百分比误读成睡眠质量评分。
    private var sleepSummaryCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("总睡眠")
                    .holoText(.body)
                    .foregroundStyle(Color.holoToolText)
                Text(sleepDetail.map { SleepStagesCard.formatHours($0.totalHours) } ?? String(localized: "未记录"))
                    .holoText(.amount)
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text((sleepDetail?.napCount ?? 0) > 0 ? "按记录结束日归属 · 含小睡" : "按记录结束日归属")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            if let main = nightRecord?.mainSession {
                // 入睡 / 记录结束（生活事实分开标注，与首页同一结果）
                HStack(spacing: HoloSpacing.lg) {
                    Label("\(Self.clockFormatter.string(from: main.start)) 入睡", systemImage: "moon.zzz.fill")
                    Label("\(Self.clockFormatter.string(from: main.asleepEnd)) 记录结束", systemImage: "alarm.fill")
                }
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                Text(String(localized: "时长目标 \(SleepStagesCard.formatHours(type.dailyGoal))"))
                Spacer(minLength: HoloSpacing.sm)
                Text(metric.availability == .available ? metric.statusText : String(localized: "未记录"))
                    .monospacedDigit()
            }
            .holoText(.metadata)
            .foregroundStyle(Color.holoToolTextSecondary)
            HoloProgress(value: metric.availability == .available ? metric.progress : nil, color: type.color, lineWidth: 8)
                .accessibilityHidden(true)
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    /// 来源与状态卡：记录来自哪里、分期可信度、边界完整性、待确认候选
    private func nightSourcesCard(_ record: HealthNightSleepRecord) -> some View {
        let sessions = (record.mainSession.map { [$0] } ?? []) + record.extraSessions
        let sources = Array(Set(sessions.flatMap(\.sources))).sorted { $0.name < $1.name }
        let anyPending = sessions.contains { $0.stageStatus == .conflicting }
        let anyIncomplete = sessions.contains { $0.possiblyIncomplete }
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("记录来源")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                Spacer()
                Text(sources.map(\.name).joined(separator: " · "))
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
            }

            if record.mainAmbiguous {
                Text("这一结束日有两段相近的长睡眠，暂缓主睡眠对比，两段都按实际记录展示。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if anyPending {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text("两个来源对这段睡眠的记录相差明显，无法裁决——这段不参与趋势比较。")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(sessions.flatMap(\.candidates).enumerated()), id: \.offset) { _, candidate in
                        Text("· \(candidate.source.name)：\(Self.clockFormatter.string(from: candidate.start))–\(Self.clockFormatter.string(from: candidate.asleepEnd)) · \(SleepStagesCard.formatHours(candidate.asleepSeconds / 3600))\(candidate.staged ? " · 有分期" : " · 仅时长")")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
            }
            if anyIncomplete {
                Text("这段记录连接到读取边界，可能不完整。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolWarning)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    /// 额外睡眠段卡：小睡 / 其他睡眠 / 孤立短记录单列（不并入主睡眠）
    private func nightExtrasCard(_ record: HealthNightSleepRecord) -> some View {
        Group {
            if !record.extraSessions.isEmpty {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("额外睡眠记录")
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)

                    ForEach(Array(record.extraSessions.enumerated()), id: \.offset) { _, session in
                        HStack {
                            Text(kindLabel(session.kind))
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundColor(.holoToolText)
                            Spacer()
                            Text("\(Self.clockFormatter.string(from: session.start))–\(Self.clockFormatter.string(from: session.asleepEnd)) · \(SleepStagesCard.formatHours(session.asleepHours))")
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoToolTextSecondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(HoloSpacing.md)
                .holoSurface()
            }
        }
    }

    private func kindLabel(_ kind: HealthNightSession.Kind) -> String {
        switch kind {
        case .main: return String(localized: "主睡眠")
        case .nap: return String(localized: "小睡")
        case .otherSleep: return String(localized: "其他睡眠")
        case .record: return String(localized: "睡眠记录")
        }
    }

    /// 按晚结果 → 既有明细卡数据（时间轴/阶段卡继续用 HealthSleepDetail 渲染，口径来自主睡眠）
    private static func sleepDetail(fromRecord record: HealthNightSleepRecord) -> HealthSleepDetail? {
        guard let main = record.mainSession else { return nil }
        let awakeHours = main.timeline
            .filter { $0.stage == .awake }
            .reduce(0.0) { $0 + $1.duration } / 3600
        let naps = record.extraSessions.filter { $0.kind == .nap }
        let stages = main.stageHours
        return HealthSleepDetail(
            date: record.endDate,
            totalHours: main.asleepHours,
            coreHours: stages?.core,
            deepHours: stages?.deep,
            remHours: stages?.rem,
            awakeHours: awakeHours > 0 ? awakeHours : nil,
            inBedHours: main.bedStart.map { max(main.sessionEnd.timeIntervalSince($0), 0) / 3600 },
            bedtime: main.start,
            wakeTime: main.asleepEnd,
            interruptionCount: main.awakeInterruptions,
            napCount: naps.isEmpty ? nil : naps.count,
            napHours: naps.isEmpty ? nil : naps.reduce(0.0) { $0 + $1.asleepHours }
        )
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var statsSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            statCard(title: type == .sleep ? String(localized: "有记录晚均") : String(localized: "7 天平均"), value: weeklyData.isEmpty ? "—" : type.formatValue(weeklyAverage), unit: type.unit)
            statCard(title: type == .sleep ? String(localized: "最长睡眠") : String(localized: "最高值"), value: weeklyData.isEmpty ? "—" : type.formatValue(weeklyMax), unit: type.unit)
            statCard(title: type == .sleep ? String(localized: "时长达标") : String(localized: "达标天数"), value: weeklyData.isEmpty ? "—" : "\(goalDays)", unit: type == .sleep ? String(localized: "晚") : String(localized: "天"))
        }
    }

    private func statCard(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.holoToolText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(unit)
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoToolBorder, lineWidth: 1)
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
                    .holoText(.body)
                    .foregroundColor(.holoToolText)

                Text(insightDetail)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
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
                .holoText(.body)
                .foregroundColor(.holoToolText)

            ForEach(relatedRows, id: \.title) { row in
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Text(row.badge)
                        .holoText(.metadata)
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(row.color)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .holoText(.metadata)
                            .foregroundColor(.holoToolText)
                        Text(row.detail)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    Spacer()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoToolBorder, lineWidth: 1)
        )
    }

    private func loadDateData(for date: Date) async {
        // R10（2026-10-04 体检）：日期作为请求身份，await 后不读变化中的 selectedDate；
        // 各分支取齐全部数据后一次性发布，不再出现数值/明细来自不同日期的混合态
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let data = await repository.fetchDayData(for: date)
        switch type {
        case .steps:
            let hourly = await repository.fetchHourlySteps(for: date)
            guard generation == detailLoadGeneration else { return }
            currentValue = data.steps
            currentAvailability = data.steps > 0 ? .available : .noData
            hourlySteps = hourly
        case .sleep:
            // 按晚统一口径（方案第三步）：归属按「最后一段可信睡着记录结束时刻」，
            // 与首页、「今日」同一晚同源；无主睡眠记录 = 未记录，不回退自然日合计
            let night = await repository.fetchNightSleepStrict(forEndDay: date)
            var vitals: HealthNightVitals?
            if case .value(let record) = night, let main = record?.mainSession {
                if case .value(let v) = await repository.fetchNightVitals(for: main) {
                    vitals = v
                }
            }
            guard generation == detailLoadGeneration else { return }
            // fetchNightSleepStrict 的载荷本身可选（nil = 该结束日无记录），拍平双层可选
            let record: HealthNightSleepRecord? = night.valueIfAvailable ?? nil
            nightRecord = record
            nightVitals = vitals
            let detail = record.flatMap(Self.sleepDetail(fromRecord:))
            let timeline: HealthSleepTimeline? = record?.mainSession.map {
                HealthSleepTimeline(wakeDay: date, segments: $0.timeline, hasStageData: $0.stageHours != nil)
            }
            currentValue = detail?.totalHours ?? 0
            currentAvailability = detail == nil ? .noData : .available
            sleepDetail = detail
            sleepTimeline = timeline
        case .standHours:
            guard generation == detailLoadGeneration else { return }
            currentValue = data.standHours
            currentAvailability = data.standHours > 0 ? .available : (data.activeMinutes > 0 ? .unsupported : .noData)
        case .activeMinutes:
            guard generation == detailLoadGeneration else { return }
            currentValue = data.activeMinutes
            currentAvailability = data.activeMinutes > 0 ? .available : .noData
        case .workout:
            guard generation == detailLoadGeneration else { return }
            workoutSessions = data.workoutSessions
            currentValue = data.workoutMinutes
            currentAvailability = data.workoutMinutes > 0 ? .available : .noData
        }
    }

    private var weeklyAverage: Double {
        DailyHealthData.averageValue(in: weeklyData) ?? 0
    }

    private var detailSubtitleText: String {
        if type == .sleep { return String(localized: "整晚记录与近 7 天趋势") }
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) {
            return String(localized: "近 7 天趋势与关联线索")
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return String(localized: "\(formatter.string(from: selectedDate)) 及近 7 天趋势")
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
            return remainingValue > 0 ? String(localized: "还差 \(type.formatValue(remainingValue)) 步") : String(localized: "步数目标已达成")
        case .sleep:
            return currentValue >= HealthThresholds.sleepQualityGoodHours ? String(localized: "恢复良好") : String(localized: "今晚优先补睡眠")
        case .standHours:
            return remainingValue > 0 ? String(localized: "还差 \(type.formatValue(remainingValue)) 小时") : String(localized: "站立目标已达成")
        case .activeMinutes:
            return String(localized: "已启用替代环")
        case .workout:
            return currentValue > 0
                ? String(localized: "今日已运动 \(Int(currentValue.rounded())) 分钟")
                : String(localized: "今天还没有运动记录")
        }
    }

    private var detailSubtitle: String {
        // 基于本周达标天数给出诚实陈述，不编造无依据的"建议"
        switch type {
        case .steps:
            if weeklyData.isEmpty {
                return String(localized: "近 7 天暂无步数数据。")
            }
            return goalDays >= 5
                ? String(localized: "本周步数稳定，保持节奏即可。")
                : String(localized: "本周有 \(goalDays) 天达标，还可以再稳定一些。")
        case .sleep:
            if weeklyData.isEmpty {
                return String(localized: "近 7 天暂无睡眠数据。")
            }
            return weeklyAverage >= HealthThresholds.sleepQualityGoodHours
                ? String(localized: "本周平均睡眠充足，适合安排高专注任务。")
                : String(localized: "本周平均睡眠偏少，注意补充休息。")
        case .standHours:
            if weeklyData.isEmpty {
                return String(localized: "近 7 天暂无站立数据。")
            }
            return goalDays >= 5
                ? String(localized: "本周站立规律，久坐风险较低。")
                : String(localized: "本周有 \(goalDays) 天达标，可适当增加站立时间。")
        case .activeMinutes:
            return String(localized: "没有站立数据时，HOLO 用活动分钟替代站立环来估算久坐风险。")
        case .workout:
            if weeklyData.isEmpty {
                return String(localized: "近 7 天暂无运动数据。")
            }
            return goalDays >= 3
                ? String(localized: "本周有 \(goalDays) 天运动达标，节奏不错。")
                : String(localized: "本周有 \(goalDays) 天运动达标，规律比单次强度更重要。")
        }
    }

    private var insightTitle: String {
        switch type {
        case .steps:
            return String(localized: "活动建议")
        case .sleep:
            return String(localized: "近 7 晚记录")
        case .standHours, .activeMinutes:
            return String(localized: "久坐提醒")
        case .workout:
            return String(localized: "运动洞察")
        }
    }

    private var insightDetail: String {
        switch type {
        case .steps:
            return String(localized: "本周低步数日通常也是久坐日，可以把站立提醒和散步目标合并触发。")
        case .sleep:
            if weeklyData.isEmpty { return String(localized: "近 7 晚尚无睡眠记录，暂无可比较的趋势。") }
            return String(localized: "7 晚中有 \(weeklyData.count) 晚记录，其中 \(goalDays) 晚达到时长目标。其余 \(max(7 - weeklyData.count, 0)) 晚未记录，不参与平均值计算。")
        case .standHours:
            return String(localized: "站立不足时，压力类想法更容易集中出现，下午适合设置轻提醒。")
        case .activeMinutes:
            return String(localized: "无 Apple Watch 时不隐藏健康模块，而是明确显示替代指标和当前数据精度。")
        case .workout:
            return String(localized: "规律运动与睡眠恢复互相促进。连续记录后，HOLO 会把运动和睡眠、任务、习惯串起来看。")
        }
    }

    private var relatedRows: [(badge: String, title: String, detail: String, color: Color)] {
        switch type {
        case .steps:
            return [
                (String(localized: "习"), String(localized: "运动习惯正在拉动步数"), String(localized: "连续运动后，步数达标日更稳定。"), .holoSuccess),
                (String(localized: "任"), String(localized: "低步数日适合少排外出任务"), String(localized: "活动不足时，任务安排可以更轻。"), .holoChart1)
            ]
        case .sleep:
            // 尚无成对数据分析，不能把固定文案包装成个人关联结论。
            return []
        case .standHours, .activeMinutes:
            return [
                (String(localized: "想"), String(localized: "压力关联"), String(localized: "久坐日更适合回看压力类想法。"), .holoChart7),
                (String(localized: "习"), String(localized: "习惯关联"), String(localized: "短散步和喝水习惯能帮助打断久坐。"), .holoSuccess)
            ]
        case .workout:
            return [
                (String(localized: "健"), String(localized: "恢复关联"), String(localized: "运动日的深睡通常更多，入睡也更快。"), .holoChart1),
                (String(localized: "任"), String(localized: "精力关联"), String(localized: "运动后的下午，专注类任务完成更稳。"), .holoPrimary)
            ]
        }
    }

    private func loadWeeklyData(for date: Date) async {
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        isLoading = true
        let data: [DailyHealthData]
        if type == .sleep {
            // 周趋势与单晚同一按晚口径（方案第三步：点同一晚数字一致）
            let end = Calendar.current.startOfDay(for: date)
            let start = Calendar.current.date(byAdding: .day, value: -6, to: end) ?? end
            if case .value(let records) = await repository.fetchNightSleepRangeStrict(from: start, to: end) {
                data = records.compactMap { record in
                    record.mainSession.map { DailyHealthData(date: record.endDate, value: $0.asleepHours) }
                }
            } else {
                data = []
            }
        } else {
            data = await repository.fetchChartWeeklyData(for: type, endingOn: date)
        }
        // R10：过期请求不发布，也不替新请求提前关掉加载态
        guard generation == detailLoadGeneration else { return }
        weeklyData = data
        isLoading = false
    }

    /// 左右滑动切天：与看板页、日期胶囊共用同一条边界规则（不越过今天）
    private func switchDay(forward: Bool) {
        guard let newDate = HealthDateNavigator.steppedDate(from: selectedDate, forward: forward) else { return }
        withAnimation(HoloAnimation.standard) {
            selectedDate = newDate
        }
    }

}

#Preview {
    struct PreviewWrapper: View {
        @State private var date = Calendar.current.startOfDay(for: Date())
        var body: some View {
            NavigationStack {
                HealthDetailView(type: .sleep, selectedDate: $date)
            }
        }
    }
    return PreviewWrapper()
}
