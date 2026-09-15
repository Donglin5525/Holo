//
//  WorkoutSessionData.swift
//  Holo
//
//  运动会话级模型（HKWorkout 会话明细）：单次运动的类型/起止/时长/距离/能量/心率，
//  以及心率区间分析器与配速格式化（纯函数，供仓库/视图/测试共用，不依赖 UI）。
//

import Foundation
import HealthKit

// MARK: - WorkoutSessionData

/// 单次运动会话。保留 HKWorkout 会话明细；日聚合 DailyWorkoutData 由 `fold` 折叠而来，
/// 全模块口径统一（界面、AI 工具、洞察共用同一份会话数据）。
struct WorkoutSessionData: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    /// HKWorkoutActivityType 原始值（图标/分析用；存 UInt 避免模型层强绑枚举）
    let activityTypeRaw: UInt
    /// 运动类型中文名（复用 HealthRepository.workoutActivityTypeName 口径）
    let typeName: String
    /// 距离（米），无距离概念的运动（力量训练等）为 nil
    let distanceMeters: Double?
    /// 能量（千卡），缺失为 nil
    let kilocalories: Double?
    /// 平均心率（bpm），Apple Watch 记录的运动通常有；缺失 = 无心率数据而非 0
    let averageHeartRate: Double?
    /// 最高心率（bpm），缺失为 nil
    let maxHeartRate: Double?
    /// 数据来源名（"Apple Watch" / "iPhone" / 第三方 App 名）
    let sourceName: String

    /// 时长（分钟）= 起止时间差
    var minutes: Double { end.timeIntervalSince(start) / 60 }

    /// 是否 Apple Watch 记录（心率/配速字段可信度的判断依据）
    var isFromAppleWatch: Bool { sourceName.localizedCaseInsensitiveContains("watch") }

    /// 公里配速（秒/公里）。距离不足 1 公里不产出，避免短距离误差放大。
    var paceSecondsPerKm: Double? {
        guard let meters = distanceMeters, meters >= 1000, end > start else { return nil }
        return end.timeIntervalSince(start) / (meters / 1000)
    }

    /// SF Symbol 图标（按活动类型映射，未覆盖类型回落跑步人形）
    var icon: String { Self.icon(forActivityTypeRaw: activityTypeRaw) }

    /// 界面显示用的本地化类型名（AI 提示词/证据摘要用 typeName 保持中文口径，两者分离）
    var localizedName: String { Self.localizedName(forActivityTypeRaw: activityTypeRaw) }

    static func localizedName(forActivityTypeRaw raw: UInt) -> String {
        switch HKWorkoutActivityType(rawValue: raw) {
        case .running: return String(localized: "跑步")
        case .walking: return String(localized: "步行")
        case .cycling: return String(localized: "骑行")
        case .swimming: return String(localized: "游泳")
        case .traditionalStrengthTraining, .functionalStrengthTraining: return String(localized: "力量训练")
        case .coreTraining: return String(localized: "核心训练")
        case .yoga: return String(localized: "瑜伽")
        case .pilates: return String(localized: "普拉提")
        case .flexibility: return String(localized: "拉伸")
        case .highIntensityIntervalTraining: return String(localized: "HIIT")
        case .hiking: return String(localized: "徒步")
        case .elliptical: return String(localized: "椭圆机")
        case .rowing: return String(localized: "划船")
        case .stairClimbing: return String(localized: "爬楼梯")
        case .dance: return String(localized: "舞蹈")
        case .martialArts: return String(localized: "武术")
        case .basketball: return String(localized: "篮球")
        case .soccer: return String(localized: "足球")
        case .badminton: return String(localized: "羽毛球")
        case .tennis: return String(localized: "网球")
        case .tableTennis: return String(localized: "乒乓球")
        default: return String(localized: "运动")
        }
    }

    static func icon(forActivityTypeRaw raw: UInt) -> String {
        switch HKWorkoutActivityType(rawValue: raw) {
        case .running: return "figure.run"
        case .walking, .hiking: return "figure.hiking"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining: return "figure.strengthtraining.traditional"
        case .yoga, .pilates, .flexibility: return "figure.yoga"
        case .highIntensityIntervalTraining: return "figure.highintensity.intervaltraining"
        case .rowing: return "figure.rower"
        case .stairs, .stairClimbing: return "figure.stairs"
        case .dance: return "figure.dance"
        case .martialArts: return "figure.boxing"
        case .basketball: return "figure.basketball"
        case .soccer: return "figure.soccer"
        case .badminton: return "figure.badminton"
        case .tennis: return "figure.tennis"
        case .tableTennis: return "figure.table.tennis"
        case .elliptical: return "figure.elliptical"
        default: return "figure.run"
        }
    }

    /// 会话列表折叠为日聚合（时长最长者为 topType，与旧 HKWorkout 聚合口径一致）
    static func fold(_ sessions: [WorkoutSessionData], on date: Date) -> DailyWorkoutData {
        guard !sessions.isEmpty else {
            return DailyWorkoutData(date: date, totalMinutes: 0, sessionCount: 0, topType: nil)
        }
        let totalMinutes = sessions.reduce(0) { $0 + $1.minutes }
        var durationByType: [String: Double] = [:]
        for session in sessions {
            durationByType[session.typeName, default: 0] += session.minutes
        }
        let topType = durationByType.max { $0.value < $1.value }?.key
        return DailyWorkoutData(
            date: date,
            totalMinutes: totalMinutes,
            sessionCount: sessions.count,
            topType: topType
        )
    }
}

// MARK: - 心率明细与区间分析

/// 单个心率样本点
struct WorkoutHeartRatePoint: Identifiable, Equatable, Sendable {
    let date: Date
    let bpm: Double
    var id: Date { date }
}

/// 一次运动的心率明细（懒加载：仅在用户点开单次运动详情时查询）
struct WorkoutHeartDetail: Equatable, Sendable {
    /// 心率样本（按时间升序）
    let points: [WorkoutHeartRatePoint]
    /// 五区间停留分钟（Z1..Z5）
    let zoneMinutes: [Double]
    /// 区间计算使用的最大心率
    let maxHeartRateUsed: Double
    /// 最大心率是否为回退估算（读不到生日时为 true，界面需标注「估算」）
    let isEstimatedMaxHeartRate: Bool
}

/// 心率五区间分析（Apple 健康口径：按最大心率百分比划分）
enum WorkoutHeartZoneAnalyzer {

    /// Z1 <60% / Z2 <70% / Z3 <80% / Z4 <90% / Z5 ≥90%
    static let zoneUpperRatios: [Double] = [0.6, 0.7, 0.8, 0.9, .infinity]
    static let zoneCount = 5

    /// 单个心率值所属区间（0...4）
    static func zoneIndex(bpm: Double, maxHeartRate: Double) -> Int {
        guard maxHeartRate > 0 else { return 0 }
        let ratio = bpm / maxHeartRate
        for (index, upper) in zoneUpperRatios.enumerated() where ratio < upper {
            return index
        }
        return zoneCount - 1
    }

    /// 各区间停留分钟：相邻样本间隔归因给前一个样本的区间；
    /// 间隔超过 `capSeconds`（默认 120 秒）按 capSeconds 计，防止记录暂停区间虚增时长。
    static func zoneMinutes(
        points: [WorkoutHeartRatePoint],
        maxHeartRate: Double,
        capSeconds: TimeInterval = 120
    ) -> [Double] {
        var minutes = Array(repeating: 0.0, count: zoneCount)
        let sorted = points.sorted { $0.date < $1.date }
        for (current, next) in zip(sorted, sorted.dropFirst()) {
            let gap = min(next.date.timeIntervalSince(current.date), capSeconds)
            guard gap > 0 else { continue }
            minutes[zoneIndex(bpm: current.bpm, maxHeartRate: maxHeartRate)] += gap / 60
        }
        return minutes
    }

    /// 估算最大心率：220 − 年龄（生日来自 HealthKit 个人资料）。
    /// 生日缺失或年龄越界（<13 / >100）时回退 190 并标记估算。
    static func estimatedMaxHeartRate(
        birthComponents: DateComponents?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (value: Double, isEstimated: Bool) {
        let fallback: (Double, Bool) = (190, true)
        guard let year = birthComponents?.year, let month = birthComponents?.month, let day = birthComponents?.day,
              let birth = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return fallback
        }
        let age = calendar.dateComponents([.year], from: birth, to: now).year ?? -1
        guard (13...100).contains(age) else { return fallback }
        return (Double(220 - age), false)
    }
}

// MARK: - 种子化随机数（模拟数据用：同一种子序列可复现）

/// SplitMix64：轻量确定性随机源，供模拟数据按日期种子生成稳定结果。
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 整数区间（含两端）
    mutating func next(_ range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.count)) + range.lowerBound
    }

    /// 整数半开区间
    mutating func next(_ range: Range<Int>) -> Int {
        Int(next() % UInt64(range.count)) + range.lowerBound
    }
}

// MARK: - 配速格式化

enum WorkoutPaceFormatter {

    /// 秒/公里 → "6'12\""；输入 nil 或非正值返回 nil（界面按无配速处理）
    static func paceText(secondsPerKm: Double?) -> String? {
        guard let seconds = secondsPerKm, seconds > 0, seconds.isFinite else { return nil }
        let total = Int(seconds.rounded())
        return "\(total / 60)'\(String(format: "%02d", total % 60))\""
    }
}
