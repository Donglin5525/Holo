//
//  HoloHealthTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — HealthKit 全指标只读工具。
//

import Foundation

enum HoloHealthMetricKind: String, Codable, CaseIterable, Hashable, Sendable {
    case steps
    case sleep
    case stand
    case activity

    /// 用户可见的中文标签。证据摘要（excerpt）必须用这个，不能用 rawValue（英文），
    /// 否则用户会在"查看数据依据"里看到 steps/sleep/stand 这种英文。
    var displayLabel: String {
        switch self {
        case .steps: return "步数"
        case .sleep: return "睡眠"
        case .stand: return "站立"
        case .activity: return "活动"
        }
    }
}

nonisolated struct HoloHealthDailyRecord: Codable, Equatable, Sendable {
    var date: Date
    var value: Double
}

/// 一晚睡眠的结构化记录。阶段字段为 nil 表示设备没有提供对应数据，
/// 此时 Agent 必须降级为时长分析，不能把时长包装成完整睡眠质量。
nonisolated struct HoloSleepRecord: Codable, Equatable, Sendable {
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
    // 睡眠结构特征：nil = 无阶段数据（需 Apple Watch 分期），不得当 0 解读。
    var remEpisodes: Int? = nil
    var remLatencyMinutes: Double? = nil
    /// 前半夜深睡占整晚深睡百分比（0-100）
    var deepFrontLoadPercent: Double? = nil
    var sleepOnsetLatencyMinutes: Double? = nil

    var hasStageData: Bool { coreHours != nil || deepHours != nil || remHours != nil }
    var sleepEfficiency: Double? {
        guard let inBedHours, inBedHours > 0 else { return nil }
        return min(1, totalHours / inBedHours)
    }
}

/// 每日活动节律记录（由小时级步数聚合推导）。nil 字段 = 该维度不可得。
nonisolated struct HoloActivityPatternRecord: Codable, Equatable, Sendable {
    var date: Date
    /// 白天窗（8-21 时）内最长连续安静小时折算分钟；0 = 白天无连续静坐
    var longestSedentaryMinutes: Double
    /// 首个/末个活跃小时（0-23）
    var activeWindowStartHour: Int?
    var activeWindowEndHour: Int?
    /// 18-23 时步数占全天比例（0-1）
    var eveningStepShare: Double?
    var peakHour: Int?
    /// 当天总步数（供占比/口径核对）
    var totalSteps: Double
}

nonisolated struct HoloHealthWorkoutRecord: Codable, Equatable, Sendable {
    var date: Date
    var totalMinutes: Double
    var sessionCount: Int
    var topType: String?
}

protocol HoloHealthDataSource: Sendable {
    func dailyRecords(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> [HoloHealthDailyRecord]

    func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord]
    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloSleepRecord]

    /// 每日活动节律（小时级步数聚合推导）。默认空实现：fake 数据源按需覆盖。
    func activityPatternRecords(timeRange: HoloAgentTimeRange?) async -> [HoloActivityPatternRecord]
    /// 每日活动能量（千卡）。默认空实现。
    func energyRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord]
    /// 每日步行+跑步距离（公里）。默认空实现。
    func distanceRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord]

    /// 严格查询（§7.1 P0-4）：生产实现必须读取 HK error，锁屏返回 waitingForUnlock，
    /// 禁止把锁屏/查询错误伪装成空数组或 0。默认实现回落 best-effort 包装（fake/旧实现兼容）。
    func dailyRecordsStrict(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]>

    func workoutRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthWorkoutRecord]>
    func sleepRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloSleepRecord]>

    func activityPatternRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloActivityPatternRecord]>
    func energyRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]>
    func distanceRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]>
}

extension HoloHealthDataSource {
    func activityPatternRecords(timeRange: HoloAgentTimeRange?) async -> [HoloActivityPatternRecord] { [] }
    func energyRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] { [] }
    func distanceRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] { [] }

    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloSleepRecord] {
        await dailyRecords(for: .sleep, timeRange: timeRange).map {
            HoloSleepRecord(date: $0.date, totalHours: $0.value, coreHours: nil, deepHours: nil,
                            remHours: nil, awakeHours: nil, inBedHours: nil, bedtime: nil,
                            wakeTime: nil, interruptionCount: nil)
        }
    }

    /// 默认严格实现：包装 best-effort 结果为 value（空数组映射为 noData）。
    /// 仅用于测试 fake 与未实现严格查询的数据源；生产 `HoloDefaultHealthDataSource` 必须覆盖。
    func dailyRecordsStrict(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]> {
        let records = await dailyRecords(for: metric, timeRange: timeRange)
        return records.isEmpty ? .noData : .value(records)
    }

    func workoutRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthWorkoutRecord]> {
        let records = await workoutRecords(timeRange: timeRange)
        return records.isEmpty ? .noData : .value(records)
    }

    func sleepRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloSleepRecord]> {
        let records = await sleepRecords(timeRange: timeRange)
        return records.isEmpty ? .noData : .value(records)
    }

    func activityPatternRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloActivityPatternRecord]> {
        let records = await activityPatternRecords(timeRange: timeRange)
        return records.isEmpty ? .noData : .value(records)
    }

    func energyRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]> {
        let records = await energyRecords(timeRange: timeRange)
        return records.isEmpty ? .noData : .value(records)
    }

    func distanceRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]> {
        let records = await distanceRecords(timeRange: timeRange)
        return records.isEmpty ? .noData : .value(records)
    }
}

struct HoloHealthTool: HoloDataTool {

    /// 数据身份证（随目录下发给模型）：睡眠阶段类字段的统一口径说明。
    private static let sleepStageCaveat = "需 Apple Watch（或兼容设备）写入睡眠分期，缺失=设备无阶段数据而非 0；单晚分期精度有限，结论应基于 7 天以上趋势，与自己对比"

    static let dynamicCatalog = HoloDataCatalog(datasets:
        HoloHealthMetricKind.allCases.map { kind in
            let config: (name: String, unit: String, description: String) = switch kind {
            case .steps: ("health.steps", "步", "每日步数")
            case .sleep: ("health.sleep", "小时", "每日睡眠时长")
            case .stand: ("health.stand", "小时", "每日站立小时")
            case .activity: ("health.activity", "分钟", "每日活动分钟")
            }
            var fields = [
                HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "记录日期"),
                HoloDataField(name: "value", type: .number, unit: config.unit, filterable: true, groupable: false, aggregatable: true, description: config.description)
            ]
            if kind == .sleep {
                fields += [
                    HoloDataField(name: "deepHours", type: .number, unit: "小时", filterable: true, groupable: false, aggregatable: true, description: "深睡时长。\(sleepStageCaveat)", label: "深睡"),
                    HoloDataField(name: "coreHours", type: .number, unit: "小时", filterable: true, groupable: false, aggregatable: true, description: "核心睡眠时长。\(sleepStageCaveat)", label: "核心睡眠"),
                    HoloDataField(name: "remHours", type: .number, unit: "小时", filterable: true, groupable: false, aggregatable: true, description: "REM 睡眠时长。\(sleepStageCaveat)", label: "REM 睡眠"),
                    HoloDataField(name: "awakeHours", type: .number, unit: "小时", filterable: true, groupable: false, aggregatable: true, description: "夜间清醒时长。\(sleepStageCaveat)", label: "夜间清醒"),
                    HoloDataField(name: "inBedHours", type: .number, unit: "小时", filterable: true, groupable: false, aggregatable: true, description: "在床时长", label: "在床时长"),
                    HoloDataField(name: "efficiency", type: .number, unit: "%", filterable: true, groupable: false, aggregatable: true, description: "睡眠效率（睡着时长/在床时长）。看长期趋势，单晚波动正常", label: "睡眠效率"),
                    HoloDataField(name: "bedtimeMinutes", type: .number, unit: "分钟", filterable: true, groupable: false, aggregatable: true, description: "入睡时间（距午夜分钟，跨午夜为负或超 1440 需按环形时间解读）", label: "入睡时间"),
                    HoloDataField(name: "wakeMinutes", type: .number, unit: "分钟", filterable: true, groupable: false, aggregatable: true, description: "起床时间（距午夜分钟）", label: "起床时间"),
                    HoloDataField(name: "interruptions", type: .number, unit: "次", filterable: true, groupable: false, aggregatable: true, description: "两分钟以上清醒次数。\(sleepStageCaveat)", label: "夜间中断")
                ]
                // 一期睡眠结构特征
                fields += [
                    HoloDataField(name: "remEpisodes", type: .number, unit: "段", filterable: true, groupable: false, aggregatable: true, description: "一晚 REM 出现段数（已合并重叠段、过滤 5 分钟以下噪声段）。健康成人典型 4-6 段；\(sleepStageCaveat)", label: "REM 段数"),
                    HoloDataField(name: "remLatencyMinutes", type: .number, unit: "分钟", filterable: true, groupable: false, aggregatable: true, description: "入睡后到第一段 REM 的分钟数（首段 REM 潜伏期）。偏短可能与睡眠负债相关，解读看多晚趋势。\(sleepStageCaveat)", label: "REM 潜伏期"),
                    HoloDataField(name: "deepFrontLoadPercent", type: .number, unit: "%", filterable: true, groupable: false, aggregatable: true, description: "前半夜深睡占整晚深睡百分比（0-100）。深睡正常以前半夜为主，长期偏低值得观察。\(sleepStageCaveat)", label: "深睡前半夜占比"),
                    HoloDataField(name: "onsetLatencyMinutes", type: .number, unit: "分钟", filterable: true, groupable: false, aggregatable: true, description: "入睡潜伏期（上床到首次入睡）。需设备记录在床段，缺失时不产出", label: "入睡潜伏期")
                ]
            }
            return HoloDataSetSchema(
                name: config.name,
                domain: "health",
                description: config.description,
                timeField: "date",
                fields: fields,
                sensitivity: .sensitive,
                maximumRangeDays: 366,
                coverageSemantics: .dailyObservations
            )
        }
        + [
            HoloDataSetSchema(
                name: "health.activity_pattern",
                domain: "health",
                description: "每日活动节律（由小时级步数聚合推导）：最长连续静坐、活动时间窗、晚间步数占比。口径：小时粒度（非分钟级行为记录）；静坐判定=白天 8-21 时整小时步数低于 100；活跃判定=整小时步数不低于 200。iPhone 即可产生，无需 Apple Watch",
                label: "活动节律",
                timeField: "date",
                fields: [
                    HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "记录日期"),
                    HoloDataField(name: "longestSedentaryMinutes", type: .number, unit: "分钟", filterable: true, groupable: false, aggregatable: true, description: "白天窗内最长连续静坐折算分钟。0=白天无连续静坐小时；久坐观察建议以多天平均口径，单日波动正常", label: "最长连续静坐"),
                    HoloDataField(name: "activeWindowStartHour", type: .number, unit: "时", filterable: true, groupable: false, aggregatable: true, description: "首个活跃小时（0-23）。缺行=该天无活跃小时", label: "活动窗开始"),
                    HoloDataField(name: "activeWindowEndHour", type: .number, unit: "时", filterable: true, groupable: false, aggregatable: true, description: "末个活跃小时（0-23）", label: "活动窗结束"),
                    HoloDataField(name: "eveningStepShare", type: .number, unit: "比例", filterable: true, groupable: false, aggregatable: true, description: "18-23 时步数占全天比例（0-1）。晚间占比高且入睡困难时可作为讨论线索", label: "晚间步数占比"),
                    HoloDataField(name: "peakHour", type: .number, unit: "时", filterable: true, groupable: false, aggregatable: true, description: "步数最多的小时（0-23），用于判断早型/晚型活动", label: "最活跃小时"),
                    HoloDataField(name: "totalSteps", type: .number, unit: "步", filterable: true, groupable: false, aggregatable: true, description: "当天总步数（占比分母，供口径核对）", label: "当日总步数")
                ],
                sensitivity: .sensitive,
                maximumRangeDays: 366,
                coverageSemantics: .dailyObservations
            ),
            HoloDataSetSchema(
                name: "health.energy",
                domain: "health",
                description: "每日活动能量消耗。口径：有 Apple Watch 时为实测，无 Watch 时 iPhone 按步数与身体数据推算、误差较大——只看自身趋势与对比，不与他人横向比较，不作为饮食控制的精确依据",
                label: "活动能量",
                timeField: "date",
                fields: [
                    HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "记录日期"),
                    HoloDataField(name: "value", type: .number, unit: "千卡", filterable: true, groupable: false, aggregatable: true, description: "当日活动能量（估算口径，看趋势）", label: "活动能量")
                ],
                sensitivity: .sensitive,
                maximumRangeDays: 366,
                coverageSemantics: .dailyObservations
            ),
            HoloDataSetSchema(
                name: "health.distance",
                domain: "health",
                description: "每日步行+跑步距离",
                label: "步行距离",
                timeField: "date",
                fields: [
                    HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "记录日期"),
                    HoloDataField(name: "value", type: .number, unit: "公里", filterable: true, groupable: false, aggregatable: true, description: "当日步行+跑步距离", label: "步行距离")
                ],
                sensitivity: .sensitive,
                maximumRangeDays: 366,
                coverageSemantics: .dailyObservations
            )
        ]
    )

    let descriptor = HoloToolDescriptor(
        name: "health",
        description: "健康数据分析（综合状态 / 步数 / 睡眠 / 站立 / 活动分钟 / 运动会话 / 活动节律 / 活动能量 / 步行距离）",
        supportedQueries: [
            "health_overview",
            "steps_summary",
            "sleep_summary",
            "stand_summary",
            "activity_summary",
            "workout_summary",
            "dynamic_query"
        ],
        supportedTimeRanges: ["recent", "7d", "14d", "30d"],
        outputMetrics: [
            "health.steps.average",
            "health.steps.goal_met_days",
            "health.steps.daily",
            "health.sleep.average_hours",
            "health.sleep.goal_met_days",
            "health.sleep.low_days",
            "health.sleep.recorded_nights",
            "health.sleep.duration_variation_minutes",
            "health.sleep.deep_hours",
            "health.sleep.core_hours",
            "health.sleep.rem_hours",
            "health.sleep.awake_hours",
            "health.sleep.in_bed_hours",
            "health.sleep.efficiency",
            "health.sleep.average_bedtime_minutes",
            "health.sleep.average_wake_minutes",
            "health.sleep.bedtime_variation_minutes",
            "health.sleep.wake_variation_minutes",
            "health.sleep.interruptions",
            "health.sleep.hours",
            "health.sleep.rem_episodes",
            "health.sleep.rem_latency_minutes",
            "health.sleep.deep_front_load",
            "health.sleep.onset_latency_minutes",
            "health.stand.average_hours",
            "health.stand.goal_met_days",
            "health.stand.hours",
            "health.activity.average_minutes",
            "health.activity.goal_met_days",
            "health.activity.minutes",
            "health.workout.total_minutes",
            "health.workout.session_count",
            "health.workout.active_days",
            "health.workout.daily_minutes"
        ],
        sensitivityPolicy: "sensitive",
        dynamicCatalog: Self.dynamicCatalog
    )

    private let dataSource: HoloHealthDataSource

    init(dataSource: HoloHealthDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        if request.query == "dynamic_query" {
            guard let plan = request.dynamicPlan else { return .invalid(reason: "dynamic_query 缺少 dynamicPlan") }
            do {
                try HoloDynamicQueryValidator.validate(plan, catalog: Self.dynamicCatalog)
                guard plan.source.hasPrefix("health.") else { return .invalid(reason: "健康工具不能访问 \(plan.source)") }
                return .valid
            } catch { return .invalid(reason: error.localizedDescription) }
        }
        return descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的健康查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        if request.query == "dynamic_query", let plan = request.dynamicPlan {
            return await dynamicResult(request, plan: plan)
        }
        let historicalRange = HoloAgentHistoricalTimePolicy.resolve(request.timeRange)
        if historicalRange.isEntirelyFuture {
            return empty(
                request,
                warning: HoloToolWarning(
                    code: "FUTURE_RANGE_NOT_HISTORICAL",
                    message: "所选范围尚未发生，没有可分析的健康事实"
                )
            )
        }
        var scopedRequest = request
        scopedRequest.timeRange = historicalRange.effectiveRange
        let baselineRange = HoloAgentHistoricalTimePolicy.resolve(request.baseline)
        scopedRequest.baseline = baselineRange.isEntirelyFuture ? nil : baselineRange.effectiveRange
        let result: HoloDataToolResult
        switch scopedRequest.query {
        case "health_overview":
            result = await overview(scopedRequest)
        case "steps_summary":
            result = await dailySummary(scopedRequest, metric: .steps)
        case "sleep_summary":
            result = await sleepSummary(scopedRequest)
        case "stand_summary":
            result = await dailySummary(scopedRequest, metric: .stand)
        case "activity_summary":
            result = await dailySummary(scopedRequest, metric: .activity)
        case "workout_summary":
            result = await workoutSummary(scopedRequest)
        default:
            result = error(scopedRequest, reason: "不支持的健康查询：\(scopedRequest.query)")
        }
        // P3：固定指标统一挂类型化语义（动态链路 P1 已覆盖，不走这里）
        return HoloMetricSemanticFactory.attachFixedToolSemantics(to: result)
    }
}

// 行构造器与口径助手：跨域取数源（云端快照）与本地动态查询共用，
// 需模块内可见，故不用 private extension。
extension HoloHealthTool {

    func dynamicResult(_ request: HoloToolRequest, plan: HoloDynamicQueryPlan) async -> HoloDataToolResult {
        guard Self.metricKind(for: plan.source) != nil
            || ["health.activity_pattern", "health.energy", "health.distance"].contains(plan.source)
        else { return error(request, reason: "未注册健康数据集：\(plan.source)") }
        let resolvedRange = HoloAgentHistoricalTimePolicy.resolve(plan.timeRange ?? request.timeRange)
        if resolvedRange.isEntirelyFuture {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [
                    HoloToolWarning(
                        code: "FUTURE_RANGE_NOT_HISTORICAL",
                        message: "所选范围尚未发生，没有可分析的健康事实"
                    )
                ],
                error: nil,
                sensitivity: .sensitive
            )
        }
        let currentRange = resolvedRange.effectiveRange
        let requestedBaseline = plan.baseline
            ?? request.baseline
            ?? HoloDynamicQueryRangeResolver.baselineIfNeeded(for: plan, currentRange: currentRange)
        let resolvedBaseline = HoloAgentHistoricalTimePolicy.resolve(requestedBaseline)
        let baselineRange = resolvedBaseline.isEntirelyFuture ? nil : resolvedBaseline.effectiveRange
        // §7.1：主查询走严格接口，锁屏/权限错误显式传播
        let currentRowsOutcome: HoloHealthQueryOutcome<[HoloQueryRow]>
        let baselineRowsOutcome: HoloHealthQueryOutcome<[HoloQueryRow]>
        switch plan.source {
        case "health.activity_pattern":
            currentRowsOutcome = await dataSource.activityPatternRecordsStrict(timeRange: currentRange)
                .map { $0.map(Self.activityPatternQueryRow) }
            baselineRowsOutcome = await dataSource.activityPatternRecordsStrict(timeRange: baselineRange)
                .map { $0.map(Self.activityPatternQueryRow) }
        case "health.energy":
            currentRowsOutcome = await dataSource.energyRecordsStrict(timeRange: currentRange)
                .map { $0.filter { $0.value > 0 }.map { Self.scalarDailyQueryRow($0, source: "energy", label: "活动能量") } }
            baselineRowsOutcome = await dataSource.energyRecordsStrict(timeRange: baselineRange)
                .map { $0.filter { $0.value > 0 }.map { Self.scalarDailyQueryRow($0, source: "energy", label: "活动能量") } }
        case "health.distance":
            currentRowsOutcome = await dataSource.distanceRecordsStrict(timeRange: currentRange)
                .map { $0.filter { $0.value > 0 }.map { Self.scalarDailyQueryRow($0, source: "distance", label: "步行距离") } }
            baselineRowsOutcome = await dataSource.distanceRecordsStrict(timeRange: baselineRange)
                .map { $0.filter { $0.value > 0 }.map { Self.scalarDailyQueryRow($0, source: "distance", label: "步行距离") } }
        default:
            let kind = Self.metricKind(for: plan.source)!
            if kind == .sleep {
                currentRowsOutcome = await dataSource.sleepRecordsStrict(timeRange: currentRange)
                    .map { $0.filter { $0.totalHours > 0 }.map(Self.sleepQueryRow) }
                baselineRowsOutcome = await dataSource.sleepRecordsStrict(timeRange: baselineRange)
                    .map { $0.filter { $0.totalHours > 0 }.map(Self.sleepQueryRow) }
            } else {
                currentRowsOutcome = await dataSource.dailyRecordsStrict(for: kind, timeRange: currentRange)
                    .map { $0.filter { $0.value > 0 }.map { Self.queryRow($0, kind: kind) } }
                baselineRowsOutcome = await dataSource.dailyRecordsStrict(for: kind, timeRange: baselineRange)
                    .map { $0.filter { $0.value > 0 }.map { Self.queryRow($0, kind: kind) } }
            }
        }
        let currentRows: [HoloQueryRow]
        switch currentRowsOutcome {
        case .value(let rows):
            currentRows = rows
        case .noData:
            currentRows = []
        case .waitingForUnlock:
            return deviceLocked(request)
        case .unavailable(let error):
            return unavailableResult(request, error: error)
        }
        // 基线缺失/不可读降级为空基线，不阻塞主查询
        let baselineRows: [HoloQueryRow]
        switch baselineRowsOutcome {
        case .value(let rows):
            baselineRows = rows
        case .noData, .waitingForUnlock, .unavailable:
            baselineRows = []
        }
        var scopedPlan = plan
        scopedPlan.timeRange = currentRange
        scopedPlan.baseline = baselineRange
        do {
            let output = try HoloDynamicQueryEngine.execute(
                plan: scopedPlan,
                catalog: Self.dynamicCatalog,
                currentRows: currentRows,
                baselineRows: baselineRows
            )
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: output.metrics.isEmpty ? .empty : .success,
                coverage: output.coverage,
                metrics: output.metrics,
                events: output.events,
                warnings: [],
                error: nil,
                sensitivity: .sensitive
            )
        } catch let caughtError {
            return error(request, reason: caughtError.localizedDescription)
        }
    }

    static func metricKind(for source: String) -> HoloHealthMetricKind? {
        switch source {
        case "health.steps": .steps
        case "health.sleep": .sleep
        case "health.stand": .stand
        case "health.activity": .activity
        default: nil
        }
    }

    static func queryRow(_ record: HoloHealthDailyRecord, kind: HoloHealthMetricKind) -> HoloQueryRow {
        HoloQueryRow(
            id: "\(kind.rawValue)-\(idFormatter.string(from: record.date))",
            occurredAt: record.date,
            fields: ["date": .date(record.date), "value": .number(record.value)],
            excerpt: "\(displayFormatter.string(from: record.date)) \(kind.displayLabel) \(record.value)"
        )
    }

    static func sleepQueryRow(_ record: HoloSleepRecord) -> HoloQueryRow {
        var fields: [String: HoloQueryValue] = ["date": .date(record.date), "value": .number(record.totalHours)]
        if let value = record.deepHours { fields["deepHours"] = .number(value) }
        if let value = record.coreHours { fields["coreHours"] = .number(value) }
        if let value = record.remHours { fields["remHours"] = .number(value) }
        if let value = record.awakeHours { fields["awakeHours"] = .number(value) }
        if let value = record.inBedHours { fields["inBedHours"] = .number(value) }
        if let value = record.sleepEfficiency { fields["efficiency"] = .number(value * 100) }
        if let value = record.bedtime { fields["bedtimeMinutes"] = .number(minutesSinceMidnight(value)) }
        if let value = record.wakeTime { fields["wakeMinutes"] = .number(minutesSinceMidnight(value)) }
        if let value = record.interruptionCount { fields["interruptions"] = .number(Double(value)) }
        if let value = record.remEpisodes { fields["remEpisodes"] = .number(Double(value)) }
        if let value = record.remLatencyMinutes { fields["remLatencyMinutes"] = .number(value) }
        if let value = record.deepFrontLoadPercent { fields["deepFrontLoadPercent"] = .number(value) }
        if let value = record.sleepOnsetLatencyMinutes { fields["onsetLatencyMinutes"] = .number(value) }
        return HoloQueryRow(id: "sleep-\(idFormatter.string(from: record.date))", occurredAt: record.date,
                            fields: fields, excerpt: sleepEvent(record).excerpt)
    }

    static func activityPatternQueryRow(_ record: HoloActivityPatternRecord) -> HoloQueryRow {
        var fields: [String: HoloQueryValue] = [
            "date": .date(record.date),
            "longestSedentaryMinutes": .number(record.longestSedentaryMinutes),
            "totalSteps": .number(record.totalSteps)
        ]
        if let hour = record.activeWindowStartHour { fields["activeWindowStartHour"] = .number(Double(hour)) }
        if let hour = record.activeWindowEndHour { fields["activeWindowEndHour"] = .number(Double(hour)) }
        if let share = record.eveningStepShare { fields["eveningStepShare"] = .number(share) }
        if let peak = record.peakHour { fields["peakHour"] = .number(Double(peak)) }

        var excerpt = "\(displayFormatter.string(from: record.date)) 最长连续静坐 \(Int(record.longestSedentaryMinutes)) 分钟"
        if let start = record.activeWindowStartHour, let end = record.activeWindowEndHour {
            excerpt += " · 活动窗 \(start)-\(end) 时"
        }
        if let peak = record.peakHour {
            excerpt += " · 最活跃 \(peak) 时"
        }
        return HoloQueryRow(
            id: "activity-pattern-\(idFormatter.string(from: record.date))",
            occurredAt: record.date,
            fields: fields,
            excerpt: excerpt
        )
    }

    static func scalarDailyQueryRow(_ record: HoloHealthDailyRecord, source: String, label: String) -> HoloQueryRow {
        HoloQueryRow(
            id: "\(source)-\(idFormatter.string(from: record.date))",
            occurredAt: record.date,
            fields: ["date": .date(record.date), "value": .number(record.value)],
            excerpt: "\(displayFormatter.string(from: record.date)) \(label) \(String(format: "%.1f", record.value))"
        )
    }

    func dailySummary(
        _ request: HoloToolRequest,
        metric: HoloHealthMetricKind
    ) async -> HoloDataToolResult {
        // §7.1：走严格查询，锁屏/权限/暂时错误显式传播，不得伪装空数据
        let records: [HoloHealthDailyRecord]
        switch await dataSource.dailyRecordsStrict(for: metric, timeRange: request.timeRange) {
        case .value(let value):
            records = value
        case .noData:
            return empty(request, warning: warning(for: metric))
        case .waitingForUnlock:
            return deviceLocked(request)
        case .unavailable(let error):
            return unavailableResult(request, error: error)
        }
        let filtered = records
            .filter { $0.value > 0 }
            .sorted { $0.date < $1.date }

        guard !filtered.isEmpty else {
            return empty(request, warning: warning(for: metric))
        }

        let summaryMetrics = metrics(for: metric, records: filtered)
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: coverage(filtered.map(\.date), timeRange: request.timeRange),
            metrics: summaryMetrics,
            events: summaryEvidenceEvents(summaryMetrics, metric: metric, records: filtered)
                + filtered.map { event(for: metric, record: $0) },
            warnings: [],
            error: nil,
            sensitivity: .sensitive
        )
    }

    func sleepSummary(_ request: HoloToolRequest) async -> HoloDataToolResult {
        // §7.1：走严格查询，锁屏显式传播
        let allRecords: [HoloSleepRecord]
        switch await dataSource.sleepRecordsStrict(timeRange: request.timeRange) {
        case .value(let value):
            allRecords = value
        case .noData:
            return empty(request, warning: warning(for: .sleep))
        case .waitingForUnlock:
            return deviceLocked(request)
        case .unavailable(let error):
            return unavailableResult(request, error: error)
        }
        let records = allRecords
            .filter { $0.totalHours > 0 }
            .sorted { $0.date < $1.date }
        guard !records.isEmpty else { return empty(request, warning: warning(for: .sleep)) }

        let baselineRange = request.baseline ?? Self.previousRange(for: request.timeRange)
        // 基线缺失/不可读降级为空基线，不阻塞主查询（主查询成功即说明当前可读）
        let baseline: [HoloSleepRecord]
        switch await dataSource.sleepRecordsStrict(timeRange: baselineRange) {
        case .value(let value):
            baseline = value.filter { $0.totalHours > 0 }
        case .noData, .waitingForUnlock, .unavailable:
            baseline = []
        }
        let values = records.map(\.totalHours)
        let average = values.reduce(0, +) / Double(values.count)
        let baselineAverage = baseline.isEmpty ? nil : baseline.map(\.totalHours).reduce(0, +) / Double(baseline.count)
        let bedtimeMinutes = records.compactMap { $0.bedtime.map(Self.minutesSinceMidnight) }
        let wakeMinutes = records.compactMap { $0.wakeTime.map(Self.minutesSinceMidnight) }

        var metrics = [
            metric("health.sleep.average_hours", average, unit: "小时", baseline: baselineAverage),
            metric("health.sleep.recorded_nights", Double(records.count), unit: "晚"),
            metric("health.sleep.goal_met_days", Double(records.filter { $0.totalHours >= 8 }.count), unit: "晚"),
            metric("health.sleep.low_days", Double(records.filter { $0.totalHours < 6 }.count), unit: "晚"),
            metric("health.sleep.duration_variation_minutes", Self.standardDeviation(values) * 60, unit: "分钟")
        ]
        Self.appendAverage(\.deepHours, key: "health.sleep.deep_hours", unit: "小时", records: records, to: &metrics)
        Self.appendAverage(\.coreHours, key: "health.sleep.core_hours", unit: "小时", records: records, to: &metrics)
        Self.appendAverage(\.remHours, key: "health.sleep.rem_hours", unit: "小时", records: records, to: &metrics)
        Self.appendAverage(\.awakeHours, key: "health.sleep.awake_hours", unit: "小时", records: records, to: &metrics)
        Self.appendAverage(\.inBedHours, key: "health.sleep.in_bed_hours", unit: "小时", records: records, to: &metrics)
        Self.appendAverage(\.sleepEfficiency, key: "health.sleep.efficiency", unit: "%", multiplier: 100, records: records, to: &metrics)
        // 一期睡眠结构特征（仅有阶段数据的晚次产出；平均口径与阶段字段一致）
        let remEpisodesValues = records.compactMap(\.remEpisodes).map(Double.init)
        if !remEpisodesValues.isEmpty {
            metrics.append(metric("health.sleep.rem_episodes", remEpisodesValues.reduce(0, +) / Double(remEpisodesValues.count), unit: "段"))
        }
        Self.appendAverage(\.remLatencyMinutes, key: "health.sleep.rem_latency_minutes", unit: "分钟", records: records, to: &metrics)
        Self.appendAverage(\.deepFrontLoadPercent, key: "health.sleep.deep_front_load", unit: "%", records: records, to: &metrics)
        Self.appendAverage(\.sleepOnsetLatencyMinutes, key: "health.sleep.onset_latency_minutes", unit: "分钟", records: records, to: &metrics)
        let interruptions = records.compactMap(\.interruptionCount).map(Double.init)
        if !interruptions.isEmpty {
            metrics.append(metric("health.sleep.interruptions", interruptions.reduce(0, +) / Double(interruptions.count), unit: "次"))
        }
        if !bedtimeMinutes.isEmpty {
            metrics.append(metric("health.sleep.average_bedtime_minutes", Self.circularMean(bedtimeMinutes), unit: "分钟"))
            metrics.append(metric("health.sleep.bedtime_variation_minutes", Self.circularStandardDeviation(bedtimeMinutes), unit: "分钟"))
        }
        if !wakeMinutes.isEmpty {
            metrics.append(metric("health.sleep.average_wake_minutes", Self.circularMean(wakeMinutes), unit: "分钟"))
            metrics.append(metric("health.sleep.wake_variation_minutes", Self.circularStandardDeviation(wakeMinutes), unit: "分钟"))
        }

        let stageNights = records.filter(\.hasStageData).count
        let modeText = stageNights > 0
            ? "其中 \(stageNights)/\(records.count) 晚有睡眠阶段，可结合时长、阶段、效率和作息稳定性评估"
            : "设备未提供睡眠阶段；当前只能评估睡眠时长，不能完整判断睡眠质量"
        let summaryEvents = summaryEvidenceEvents(metrics, label: "睡眠汇总", occurredAt: records.last?.date)
        let capabilityEvent = HoloEvidenceEvent(
            id: "summary-health.sleep.capability", occurredAt: records.last?.date,
            metricKey: "health.sleep.capability", metricValue: Double(stageNights), excerpt: modeText
        )
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: stageNights == records.count ? .success : .partial,
            coverage: coverage(records.map(\.date), timeRange: request.timeRange), metrics: metrics,
            events: summaryEvents + [capabilityEvent] + records.map(Self.sleepEvent),
            warnings: stageNights == 0 ? [HoloToolWarning(code: "SLEEP_DURATION_ONLY", message: modeText)] : [],
            error: nil, sensitivity: .sensitive
        )
    }

    func workoutSummary(_ request: HoloToolRequest) async -> HoloDataToolResult {
        // §7.1：走严格查询
        let allRecords: [HoloHealthWorkoutRecord]
        switch await dataSource.workoutRecordsStrict(timeRange: request.timeRange) {
        case .value(let value):
            allRecords = value
        case .noData:
            return empty(
                request,
                warning: HoloToolWarning(code: "NO_WORKOUT_DATA", message: "没有可用的运动会话数据")
            )
        case .waitingForUnlock:
            return deviceLocked(request)
        case .unavailable(let error):
            return unavailableResult(request, error: error)
        }
        let records = allRecords
            .filter { $0.totalMinutes > 0 || $0.sessionCount > 0 }
            .sorted { $0.date < $1.date }

        guard !records.isEmpty else {
            return empty(
                request,
                warning: HoloToolWarning(code: "NO_WORKOUT_DATA", message: "没有可用的运动会话数据")
            )
        }

        let totalMinutes = records.reduce(0) { $0 + $1.totalMinutes }
        let sessionCount = records.reduce(0) { $0 + $1.sessionCount }
        let summaryMetrics = [
            metric("health.workout.total_minutes", totalMinutes, unit: "分钟"),
            metric("health.workout.session_count", Double(sessionCount), unit: "次"),
            metric("health.workout.active_days", Double(records.count), unit: "天")
        ]
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: coverage(records.map(\.date), timeRange: request.timeRange),
            metrics: summaryMetrics,
            events: summaryEvidenceEvents(summaryMetrics, label: "运动汇总") + records.map(workoutEvent),
            warnings: [],
            error: nil,
            sensitivity: .sensitive
        )
    }

    func overview(_ request: HoloToolRequest) async -> HoloDataToolResult {
        async let steps = dailySummary(request, metric: .steps)
        async let sleep = sleepSummary(request)
        async let stand = dailySummary(request, metric: .stand)
        async let activity = dailySummary(request, metric: .activity)
        async let workout = workoutSummary(request)

        let results = await [steps, sleep, stand, activity, workout]
        let available = results.filter { $0.status == .success || $0.status == .partial }
        guard !available.isEmpty else {
            // §7.1：全部子查询都因锁屏失败 → 整体 DEVICE_LOCKED，不得伪装「无健康数据」
            if results.allSatisfy({ $0.error?.code == HoloToolErrorCode.deviceLocked }) {
                return deviceLocked(request)
            }
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: results.flatMap(\.warnings),
                error: nil,
                sensitivity: .sensitive
            )
        }

        let events = available.flatMap(\.events)
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: available.count == results.count ? .success : .partial,
            coverage: coverage(events.compactMap(\.occurredAt), timeRange: request.timeRange),
            metrics: available.flatMap(\.metrics),
            events: events,
            warnings: results.flatMap(\.warnings),
            error: nil,
            sensitivity: .sensitive
        )
    }

    func metrics(
        for metricKind: HoloHealthMetricKind,
        records: [HoloHealthDailyRecord]
    ) -> [HoloMetric] {
        let average = records.reduce(0) { $0 + $1.value } / Double(records.count)
        switch metricKind {
        case .steps:
            return [
                metric("health.steps.average", average, unit: "步"),
                metric("health.steps.goal_met_days", Double(records.filter { $0.value >= 10_000 }.count), unit: "天")
            ]
        case .sleep:
            return [
                metric("health.sleep.average_hours", average, unit: "小时"),
                metric("health.sleep.goal_met_days", Double(records.filter { $0.value >= 8 }.count), unit: "天"),
                metric("health.sleep.low_days", Double(records.filter { $0.value < 6 }.count), unit: "天")
            ]
        case .stand:
            return [
                metric("health.stand.average_hours", average, unit: "小时"),
                metric("health.stand.goal_met_days", Double(records.filter { $0.value >= 12 }.count), unit: "天")
            ]
        case .activity:
            return [
                metric("health.activity.average_minutes", average, unit: "分钟"),
                metric("health.activity.goal_met_days", Double(records.filter { $0.value >= 30 }.count), unit: "天")
            ]
        }
    }

    func summaryEvidenceEvents(
        _ metrics: [HoloMetric],
        metric: HoloHealthMetricKind,
        records: [HoloHealthDailyRecord]
    ) -> [HoloEvidenceEvent] {
        let label: String = switch metric {
        case .steps: "步数汇总"
        case .sleep: "睡眠汇总"
        case .stand: "站立汇总"
        case .activity: "活动汇总"
        }
        return summaryEvidenceEvents(metrics, label: label, occurredAt: records.last?.date)
    }

    func summaryEvidenceEvents(
        _ metrics: [HoloMetric],
        label: String,
        occurredAt: Date? = nil
    ) -> [HoloEvidenceEvent] {
        metrics.map { metric in
            let excerpt = HoloMetricSemanticCatalog.sentence(
                metricKey: metric.metricKey,
                value: metric.value,
                unit: metric.unit,
                comparison: metric.comparison
            ) ?? "\(label)暂无可展示结果"
            return HoloEvidenceEvent(
                id: "summary-\(metric.metricKey)",
                occurredAt: occurredAt,
                metricKey: metric.metricKey,
                metricValue: metric.value,
                excerpt: excerpt
            )
        }
    }

    func event(
        for metricKind: HoloHealthMetricKind,
        record: HoloHealthDailyRecord
    ) -> HoloEvidenceEvent {
        let config: (key: String, label: String, unit: String, digits: Int) = switch metricKind {
        case .steps: ("health.steps.daily", "步数", "步", 0)
        case .sleep: ("health.sleep.hours", "睡眠", "小时", 1)
        case .stand: ("health.stand.hours", "站立", "小时", 1)
        case .activity: ("health.activity.minutes", "活动", "分钟", 0)
        }
        let valueText = config.digits == 0
            ? String(format: "%.0f", record.value)
            : String(format: "%.1f", record.value)
        return HoloEvidenceEvent(
            id: "\(metricKind.rawValue)-\(Self.idFormatter.string(from: record.date))",
            occurredAt: record.date,
            metricKey: config.key,
            metricValue: Self.round(record.value),
            excerpt: "\(Self.displayFormatter.string(from: record.date)) \(config.label) \(valueText) \(config.unit)"
        )
    }

    func workoutEvent(_ record: HoloHealthWorkoutRecord) -> HoloEvidenceEvent {
        let typeText = record.topType.map { " · \($0)" } ?? ""
        return HoloEvidenceEvent(
            id: "workout-\(Self.idFormatter.string(from: record.date))",
            occurredAt: record.date,
            metricKey: "health.workout.daily_minutes",
            metricValue: Self.round(record.totalMinutes),
            excerpt: "\(Self.displayFormatter.string(from: record.date)) 运动 \(String(format: "%.0f", record.totalMinutes)) 分钟 · \(record.sessionCount) 次\(typeText)"
        )
    }

    func coverage(_ dates: [Date], timeRange: HoloAgentTimeRange?) -> HoloDataCoverage {
        let calendar = Calendar.current
        let uniqueDays = Set(dates.map { calendar.startOfDay(for: $0) }).count
        let totalDays = Self.expectedDays(in: timeRange, calendar: calendar)
        return HoloDataCoverage(
            coveredDays: uniqueDays,
            totalDays: totalDays,
            coverageRatio: totalDays > 0 ? Double(uniqueDays) / Double(totalDays) : nil,
            missingRanges: [],
            note: "已读取 \(uniqueDays)/\(totalDays) 天健康数据",
            semantics: .dailyObservations
        )
    }

    static func expectedDays(in timeRange: HoloAgentTimeRange?, calendar: Calendar) -> Int {
        guard let start = timeRange?.start, let end = timeRange?.end else { return 14 }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return max(1, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 1)
    }

    func warning(for metric: HoloHealthMetricKind) -> HoloToolWarning {
        switch metric {
        case .steps: HoloToolWarning(code: "NO_STEPS_DATA", message: "没有可用的步数数据")
        case .sleep: HoloToolWarning(code: "NO_SLEEP_DATA", message: "没有可用的睡眠数据")
        case .stand: HoloToolWarning(code: "NO_STAND_DATA", message: "没有可用的站立数据")
        case .activity: HoloToolWarning(code: "NO_ACTIVITY_DATA", message: "没有可用的活动分钟数据")
        }
    }

    func empty(_ request: HoloToolRequest, warning: HoloToolWarning) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .empty,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [warning],
            error: nil,
            sensitivity: .sensitive
        )
    }

    func error(_ request: HoloToolRequest, reason: String) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .error,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [],
            error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: reason, recoverable: true),
            sensitivity: .sensitive
        )
    }

    /// §7.1/§7.2：设备锁定，HealthKit 暂不可读（可恢复，Runtime 据此进入等待解锁）。
    func deviceLocked(_ request: HoloToolRequest) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .error,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [],
            error: HoloToolError(
                code: HoloToolErrorCode.deviceLocked,
                message: "设备锁定，解锁后继续读取健康数据",
                recoverable: true
            ),
            sensitivity: .sensitive
        )
    }

    /// §7.1：权限拒绝（不可恢复）与暂时性错误（可恢复）的显式映射。
    func unavailableResult(_ request: HoloToolRequest, error: HoloHealthQueryError) -> HoloDataToolResult {
        let toolError: HoloToolError
        switch error {
        case .authorizationDenied:
            toolError = HoloToolError(
                code: HoloToolErrorCode.healthPermissionDenied,
                message: "未授权读取健康数据，请在系统设置中允许 Holo 读取健康数据",
                recoverable: false
            )
        case .recoverable(let message):
            toolError = HoloToolError(
                code: HoloToolErrorCode.healthTemporarilyUnavailable,
                message: "健康数据暂时不可用：\(message)",
                recoverable: true
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .error,
            coverage: nil,
            metrics: [],
            events: [],
            warnings: [],
            error: toolError,
            sensitivity: .sensitive
        )
    }

    func metric(_ key: String, _ value: Double, unit: String, baseline: Double? = nil) -> HoloMetric {
        HoloMetric(
            metricKey: key,
            value: Self.round(value),
            unit: unit,
            baselineValue: baseline.map(Self.round),
            comparison: baseline.map { "较上期\(Self.signed(Self.round(value - $0)))\(unit)" }
        )
    }

    static func appendAverage(
        _ keyPath: KeyPath<HoloSleepRecord, Double?>,
        key: String,
        unit: String,
        multiplier: Double = 1,
        records: [HoloSleepRecord],
        to metrics: inout [HoloMetric]
    ) {
        let values = records.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return }
        let average = values.reduce(0, +) / Double(values.count) * multiplier
        metrics.append(HoloMetric(metricKey: key, value: round(average), unit: unit,
                                  baselineValue: nil, comparison: nil))
    }

    static func previousRange(for range: HoloAgentTimeRange?) -> HoloAgentTimeRange? {
        guard let range, let start = range.start, let end = range.end else { return nil }
        let duration = end.timeIntervalSince(start)
        return HoloAgentTimeRange(label: "上期", start: start.addingTimeInterval(-duration), end: start)
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count))
    }

    static func minutesSinceMidnight(_ date: Date) -> Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    static func circularMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let radians = values.map { $0 / 1440 * 2 * Double.pi }
        let angle = atan2(radians.map(sin).reduce(0, +), radians.map(cos).reduce(0, +))
        return ((angle < 0 ? angle + 2 * Double.pi : angle) / (2 * Double.pi) * 1440)
    }

    static func circularStandardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = circularMean(values)
        let distances = values.map { value -> Double in
            let raw = abs(value - mean)
            return min(raw, 1440 - raw)
        }
        return sqrt(distances.reduce(0) { $0 + $1 * $1 } / Double(distances.count))
    }

    static func sleepEvent(_ record: HoloSleepRecord) -> HoloEvidenceEvent {
        var details = ["睡眠 \(String(format: "%.1f", record.totalHours)) 小时"]
        if let deep = record.deepHours { details.append("深睡 \(String(format: "%.1f", deep)) 小时") }
        if let core = record.coreHours { details.append("核心 \(String(format: "%.1f", core)) 小时") }
        if let rem = record.remHours { details.append("REM \(String(format: "%.1f", rem)) 小时") }
        if let efficiency = record.sleepEfficiency { details.append("效率 \(String(format: "%.0f", efficiency * 100))%") }
        return HoloEvidenceEvent(id: "sleep-\(idFormatter.string(from: record.date))", occurredAt: record.date,
                                 metricKey: "health.sleep.hours", metricValue: round(record.totalHours),
                                 excerpt: "\(displayFormatter.string(from: record.date)) \(details.joined(separator: " · "))")
    }

    static func signed(_ value: Double) -> String { value >= 0 ? "+\(value)" : "\(value)" }

    static func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
