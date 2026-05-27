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
            self.errorMessage = "HealthKit 不可用"
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

    // MARK: - 获取历史数据

    /// 获取 7 天历史数据
    func fetchWeeklyData(for type: HealthMetricType) async -> [DailyHealthData] {
        if useMockData {
            return generateMockWeeklyData(for: type)
        }

        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -6, to: endDate) else {
            return []
        }

        var results: [DailyHealthData] = []

        var currentDate = startDate
        while currentDate <= endDate {
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

    /// 获取指定日期的步数
    private func fetchSteps(for date: Date) async -> Double {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return 0
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let sum = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: sum)
            }
            healthStore.execute(query)
        }
    }

    /// 获取指定日期的睡眠时长（小时）
    private func fetchSleep(for date: Date) async -> Double {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return 0
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                var totalSleep: Double = 0

                if let samples = samples as? [HKCategorySample] {
                    for sample in samples {
                        // 统计实际睡眠阶段（排除 inBed=0 上床时间 和 awake=2 醒来时间）
                        // 1=asleepUnspecified(第三方设备如小米手环), 3=asleepCore, 4=asleepDeep, 5=asleepREM
                        let sleepStages: Set<Int> = [1, 3, 4, 5]
                        if sleepStages.contains(sample.value) {
                            let duration = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                            totalSleep += duration
                        }
                    }
                }

                continuation.resume(returning: totalSleep)
            }
            healthStore.execute(query)
        }
    }

    /// 获取指定日期的站立小时数
    private func fetchStandTime(for date: Date) async -> Double {
        guard let standType = HKObjectType.categoryType(forIdentifier: .appleStandHour) else {
            return 0
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: standType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let standHours = samples?
                    .compactMap { $0 as? HKCategorySample }
                    .filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }
                    .count ?? 0
                continuation.resume(returning: Double(standHours))
            }
            healthStore.execute(query)
        }
    }

    /// 获取指定日期的活动分钟（用于无 Apple Watch 时替代站立环）
    private func fetchActiveMinutes(for date: Date) async -> Double {
        guard let exerciseType = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) else {
            return 0
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: exerciseType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let minutes = result?.sumQuantity()?.doubleValue(for: .minute()) ?? 0
                continuation.resume(returning: minutes)
            }
            healthStore.execute(query)
        }
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
    private func generateMockWeeklyData(for type: HealthMetricType) -> [DailyHealthData] {
        let calendar = Calendar.current
        let today = Date()

        return (0..<7).reversed().compactMap { offset -> DailyHealthData? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
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
            HKObjectType.quantityType(forIdentifier: .appleExerciseTime)
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

        let states = [stepsAvailability, sleepAvailability, standAvailability]
        if states.allSatisfy({ $0 == .available }) {
            dataSourceState = .connected
            isAuthorized = true
        } else if states.contains(.available) {
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
            return "此设备不支持 HealthKit"
        case .authorizationDenied:
            return "未获得健康数据访问权限"
        case .dataNotAvailable:
            return "健康数据不可用"
        }
    }
}
