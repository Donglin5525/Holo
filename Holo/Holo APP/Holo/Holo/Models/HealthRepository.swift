//
//  HealthRepository.swift
//  Holo
//
//  健康数据仓库
//  负责读取 HealthKit 数据（步数、睡眠、站立时长）
//

import Foundation
import HealthKit
import Combine

// MARK: - HealthSleepSampleAggregator

struct HealthSleepSampleAggregator {
    struct Interval {
        let start: Date
        let end: Date
    }

    /// 排序并合并重叠/相接的区间（多设备多源同晚记录天然重叠）。
    static func merged(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var result: [Interval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = Interval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    static func totalHours(for intervals: [Interval]) -> Double {
        let seconds = merged(intervals).reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return seconds / 3600
    }

    static func clippedInterval(start: Date, end: Date, to window: Interval) -> Interval? {
        let clippedStart = max(start, window.start)
        let clippedEnd = min(end, window.end)
        guard clippedEnd > clippedStart else { return nil }
        return Interval(start: clippedStart, end: clippedEnd)
    }
}

struct HealthSleepDetail: Sendable {
    var date: Date
    var totalHours: Double
    var coreHours: Double?
    var deepHours: Double?
    var remHours: Double?
    var awakeHours: Double?
    var inBedHours: Double?
    var bedtime: Date?
    var wakeTime: Date?
    var interruptionCount: Int?
    // 睡眠结构特征（SleepStructureAnalyzer 产出）。
    // nil = 无阶段数据（需 Apple Watch 分期）或多源错位，不得当 0 解读。
    var remEpisodes: Int? = nil
    var remLatencyMinutes: Double? = nil
    var deepFrontLoadPercent: Double? = nil
    var sleepOnsetLatencyMinutes: Double? = nil

    /// 是否包含睡眠阶段数据（深睡/浅睡/REM），无 Apple Watch 类数据源时为 false
    var hasStageData: Bool {
        deepHours != nil || coreHours != nil || remHours != nil
    }
}

/// 每日 24 小时步数桶（index = 小时），供活动分布分析。
struct HourlyStepsData: Sendable {
    let date: Date
    let hourly: [Double]
}

/// 每日体征（二期身体状态页）。字段 nil = 当日无该项样本（不可得 ≠ 0）。
/// 静息心率/HRV/呼吸频率均需 Apple Watch 产生。
struct DailyVitals: Sendable {
    let date: Date
    var restingHeartRate: Double?
    var heartRateVariability: Double?
    var respiratoryRate: Double?
}

// MARK: - HealthStandHourAggregator

struct HealthStandHourAggregator {
    static func stoodHours(for samples: [HKCategorySample], in window: HealthSleepSampleAggregator.Interval) -> Double {
        let calendar = Calendar.current
        let stoodHourKeys = samples.compactMap { sample -> Date? in
            guard sample.value == HKCategoryValueAppleStandHour.stood.rawValue,
                  HealthSleepSampleAggregator.clippedInterval(start: sample.startDate, end: sample.endDate, to: window) != nil
            else {
                return nil
            }
            return calendar.dateInterval(of: .hour, for: sample.startDate)?.start
        }

        return Double(Set(stoodHourKeys).count)
    }
}

// MARK: - HealthRepository

/// 健康数据仓库
/// 使用 @MainActor 保证所有操作在主线程执行
@MainActor
class HealthRepository: ObservableObject {

    // MARK: - Singleton

    static let shared = HealthRepository()

    // MARK: - Published Properties

    /// 是否已授权
    @Published var isAuthorized: Bool = false

    /// 是否已请求过权限（持久化，App 重启后仍记住）
    @Published var hasRequestedPermission: Bool = UserDefaults.standard.bool(forKey: "HealthKit.hasRequestedPermission") {
        didSet { UserDefaults.standard.set(hasRequestedPermission, forKey: "HealthKit.hasRequestedPermission") }
    }

    /// 今日步数
    @Published var todaySteps: Double = 0

    /// 今日睡眠时长（小时）
    @Published var todaySleep: Double = 0

    /// 今日站立时长（小时）
    @Published var todayStandHours: Double = 0

    /// 今日活动分钟（无 Apple Watch 时作为站立替代指标）
    @Published var todayActiveMinutes: Double = 0

    /// 各指标可用状态
    @Published var stepsAvailability: HealthMetricAvailability = .noData
    @Published var sleepAvailability: HealthMetricAvailability = .noData
    @Published var standAvailability: HealthMetricAvailability = .noData
    @Published var activeMinutesAvailability: HealthMetricAvailability = .noData

    /// Apple Health 数据源状态
    @Published var dataSourceState: HealthDataSourceState = .notRequested

    /// 错误信息
    @Published var errorMessage: String?

    // MARK: - Properties

    /// HealthKit 存储
    private let healthStore = HKHealthStore()

    /// 是否使用模拟数据（模拟器环境）
    private let useMockData: Bool

    // MARK: - Initialization

    private init() {
        // 模拟器无法访问 HealthKit，自动启用模拟数据
        #if targetEnvironment(simulator)
        useMockData = true
        #else
        useMockData = false
        #endif

        if useMockData {
            isAuthorized = true
            hasRequestedPermission = true
            dataSourceState = .connected
            Task {
                await fetchTodayData()
            }
        } else if HKHealthStore.isHealthDataAvailable() {
            Task {
                await checkAuthorizationStatus()
            }
        } else {
            dataSourceState = .unavailable
        }
    }

    // MARK: - 权限管理

    /// 检查授权状态
    func checkAuthorizationStatus() async {
        if useMockData {
            isAuthorized = true
            hasRequestedPermission = true
            dataSourceState = .connected
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            isAuthorized = false
            dataSourceState = .unavailable
            return
        }

        // HealthKit deliberately does not expose reliable read-authorization
        // status. Once the read request has completed, keep the module in a
        // connected state and let fetch results decide per-metric availability.
        if hasRequestedPermission || hasAnyFetchedData {
            isAuthorized = true
            if dataSourceState == .notRequested || dataSourceState == .denied {
                dataSourceState = .connected
            }
        } else {
            isAuthorized = false
            dataSourceState = .notRequested
        }
    }

    /// 请求 HealthKit 授权
    func requestAuthorization() {
        // 模拟数据模式直接返回成功
        if useMockData {
            self.isAuthorized = true
            self.hasRequestedPermission = true
            self.dataSourceState = .connected
            Task {
                await fetchTodayData()
            }
            return
        }

        // 检查 HealthKit 是否可用
        guard HKHealthStore.isHealthDataAvailable() else {
            self.errorMessage = String(localized: "HealthKit 不可用")
            self.dataSourceState = .unavailable
            return
        }

        // 调用 HealthKit 授权（异步回调，不会阻塞主线程）
        healthStore.requestAuthorization(toShare: nil, read: Set(readTypes)) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hasRequestedPermission = true
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    self.dataSourceState = .denied
                    self.isAuthorized = false
                } else {
                    self.dataSourceState = .connected
                    self.isAuthorized = true
                }
                Task {
                    if success {
                        await self.fetchTodayData()
                    }
                }
            }
        }
    }

    /// 刷新授权和今日数据
    func refresh() async {
        await checkAuthorizationStatus()
        if isAuthorized || hasRequestedPermission || useMockData {
            await fetchTodayData()
        }
    }

    // MARK: - 获取今日数据

    /// 获取今日所有健康数据
    func fetchTodayData() async {
        if useMockData {
            await loadMockTodayData()
            return
        }

        async let steps = fetchSteps(for: Date())
        async let sleep = fetchSleep(for: Date())
        async let stand = fetchStandTime(for: Date())
        async let activeMinutes = fetchActiveMinutes(for: Date())

        let (stepsValue, sleepValue, standValue, activeMinutesValue) = await (steps, sleep, stand, activeMinutes)

        await MainActor.run {
            self.todaySteps = stepsValue
            self.todaySleep = sleepValue
            self.todayStandHours = standValue
            self.todayActiveMinutes = activeMinutesValue
            self.updateAvailabilityAfterFetch()
        }
    }

    // MARK: - 获取指定日期数据

    /// 获取指定日期的所有健康数据
    func fetchDayData(for date: Date) async -> (steps: Double, sleep: Double, standHours: Double, activeMinutes: Double) {
        if useMockData {
            return (
                steps: Double(Int.random(in: 5000...12000)),
                sleep: Double(Int.random(in: 5...9)) + Double.random(in: 0...0.9),
                standHours: Double(Int.random(in: 8...14)),
                activeMinutes: Double(Int.random(in: 18...55))
            )
        }
        async let steps = fetchSteps(for: date)
        async let sleep = fetchSleep(for: date)
        async let stand = fetchStandTime(for: date)
        async let activeMinutes = fetchActiveMinutes(for: date)
        return await (steps, sleep, stand, activeMinutes)
    }

    // MARK: - 获取历史数据

    /// 获取 7 天历史数据（以指定日期为终点，默认到今天）
    func fetchWeeklyData(for type: HealthMetricType, endingOn endDate: Date? = nil) async -> [DailyHealthData] {
        if useMockData {
            return generateMockWeeklyData(for: type, endingOn: endDate ?? Date())
        }

        let calendar = Calendar.current
        let end = endDate ?? Date()
        guard let startDate = calendar.date(byAdding: .day, value: -6, to: end) else {
            return []
        }

        var results: [DailyHealthData] = []

        var currentDate = startDate
        while currentDate <= end {
            let value: Double

            switch type {
            case .steps:
                value = await fetchSteps(for: currentDate)
            case .sleep:
                value = await fetchSleep(for: currentDate)
            case .standHours:
                value = await fetchStandTime(for: currentDate)
            case .activeMinutes:
                value = await fetchActiveMinutes(for: currentDate)
            }

            results.append(DailyHealthData(date: currentDate, value: value))

            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDate
        }

        return results
    }

    // MARK: - 日期范围查询（AI 分析用）

    /// 获取指定日期范围的步数数据
    func fetchStepsRange(from start: Date, to end: Date) async -> [DailyHealthData] {
        await fetchRange(for: .steps, from: start, to: end)
    }

    /// 获取指定日期范围的睡眠数据
    func fetchSleepRange(from start: Date, to end: Date) async -> [DailyHealthData] {
        await fetchRange(for: .sleep, from: start, to: end)
    }

    /// 获取按起床日归属的一晚睡眠明细。使用“前一日中午到当日中午”窗口，
    /// 避免跨午夜睡眠被拆成两天；阶段缺失时保留 nil 供上层明确降级。
    func fetchSleepDetailRange(from start: Date, to end: Date) async -> [HealthSleepDetail] {
        if useMockData {
            let calendar = Calendar.current
            var records: [HealthSleepDetail] = []
            var wakeDay = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: end)
            while wakeDay <= endDay {
                if let detail = Self.mockSleepDetail(forWakeDay: wakeDay) {
                    records.append(detail)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: wakeDay) else { break }
                wakeDay = next
            }
            return records
        }
        let calendar = Calendar.current
        var records: [HealthSleepDetail] = []
        var wakeDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while wakeDay <= endDay {
            if let detail = await fetchSleepDetail(forWakeDay: wakeDay), detail.totalHours > 0 {
                records.append(detail)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: wakeDay) else { break }
            wakeDay = next
        }
        return records
    }

    /// 获取指定日期范围的站立数据
    func fetchStandTimeRange(from start: Date, to end: Date) async -> [DailyHealthData] {
        await fetchRange(for: .standHours, from: start, to: end)
    }

    /// 获取指定日期范围的活动分钟数据
    func fetchActiveMinutesRange(from start: Date, to end: Date) async -> [DailyHealthData] {
        await fetchRange(for: .activeMinutes, from: start, to: end)
    }

    /// 通用范围查询
    private func fetchRange(for type: HealthMetricType, from start: Date, to end: Date) async -> [DailyHealthData] {
        if useMockData {
            return generateMockRangeData(for: type, from: start, to: end)
        }

        let calendar = Calendar.current
        var results: [DailyHealthData] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        while current <= endDay {
            let value: Double
            switch type {
            case .steps: value = await fetchSteps(for: current)
            case .sleep: value = await fetchSleep(for: current)
            case .standHours: value = await fetchStandTime(for: current)
            case .activeMinutes: value = await fetchActiveMinutes(for: current)
            }
            results.append(DailyHealthData(date: current, value: value))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    // MARK: - 私有方法 - 真实数据获取

    /// 获取指定日期的步数（best-effort：UI 语义不变，错误回落 0）
    private func fetchSteps(for date: Date) async -> Double {
        switch await fetchStepsStrict(for: date) {
        case .value(let value): return value
        case .noData, .waitingForUnlock, .unavailable: return 0
        }
    }

    /// 严格版步数查询（§7.1）：读取 HK 回调 error，锁屏返回 waitingForUnlock，不得伪装 0。
    private func fetchStepsStrict(for date: Date) async -> HoloHealthQueryOutcome<Double> {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return .unavailable(.recoverable(String(localized: "步数类型不可用")))
        }
        return await fetchQuantitySumStrict(quantityType: stepType, unit: .count(), date: date)
    }

    /// 获取指定日期的睡眠时长（小时）（best-effort：UI 语义不变，错误回落 0）
    private func fetchSleep(for date: Date) async -> Double {
        switch await fetchSleepStrict(for: date) {
        case .value(let value): return value
        case .noData, .waitingForUnlock, .unavailable: return 0
        }
    }

    /// 严格版睡眠查询（§7.1）：读取 HK 回调 error；空样本 → noData，不得伪装 0。
    private func fetchSleepStrict(for date: Date) async -> HoloHealthQueryOutcome<Double> {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return .unavailable(.recoverable(String(localized: "睡眠类型不可用")))
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return .noData
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: []
        )
        let dayWindow = HealthSleepSampleAggregator.Interval(start: startOfDay, end: endOfDay)
        let sleepStages: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let failure: HoloHealthQueryOutcome<Double> = HoloStrictHealthQueryService.failure(from: error) {
                    continuation.resume(returning: failure)
                    return
                }
                let categorySamples = (samples as? [HKCategorySample]) ?? []
                let intervals = categorySamples.compactMap { sample -> HealthSleepSampleAggregator.Interval? in
                    guard sleepStages.contains(sample.value) else { return nil }
                    return HealthSleepSampleAggregator.clippedInterval(
                        start: sample.startDate,
                        end: sample.endDate,
                        to: dayWindow
                    )
                }
                guard !intervals.isEmpty else {
                    continuation.resume(returning: .noData)
                    return
                }
                continuation.resume(returning: .value(HealthSleepSampleAggregator.totalHours(for: intervals)))
            }
            healthStore.execute(query)
        }
    }

    /// 按起床日归属的一晚睡眠明细（best-effort：错误回落 nil）
    private func fetchSleepDetail(forWakeDay wakeDay: Date) async -> HealthSleepDetail? {
        switch await fetchSleepDetailStrict(forWakeDay: wakeDay) {
        case .value(let detail): return detail
        case .noData, .waitingForUnlock, .unavailable: return nil
        }
    }

    /// 一晚的睡眠时间轴（二期页面渲染用，best-effort：错误回落 nil）。
    /// 复用归晚窗口（前一日中午到当日中午），样本经 TimelineBuilder 归并。
    func fetchSleepTimeline(forWakeDay wakeDay: Date) async -> HealthSleepTimeline? {
        if useMockData {
            return Self.mockSleepTimeline(forWakeDay: wakeDay)
        }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return nil
        }
        let calendar = Calendar.current
        guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: wakeDay),
              let start = calendar.date(byAdding: .day, value: -1, to: noon) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: noon, options: [])
        let window = HealthSleepSampleAggregator.Interval(start: start, end: noon)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let raw = ((samples as? [HKCategorySample]) ?? []).compactMap { sample -> (value: Int, start: Date, end: Date)? in
                    guard let clipped = HealthSleepSampleAggregator.clippedInterval(
                        start: sample.startDate, end: sample.endDate, to: window
                    ) else { return nil }
                    return (sample.value, clipped.start, clipped.end)
                }
                continuation.resume(returning: HealthSleepTimelineBuilder.build(wakeDay: wakeDay, samples: raw))
            }
            healthStore.execute(query)
        }
    }

    /// 一晚模式化 mock 时间轴（模拟器）：23:30 上床，4 段 REM 集中后半夜，两次夜醒。
    nonisolated private static func mockSleepTimeline(forWakeDay wakeDay: Date) -> HealthSleepTimeline? {
        let calendar = Calendar.current
        guard let bedStart = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: calendar.date(byAdding: .day, value: -1, to: wakeDay) ?? wakeDay) else {
            return nil
        }
        func at(_ minutes: Double) -> Date { bedStart.addingTimeInterval(minutes * 60) }
        func segment(_ stage: HealthSleepSegment.Stage, _ start: Double, _ end: Double) -> HealthSleepSegment {
            HealthSleepSegment(stage: stage, start: at(start), end: at(end))
        }
        let segments = [
            segment(.inBedAwake, 0, 17),
            segment(.asleepDeep, 17, 61),
            segment(.asleepCore, 61, 105),
            segment(.asleepDeep, 105, 148),
            segment(.asleepREM, 148, 160),
            segment(.awake, 160, 172),
            segment(.asleepCore, 172, 215),
            segment(.asleepDeep, 215, 236),
            segment(.asleepREM, 236, 258),
            segment(.asleepCore, 258, 340),
            segment(.awake, 340, 351),
            segment(.asleepREM, 351, 385),
            segment(.asleepCore, 385, 413),
            segment(.asleepREM, 413, 441),
            segment(.asleepCore, 441, 467)
        ]
        return HealthSleepTimeline(wakeDay: wakeDay, segments: segments, hasStageData: true)
    }

    /// mock 睡眠明细：直接由 mock 时间轴分段聚合推导，保证与时间轴/结构特征一致。
    nonisolated private static func mockSleepDetail(forWakeDay wakeDay: Date) -> HealthSleepDetail? {
        guard let timeline = mockSleepTimeline(forWakeDay: wakeDay) else { return nil }
        func intervals(_ stage: HealthSleepSegment.Stage) -> [HealthSleepSampleAggregator.Interval] {
            timeline.segments.filter { $0.stage == stage }.map { .init(start: $0.start, end: $0.end) }
        }
        let core = intervals(.asleepCore)
        let deep = intervals(.asleepDeep)
        let rem = intervals(.asleepREM)
        let awake = intervals(.awake)
        let asleep = core + deep + rem
        let structure = SleepStructureAnalyzer.features(
            SleepStructureAnalyzer.NightSegments(asleep: asleep, core: core, deep: deep, rem: rem, inBed: [])
        )
        let bedtime = timeline.segments.map(\.start).min()
        let wakeTime = timeline.segments.map(\.end).max()
        // mock 时间轴只有入睡前的在床段，在床时长按"上床到起床"口径（与真机无在床段 fallback 一致）
        let inBedHours = bedtime.flatMap { bed in wakeTime.map { $0.timeIntervalSince(bed) / 3600 } }
        return HealthSleepDetail(
            date: wakeDay,
            totalHours: HealthSleepSampleAggregator.totalHours(for: asleep),
            coreHours: HealthSleepSampleAggregator.totalHours(for: core),
            deepHours: HealthSleepSampleAggregator.totalHours(for: deep),
            remHours: HealthSleepSampleAggregator.totalHours(for: rem),
            awakeHours: awake.isEmpty ? nil : HealthSleepSampleAggregator.totalHours(for: awake),
            inBedHours: inBedHours,
            bedtime: bedtime,
            wakeTime: wakeTime,
            interruptionCount: awake.filter { $0.end.timeIntervalSince($0.start) >= 120 }.count,
            remEpisodes: structure.remEpisodes,
            remLatencyMinutes: structure.remLatencyMinutes,
            deepFrontLoadPercent: structure.deepFrontLoadPercent,
            sleepOnsetLatencyMinutes: structure.sleepOnsetLatencyMinutes
        )
    }

    /// 严格版睡眠明细查询（§7.1）：读取 HK 回调 error；无睡眠样本 → noData。
    private func fetchSleepDetailStrict(forWakeDay wakeDay: Date) async -> HoloHealthQueryOutcome<HealthSleepDetail> {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return .unavailable(.recoverable(String(localized: "睡眠类型不可用")))
        }
        let calendar = Calendar.current
        guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: wakeDay),
              let start = calendar.date(byAdding: .day, value: -1, to: noon) else { return .noData }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: noon, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let failure: HoloHealthQueryOutcome<HealthSleepDetail> = HoloStrictHealthQueryService.failure(from: error) {
                    continuation.resume(returning: failure)
                    return
                }
                let samples = (samples as? [HKCategorySample]) ?? []
                let window = HealthSleepSampleAggregator.Interval(start: start, end: noon)
                func intervals(_ values: Set<Int>) -> [HealthSleepSampleAggregator.Interval] {
                    samples.compactMap { sample in
                        guard values.contains(sample.value) else { return nil }
                        return HealthSleepSampleAggregator.clippedInterval(start: sample.startDate, end: sample.endDate, to: window)
                    }
                }
                let core = intervals([HKCategoryValueSleepAnalysis.asleepCore.rawValue])
                let deep = intervals([HKCategoryValueSleepAnalysis.asleepDeep.rawValue])
                let rem = intervals([HKCategoryValueSleepAnalysis.asleepREM.rawValue])
                let unspecified = intervals([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue])
                let awake = intervals([HKCategoryValueSleepAnalysis.awake.rawValue])
                let inBed = intervals([HKCategoryValueSleepAnalysis.inBed.rawValue])
                let asleep = core + deep + rem + unspecified
                guard !asleep.isEmpty else { continuation.resume(returning: .noData); return }
                let hasStages = !core.isEmpty || !deep.isEmpty || !rem.isEmpty
                let allIntervals = asleep + awake + inBed
                let bedtime = allIntervals.map(\.start).min()
                let wakeTime = allIntervals.map(\.end).max()
                let interruptionCount = awake.filter { $0.end.timeIntervalSince($0.start) >= 120 }.count
                let structure = SleepStructureAnalyzer.features(
                    SleepStructureAnalyzer.NightSegments(
                        asleep: asleep, core: core, deep: deep, rem: rem, inBed: inBed
                    )
                )
                continuation.resume(returning: .value(HealthSleepDetail(
                    date: wakeDay,
                    totalHours: HealthSleepSampleAggregator.totalHours(for: asleep),
                    coreHours: hasStages ? HealthSleepSampleAggregator.totalHours(for: core) : nil,
                    deepHours: hasStages ? HealthSleepSampleAggregator.totalHours(for: deep) : nil,
                    remHours: hasStages ? HealthSleepSampleAggregator.totalHours(for: rem) : nil,
                    awakeHours: awake.isEmpty ? nil : HealthSleepSampleAggregator.totalHours(for: awake),
                    inBedHours: inBed.isEmpty ? bedtime.flatMap { bed in wakeTime.map { $0.timeIntervalSince(bed) / 3600 } } : HealthSleepSampleAggregator.totalHours(for: inBed),
                    bedtime: bedtime, wakeTime: wakeTime,
                    interruptionCount: awake.isEmpty ? nil : interruptionCount,
                    remEpisodes: structure.remEpisodes,
                    remLatencyMinutes: structure.remLatencyMinutes,
                    deepFrontLoadPercent: structure.deepFrontLoadPercent,
                    sleepOnsetLatencyMinutes: structure.sleepOnsetLatencyMinutes
                )))
            }
            healthStore.execute(query)
        }
    }

    /// 获取指定日期的站立小时数（best-effort：UI 语义不变，错误回落 0）
    private func fetchStandTime(for date: Date) async -> Double {
        switch await fetchStandTimeStrict(for: date) {
        case .value(let value): return value
        case .noData, .waitingForUnlock, .unavailable: return 0
        }
    }

    /// 严格版站立查询（§7.1）：读取 HK 回调 error；空样本 → noData。
    private func fetchStandTimeStrict(for date: Date) async -> HoloHealthQueryOutcome<Double> {
        guard let standType = HKObjectType.categoryType(forIdentifier: .appleStandHour) else {
            return .unavailable(.recoverable(String(localized: "站立类型不可用")))
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return .noData
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )
        let dayWindow = HealthSleepSampleAggregator.Interval(start: startOfDay, end: endOfDay)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: standType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let failure: HoloHealthQueryOutcome<Double> = HoloStrictHealthQueryService.failure(from: error) {
                    continuation.resume(returning: failure)
                    return
                }
                let categorySamples = (samples as? [HKCategorySample]) ?? []
                guard !categorySamples.isEmpty else {
                    continuation.resume(returning: .noData)
                    return
                }
                let standHours = HealthStandHourAggregator.stoodHours(
                    for: categorySamples,
                    in: dayWindow
                )
                continuation.resume(returning: .value(Double(standHours)))
            }
            healthStore.execute(query)
        }
    }

    /// 获取指定日期的活动分钟（用于无 Apple Watch 时替代站立环）（best-effort：错误回落 0）
    private func fetchActiveMinutes(for date: Date) async -> Double {
        switch await fetchActiveMinutesStrict(for: date) {
        case .value(let value): return value
        case .noData, .waitingForUnlock, .unavailable: return 0
        }
    }

    /// 严格版活动分钟查询（§7.1）：读取 HK 回调 error，锁屏返回 waitingForUnlock。
    private func fetchActiveMinutesStrict(for date: Date) async -> HoloHealthQueryOutcome<Double> {
        guard let exerciseType = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) else {
            return .unavailable(.recoverable(String(localized: "活动分钟类型不可用")))
        }
        return await fetchQuantitySumStrict(quantityType: exerciseType, unit: .minute(), date: date)
    }

    // MARK: - 页面渲染数据（二期：单日小时步数 / 体征）

    /// 单日 24 小时步数桶（best-effort：无样本/错误回落 nil）。
    func fetchHourlySteps(for date: Date) async -> HourlyStepsData? {
        switch await fetchHourlyStepsRangeStrict(from: date, to: date) {
        case .value(let days): return days.first
        case .noData, .waitingForUnlock, .unavailable: return nil
        }
    }

    /// 每日体征（best-effort：字段 nil = 当日无该项样本）。需 Apple Watch 产生数据。
    func fetchVitalsRange(from start: Date, to end: Date) async -> [DailyVitals] {
        if useMockData {
            return Self.mockVitalsRange(from: start, to: end)
        }
        let calendar = Calendar.current
        var results: [DailyVitals] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while current <= endDay {
            async let resting = fetchDiscreteVitalSample(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), date: current, pick: .latest)
            async let hrv = fetchDiscreteVitalSample(.heartRateVariability, unit: HKUnit.secondUnit(with: .milli), date: current, pick: .mean)
            async let respiratory = fetchDiscreteVitalSample(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), date: current, pick: .mean)
            let (restingValue, hrvValue, respiratoryValue) = await (resting, hrv, respiratory)
            results.append(DailyVitals(
                date: current,
                restingHeartRate: restingValue,
                heartRateVariability: hrvValue,
                respiratoryRate: respiratoryValue
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    private enum VitalsKind {
        case restingHeartRate
        case heartRateVariability
        case respiratoryRate

        var quantityType: HKQuantityType? {
            switch self {
            case .restingHeartRate:
                return HKObjectType.quantityType(forIdentifier: .restingHeartRate)
            case .heartRateVariability:
                return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
            case .respiratoryRate:
                return HKObjectType.quantityType(forIdentifier: .respiratoryRate)
            }
        }
    }

    private enum VitalsAggregation {
        /// 当日最新一条（静息心率一天一两条，取最新）
        case latest
        /// 当日均值（HRV/呼吸频率夜间多条）
        case mean
    }

    /// 离散体征样本的单日聚合（best-effort：无样本回落 nil）。
    private func fetchDiscreteVitalSample(
        _ kind: VitalsKind,
        unit: HKUnit,
        date: Date,
        pick: VitalsAggregation
    ) async -> Double? {
        guard let quantityType = kind.quantityType else { return nil }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endOfDay, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                let quantities = ((samples as? [HKQuantitySample]) ?? []).map {
                    $0.quantity.doubleValue(for: unit)
                }
                guard !quantities.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                switch pick {
                case .latest:
                    continuation.resume(returning: quantities.first)
                case .mean:
                    continuation.resume(returning: quantities.reduce(0, +) / Double(quantities.count))
                }
            }
            healthStore.execute(query)
        }
    }

    /// mock：静息心率 55-60 缓升、HRV 40-52 缓降、呼吸频率 14.5-15.5（模拟器走查用）。
    nonisolated private static func mockVitalsRange(from start: Date, to end: Date) -> [DailyVitals] {
        let calendar = Calendar.current
        var results: [DailyVitals] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while current <= endDay {
            let dayOffset = calendar.dateComponents([.day], from: start, to: current).day ?? 0
            let resting = 55 + Double(dayOffset % 5) * 0.8
            let hrv = 50 - Double(dayOffset % 7) * 1.4
            let respiratory = 14.6 + Double(dayOffset % 4) * 0.25
            results.append(DailyVitals(
                date: current,
                restingHeartRate: resting,
                heartRateVariability: hrv,
                respiratoryRate: respiratory
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    // MARK: - 小时级步数与能量/距离查询（一期细粒度数据）

    /// 获取日期范围内每日 24 小时步数桶（严格协议：锁屏/权限错误显式传播）。
    /// 小时粒度聚合，供久坐节律与活动分布分析；无样本天桶值为 0。
    func fetchHourlyStepsRangeStrict(from start: Date, to end: Date) async -> HoloHealthQueryOutcome<[HourlyStepsData]> {
        if useMockData {
            let calendar = Calendar.current
            var results: [HourlyStepsData] = []
            var current = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: end)
            while current <= endDay {
                results.append(HourlyStepsData(date: current, hourly: Self.mockHourlyPattern))
                guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
            return results.isEmpty ? .noData : .value(results)
        }
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return .unavailable(.recoverable(String(localized: "步数类型不可用")))
        }
        let calendar = Calendar.current
        let rangeStart = calendar.startOfDay(for: start)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else {
            return .noData
        }
        let predicate = HKQuery.predicateForSamples(withStart: rangeStart, end: rangeEnd, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: rangeStart,
                intervalComponents: DateComponents(hour: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let failure: HoloHealthQueryOutcome<[HourlyStepsData]> = HoloStrictHealthQueryService.failure(from: error) {
                    continuation.resume(returning: failure)
                    return
                }
                guard let collection else {
                    continuation.resume(returning: .noData)
                    return
                }
                var results: [HourlyStepsData] = []
                var hasAnySample = false
                var day = rangeStart
                while day < rangeEnd {
                    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    var hourly: [Double] = []
                    collection.enumerateStatistics(from: day, to: dayEnd) { statistics, _ in
                        if let sum = statistics.sumQuantity() {
                            hasAnySample = true
                            hourly.append(sum.doubleValue(for: .count()))
                        } else {
                            hourly.append(0)
                        }
                    }
                    if hourly.count < 24 {
                        hourly = Array((hourly + Array(repeating: 0, count: 24)).prefix(24))
                    }
                    results.append(HourlyStepsData(date: day, hourly: hourly))
                    day = dayEnd
                }
                continuation.resume(returning: hasAnySample ? .value(results) : .noData)
            }
            healthStore.execute(query)
        }
    }

    /// 获取日期范围每日活动能量（千卡，严格协议）。
    /// 有 Apple Watch 时为实测；无 Watch 时 iPhone 推算，误差大——消费方应看趋势。
    func fetchEnergyRangeStrict(from start: Date, to end: Date) async -> HoloHealthQueryOutcome<[DailyHealthData]> {
        guard let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return .unavailable(.recoverable(String(localized: "活动能量类型不可用")))
        }
        if useMockData {
            return .value(Self.mockDailyRange(from: start, to: end, range: 220...560))
        }
        return await fetchQuantityDailyRangeStrict(quantityType: energyType, unit: .kilocalorie(), from: start, to: end)
    }

    /// 获取日期范围每日步行+跑步距离（公里，严格协议）。
    func fetchDistanceRangeStrict(from start: Date, to end: Date) async -> HoloHealthQueryOutcome<[DailyHealthData]> {
        guard let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) else {
            return .unavailable(.recoverable(String(localized: "步行距离类型不可用")))
        }
        if useMockData {
            return .value(Self.mockDailyRange(from: start, to: end, range: 1.5...9.0))
        }
        return await fetchQuantityDailyRangeStrict(
            quantityType: distanceType,
            unit: HKUnit.meterUnit(with: .kilo),
            from: start,
            to: end
        )
    }

    /// 通用单日累计量严格查询（§7.1）：HKStatisticsQuery cumulativeSum。
    private func fetchQuantitySumStrict(
        quantityType: HKQuantityType,
        unit: HKUnit,
        date: Date
    ) async -> HoloHealthQueryOutcome<Double> {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return .noData
        }
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endOfDay, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let failure: HoloHealthQueryOutcome<Double> = HoloStrictHealthQueryService.failure(from: error) {
                    continuation.resume(returning: failure)
                    return
                }
                guard let result else {
                    continuation.resume(returning: .noData)
                    return
                }
                continuation.resume(returning: .value(result.sumQuantity()?.doubleValue(for: unit) ?? 0))
            }
            healthStore.execute(query)
        }
    }

    /// 通用逐日累计量范围严格查询：逐天 fold，无样本天不计入。
    private func fetchQuantityDailyRangeStrict(
        quantityType: HKQuantityType,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> HoloHealthQueryOutcome<[DailyHealthData]> {
        let calendar = Calendar.current
        var daily: [HoloHealthQueryOutcome<DailyHealthData>] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while current <= endDay {
            let outcome = await fetchQuantitySumStrict(quantityType: quantityType, unit: unit, date: current)
            daily.append(outcome.map { DailyHealthData(date: current, value: $0) })
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return HoloStrictHealthQueryService.fold(daily)
    }

    /// mock：有早晚高峰与午后低谷的一天（模拟器无 HealthKit）。
    nonisolated private static let mockHourlyPattern: [Double] = [
        0, 0, 0, 0, 0, 12, 140, 820, 1310, 540, 980, 810,
        360, 70, 0, 0, 90, 180, 1450, 1720, 1090, 460, 90, 0
    ]

    private static func mockDailyRange(from start: Date, to end: Date, range: ClosedRange<Double>) -> [DailyHealthData] {
        let calendar = Calendar.current
        var results: [DailyHealthData] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while current <= endDay {
            results.append(DailyHealthData(date: current, value: Double.random(in: range)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    // MARK: - 运动会话（HKWorkout）

    /// 获取指定日期范围的每日运动会话聚合（AI 分析用）
    func fetchWorkoutsRange(from start: Date, to end: Date) async -> [DailyWorkoutData] {
        if useMockData {
            return generateMockWorkoutRange(from: start, to: end)
        }

        let calendar = Calendar.current
        var results: [DailyWorkoutData] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        while current <= endDay {
            let data = await fetchWorkouts(for: current)
            results.append(data)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    /// 获取指定日期的运动会话聚合（时长/次数/主要类型）（best-effort：错误回落 0）
    private func fetchWorkouts(for date: Date) async -> DailyWorkoutData {
        switch await fetchWorkoutsStrict(for: date) {
        case .value(let data): return data
        case .noData, .waitingForUnlock, .unavailable:
            return DailyWorkoutData(date: date, totalMinutes: 0, sessionCount: 0, topType: nil)
        }
    }

    /// 严格版运动会话查询（§7.1）：读取 HK 回调 error；无会话 → noData。
    private func fetchWorkoutsStrict(for date: Date) async -> HoloHealthQueryOutcome<DailyWorkoutData> {
        let workoutType = HKObjectType.workoutType()

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return .noData
        }

        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endOfDay, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let failure: HoloHealthQueryOutcome<DailyWorkoutData> = HoloStrictHealthQueryService.failure(from: error) {
                    continuation.resume(returning: failure)
                    return
                }
                let workouts = (samples as? [HKWorkout]) ?? []
                guard !workouts.isEmpty else {
                    continuation.resume(returning: .noData)
                    return
                }
                let totalMinutes = workouts.reduce(0.0) { $0 + $1.duration } / 60
                continuation.resume(returning: .value(DailyWorkoutData(
                    date: date,
                    totalMinutes: totalMinutes,
                    sessionCount: workouts.count,
                    topType: Self.topWorkoutTypeName(workouts)
                )))
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Agent 严格范围查询（§7.1，P0-4）

    /// 严格版每日指标范围查询：任一天锁屏 → 整体 waitingForUnlock（不得伪装 0/空）；
    /// 无样本天不计入（覆盖天数自然反映真实可读范围）。UI best-effort 方法语义不变。
    func fetchDailyRangeStrict(for type: HealthMetricType, from start: Date, to end: Date) async -> HoloHealthQueryOutcome<[DailyHealthData]> {
        if useMockData {
            let mock = generateMockRangeData(for: type, from: start, to: end)
            return mock.isEmpty ? .noData : .value(mock)
        }

        let calendar = Calendar.current
        var daily: [HoloHealthQueryOutcome<DailyHealthData>] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        while current <= endDay {
            let outcome: HoloHealthQueryOutcome<Double>
            switch type {
            case .steps: outcome = await fetchStepsStrict(for: current)
            case .sleep: outcome = await fetchSleepStrict(for: current)
            case .standHours: outcome = await fetchStandTimeStrict(for: current)
            case .activeMinutes: outcome = await fetchActiveMinutesStrict(for: current)
            }
            daily.append(outcome.map { value in DailyHealthData(date: current, value: value) })
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return HoloStrictHealthQueryService.fold(daily)
    }

    /// 严格版睡眠明细范围查询：锁屏 → waitingForUnlock；无睡眠样本天不计入。
    func fetchSleepDetailRangeStrict(from start: Date, to end: Date) async -> HoloHealthQueryOutcome<[HealthSleepDetail]> {
        if useMockData {
            let calendar = Calendar.current
            var mock: [HealthSleepDetail] = []
            var wakeDay = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: end)
            while wakeDay <= endDay {
                if let detail = Self.mockSleepDetail(forWakeDay: wakeDay) {
                    mock.append(detail)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: wakeDay) else { break }
                wakeDay = next
            }
            return mock.isEmpty ? .noData : .value(mock)
        }

        let calendar = Calendar.current
        var daily: [HoloHealthQueryOutcome<HealthSleepDetail>] = []
        var wakeDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        while wakeDay <= endDay {
            daily.append(await fetchSleepDetailStrict(forWakeDay: wakeDay))
            guard let next = calendar.date(byAdding: .day, value: 1, to: wakeDay) else { break }
            wakeDay = next
        }
        return HoloStrictHealthQueryService.fold(daily)
    }

    /// 严格版运动会话范围查询：锁屏 → waitingForUnlock；无会话天不计入。
    func fetchWorkoutsRangeStrict(from start: Date, to end: Date) async -> HoloHealthQueryOutcome<[DailyWorkoutData]> {
        if useMockData {
            let mock = generateMockWorkoutRange(from: start, to: end)
            return mock.isEmpty ? .noData : .value(mock)
        }

        let calendar = Calendar.current
        var daily: [HoloHealthQueryOutcome<DailyWorkoutData>] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        while current <= endDay {
            daily.append(await fetchWorkoutsStrict(for: current))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return HoloStrictHealthQueryService.fold(daily)
    }

    /// 取当日时长最长的运动类型中文名。
    /// nonisolated：HKWorkout 属性读取线程安全，可在 HKSampleQuery 回调线程调用，无需 MainActor。
    nonisolated private static func topWorkoutTypeName(_ workouts: [HKWorkout]) -> String? {
        guard !workouts.isEmpty else { return nil }
        var durationByType: [HKWorkoutActivityType: TimeInterval] = [:]
        for workout in workouts {
            durationByType[workout.workoutActivityType, default: 0] += workout.duration
        }
        let topKind = durationByType.max(by: { $0.value < $1.value })?.key ?? .other
        return Self.workoutActivityTypeName(topKind)
    }

    /// HKWorkoutActivityType → 中文名（覆盖常见类型，未知统一「运动」）。
    /// nonisolated：纯映射无 actor 状态依赖。
    nonisolated static func workoutActivityTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .coreTraining: return "核心训练"
        case .yoga: return "瑜伽"
        case .pilates: return "普拉提"
        case .flexibility: return "拉伸"
        case .highIntensityIntervalTraining: return "HIIT"
        case .hiking: return "徒步"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .stairClimbing: return "爬楼梯"
        case .dance: return "舞蹈"
        case .martialArts: return "武术"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .badminton: return "羽毛球"
        case .tennis: return "网球"
        case .tableTennis: return "乒乓球"
        default: return "运动"
        }
    }

    /// 生成模拟运动范围数据（模拟器无 HealthKit）
    private func generateMockWorkoutRange(from start: Date, to end: Date) -> [DailyWorkoutData] {
        let calendar = Calendar.current
        var results: [DailyWorkoutData] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let mockTypes = ["跑步", "步行", "骑行", "力量训练"]

        while current <= endDay {
            let hasWorkout = Int.random(in: 0...10) > 4
            let minutes = hasWorkout ? Double(Int.random(in: 20...75)) : 0
            let sessionCount = hasWorkout ? Int.random(in: 1...2) : 0
            let topType = hasWorkout ? mockTypes[Int.random(in: 0..<mockTypes.count)] : nil
            results.append(DailyWorkoutData(date: current, totalMinutes: minutes, sessionCount: sessionCount, topType: topType))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    // MARK: - 私有方法 - 模拟数据

    /// 加载模拟今日数据
    private func loadMockTodayData() async {
        await MainActor.run {
            self.todaySteps = Double(Int.random(in: 5000...12000))
            self.todaySleep = Double(Int.random(in: 5...9)) + Double.random(in: 0...0.9)
            self.todayStandHours = Double(Int.random(in: 8...14))
            self.todayActiveMinutes = Double(Int.random(in: 18...55))
            self.stepsAvailability = .available
            self.sleepAvailability = .available
            self.standAvailability = .available
            self.activeMinutesAvailability = .available
            self.dataSourceState = .connected
        }
    }

    /// 生成模拟周数据
    private func generateMockWeeklyData(for type: HealthMetricType, endingOn endDate: Date = Date()) -> [DailyHealthData] {
        let calendar = Calendar.current

        return (0..<7).reversed().compactMap { offset -> DailyHealthData? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDate) else {
                return nil
            }

            let value: Double
            switch type {
            case .steps:
                value = Double(Int.random(in: 5000...15000))
            case .sleep:
                value = Double(Int.random(in: 5...10)) + Double.random(in: 0...0.9)
            case .standHours:
                value = Double(Int.random(in: 6...14))
            case .activeMinutes:
                value = Double(Int.random(in: 12...60))
            }

            return DailyHealthData(date: date, value: value)
        }
    }

    /// 生成模拟日期范围数据
    private func generateMockRangeData(for type: HealthMetricType, from start: Date, to end: Date) -> [DailyHealthData] {
        let calendar = Calendar.current
        var results: [DailyHealthData] = []
        var current = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        while current <= endDay {
            let value: Double
            switch type {
            case .steps: value = Double(Int.random(in: 5000...15000))
            case .sleep: value = Double(Int.random(in: 5...10)) + Double.random(in: 0...0.9)
            case .standHours: value = Double(Int.random(in: 6...14))
            case .activeMinutes: value = Double(Int.random(in: 12...60))
            }
            results.append(DailyHealthData(date: current, value: value))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return results
    }

    private var readTypes: [HKObjectType] {
        [
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.quantityType(forIdentifier: .appleStandTime),
            HKObjectType.categoryType(forIdentifier: .appleStandHour),
            HKObjectType.quantityType(forIdentifier: .appleExerciseTime),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
            // 二期体征三项（需 Apple Watch 产生数据）
            HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKObjectType.quantityType(forIdentifier: .respiratoryRate),
            HKObjectType.workoutType()
        ].compactMap { $0 }
    }

    private var hasAnyFetchedData: Bool {
        todaySteps > 0 || todaySleep > 0 || todayStandHours > 0 || todayActiveMinutes > 0
    }

    private func updateAvailabilityAfterFetch() {
        stepsAvailability = todaySteps > 0 ? .available : .noData
        sleepAvailability = todaySleep > 0 ? .available : .noData
        activeMinutesAvailability = todayActiveMinutes > 0 ? .available : .noData

        if todayStandHours > 0 {
            standAvailability = .available
        } else if todayActiveMinutes > 0 {
            standAvailability = .unsupported
        } else {
            standAvailability = .noData
        }

        // 站立指标「已覆盖」的两种情形：有直接站立数据，或无 Watch 时由活动分钟兜底（unsupported）。
        // 兜底生效时不应再判为「部分连接」。
        let coveredStates = [
            stepsAvailability == .available,
            sleepAvailability == .available,
            standAvailability == .available || standAvailability == .unsupported
        ]
        if coveredStates.allSatisfy({ $0 }) {
            dataSourceState = .connected
            isAuthorized = true
        } else if coveredStates.contains(true) {
            dataSourceState = .partiallyConnected
            isAuthorized = true
        } else if hasRequestedPermission {
            dataSourceState = .connected
        }
    }

    var dashboardSnapshot: HealthDashboardSnapshot {
        HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(
                type: .steps,
                value: todaySteps,
                availability: stepsAvailability
            ),
            sleep: HealthMetricSnapshot(
                type: .sleep,
                value: todaySleep,
                availability: sleepAvailability
            ),
            standOrActivity: HealthDashboardSnapshot.standOrActivitySnapshot(
                standHours: todayStandHours,
                activeMinutes: todayActiveMinutes,
                standAvailability: standAvailability
            ),
            dataSourceState: dataSourceState
        )
    }
}

// MARK: - HealthError

/// 健康数据错误
enum HealthError: LocalizedError {
    case healthKitNotAvailable
    case authorizationDenied
    case dataNotAvailable

    var errorDescription: String? {
        switch self {
        case .healthKitNotAvailable:
            return String(localized: "此设备不支持 HealthKit")
        case .authorizationDenied:
            return String(localized: "未获得健康数据访问权限")
        case .dataNotAvailable:
            return String(localized: "健康数据不可用")
        }
    }
}
