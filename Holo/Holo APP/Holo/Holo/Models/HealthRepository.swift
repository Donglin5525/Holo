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

    /// 是否已请求过权限
    @Published var hasRequestedPermission: Bool = false

    /// 今日步数
    @Published var todaySteps: Double = 0

    /// 今日睡眠时长（小时）
    @Published var todaySleep: Double = 0

    /// 今日站立时长（小时）
    @Published var todayStandHours: Double = 0

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

        // 检查 HealthKit 是否可用
        if HKHealthStore.isHealthDataAvailable() {
            Task {
                await checkAuthorizationStatus()
            }
        }
    }

    // MARK: - 权限管理

    /// 检查授权状态
    func checkAuthorizationStatus() async {
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .appleStandTime)!
        ]

        var allAuthorized = true
        for type in typesToRead {
            let status = healthStore.authorizationStatus(for: type)
            if status != .sharingAuthorized {
                allAuthorized = false
                break
            }
        }

        await MainActor.run {
            self.isAuthorized = allAuthorized
        }
    }

    /// 请求 HealthKit 授权
    func requestAuthorization() {
        // 模拟数据模式直接返回成功
        if useMockData {
            self.isAuthorized = true
            self.hasRequestedPermission = true
            return
        }

        // 检查 HealthKit 是否可用
        guard HKHealthStore.isHealthDataAvailable() else {
            self.errorMessage = "HealthKit 不可用"
            return
        }

        // 需要读取的数据类型
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .appleStandTime)!
        ]

        // 调用 HealthKit 授权（异步回调，不会阻塞主线程）
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hasRequestedPermission = true
                self.isAuthorized = success
                if let error = error {
                    self.errorMessage = error.localizedDescription
                }
            }
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

        let (stepsValue, sleepValue, standValue) = await (steps, sleep, stand)

        await MainActor.run {
            self.todaySteps = stepsValue
            self.todaySleep = sleepValue
            self.todayStandHours = standValue
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
            }

            results.append(DailyHealthData(date: currentDate, value: value))

            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDate
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
                        // 统计所有睡眠状态（包括深睡、REM、浅睡等）
                        let sleepValue = sample.value
                        // 使用 intValue 比较，避免使用已废弃的枚举
                        // 2 = asleepUnspecified, 3 = asleep, 4 = asleepDeep, 5 = asleepCore, 6 = asleepREM
                        if sleepValue >= 2 && sleepValue <= 6 {
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

    /// 获取指定日期的站立时长（小时）
    private func fetchStandTime(for date: Date) async -> Double {
        guard let standType = HKObjectType.quantityType(forIdentifier: .appleStandTime) else {
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
                quantityType: standType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                // Apple Stand Time 单位是分钟，转换为小时
                let minutes = result?.sumQuantity()?.doubleValue(for: .minute()) ?? 0
                continuation.resume(returning: minutes / 60)
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
            }

            return DailyHealthData(date: date, value: value)
        }
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