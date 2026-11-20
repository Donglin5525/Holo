//
//  HoloLifeFeatureDistiller.swift
//  Holo
//
//  Phase 1：端侧全模块特征蒸馏器（纯 Swift，零 App 依赖）。
//
//  职责：把七个模块（财务/健康/习惯/想法/任务/目标/档案）的原始记录，在本机蒸馏成
//  一份紧凑、脱敏、高信息密度的 CrossDomainFeaturePacket JSON，供云端 Flash 模型
//  在单次调用中同时看到全局画面，产出动态用户画像与跨模块洞察。
//
//  铁律：
//  - 纯统计/算术/打卡计数只作底层原料，不直接写成面向用户的记忆句子。
//  - 严格保留数据覆盖率（coverage），区分「行为下降」与「HealthKit 无读数/未佩戴」。
//  - 过滤代办/报销消费，排除默认午夜补账时间，防止时段误判。
//

import Foundation

// MARK: - 输入结构体（七域原始只读投影）

nonisolated struct FinanceFeatureInput: Sendable, Equatable {
    var id: String
    var note: String?
    var categoryName: String?
    var occurredAt: Date
    var isMidnightDefault: Bool
}

nonisolated struct HealthSleepFeatureInput: Sendable, Equatable {
    var wakeDate: Date
    var totalHours: Double
    var bedtime: Date?
    var wakeTime: Date?
}

nonisolated struct HealthDailyMetricInput: Sendable, Equatable {
    var date: Date
    var value: Double
}

nonisolated struct HabitFeatureInput: Sendable, Equatable {
    var habitID: String
    var habitName: String
    var isNumeric: Bool
    var unit: String?
    var isPaused: Bool
    var date: Date
    var isCompleted: Bool
    var numericValue: Double?
}

nonisolated struct ThoughtFeatureInput: Sendable, Equatable {
    var id: String
    var text: String
    var createdAt: Date
}

nonisolated struct TaskFeatureInput: Sendable, Equatable {
    var title: String
    var isCompleted: Bool
    var updatedAt: Date
}

nonisolated struct GoalFeatureInput: Sendable, Equatable {
    var title: String
    var status: String
    var desiredOutcome: String?
}

// MARK: - 输出结构体（CrossDomainFeaturePacket）

nonisolated enum FeatureCoverage: String, Codable, Sendable, Equatable {
    case good      // 覆盖率 >= 60%
    case partial   // 覆盖率 20% ~ 59%
    case none      // 覆盖率 < 20% 或 0 天（原因未知：可能未佩戴或未授权）
}

nonisolated struct TimeOfDayCounts: Codable, Sendable, Equatable {
    var morning: Int = 0     // 05:00 - 10:59
    var afternoon: Int = 0   // 11:00 - 16:59
    var evening: Int = 0     // 17:00 - 22:59
    var night: Int = 0       // 23:00 - 04:59

    enum CodingKeys: String, CodingKey {
        case morning = "上午"
        case afternoon = "下午"
        case evening = "晚间"
        case night = "深夜"
    }

    var totalTimed: Int { morning + afternoon + evening + night }
}

nonisolated struct FinanceConceptFeature: Codable, Sendable, Equatable {
    var concept: String
    var count: Int
    var spanDays: Int
    var recent30dCount: Int
    var timeOfDay: TimeOfDayCounts?
    var dominantBand: String?
}

nonisolated struct FinanceFeatureSummary: Codable, Sendable, Equatable {
    var windowDays: Int
    var totalTransactions: Int
    var excludedProxyOrOrgCount: Int
    var recurringConcepts: [FinanceConceptFeature]
}

nonisolated struct SleepFeatureSummary: Codable, Sendable, Equatable {
    var coverage: FeatureCoverage
    var recentDaysWithData: Int
    var recentWindowDays: Int
    var recentAvgHours: Double?
    var baselineAvgHours: Double?
    var durationDeltaMinutes: Int?
    var recentAvgBedtimeHHMM: String?
    var baselineAvgBedtimeHHMM: String?
    /// 正值表示近期入睡更晚（单位：分钟）。
    var bedtimeShiftMinutes: Int?
    /// 近期入睡 >= 23:30 的占比（0.0 ~ 1.0）。
    var lateSleepRatio: Double?
    /// 近期总时长 < 7.0h 的占比（0.0 ~ 1.0）。
    var shortSleepRatio: Double?
}

nonisolated struct ActivityFeatureSummary: Codable, Sendable, Equatable {
    var coverage: FeatureCoverage
    var recentDaysWithData: Int
    var recentWindowDays: Int
    var recentAvgSteps: Int?
    var baselineAvgSteps: Int?
    var stepsChangePercent: Int?
    var recentAvgActiveMinutes: Int?
    var baselineAvgActiveMinutes: Int?
    var activeMinutesChangePercent: Int?
}

nonisolated struct HealthFeatureSummary: Codable, Sendable, Equatable {
    var sleep: SleepFeatureSummary
    var activity: ActivityFeatureSummary
}

nonisolated struct CheckinHabitTrend: Codable, Sendable, Equatable {
    var name: String
    var recent21dCount: Int
    var baseline21dCount: Int
    var total90dCount: Int
    var direction: String // up | down | flat
}

nonisolated struct NumericHabitTrend: Codable, Sendable, Equatable {
    var name: String
    var unit: String?
    var sampleCount: Int
    var spanDays: Int
    var earliestAvg: Double
    var recentAvg: Double
    var delta: Double
    var direction: String // up | down | flat
}

nonisolated struct HabitFeatureSummary: Codable, Sendable, Equatable {
    var checkins: [CheckinHabitTrend]
    var numerics: [NumericHabitTrend]
}

nonisolated struct ThoughtExcerptFeature: Codable, Sendable, Equatable {
    var daysAgo: Int
    var excerpt: String
}

nonisolated struct GoalFeatureItem: Codable, Sendable, Equatable {
    var title: String
    var status: String
    var desiredOutcome: String?
}

nonisolated struct CrossDomainAnomalySignal: Codable, Sendable, Equatable {
    var code: String
    var domain: String
    var summary: String
}

nonisolated struct CrossDomainFeaturePacket: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var generatedAtISO: String
    var finance: FinanceFeatureSummary
    var health: HealthFeatureSummary
    var habits: HabitFeatureSummary
    var thoughts: [ThoughtExcerptFeature]
    var recentTasks: [String]
    var activeGoals: [GoalFeatureItem]
    var profileSummary: String?
    /// 用户此前亲手确认过的有价值旧记忆（已自动过滤浅层算术/模板复述），供新版画像融合升级为 confirmed 节点。
    var confirmedLegacyMemories: [String]
    var anomalies: [CrossDomainAnomalySignal]

    func encodeCompactJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 粗略 token 估算（中文约 1.5 字/token，ASCII 约 4 字符/token）。
    var estimatedTokens: Int {
        guard let json = encodeCompactJSON() else { return 0 }
        var asciiCount = 0
        var nonAsciiCount = 0
        for scalar in json.unicodeScalars {
            if scalar.isASCII {
                asciiCount += 1
            } else {
                nonAsciiCount += 1
            }
        }
        return (asciiCount / 4) + Int(Double(nonAsciiCount) / 1.4)
    }
}

// MARK: - 蒸馏器（纯函数）

nonisolated enum HoloLifeFeatureDistiller {

    static let financeWindowDays = 180
    static let healthRecentDays = 14
    static let healthBaselineDays = 60
    static let habitRecentDays = 21

    private static let proxyKeywords = [
        "帮朋友", "帮同事", "帮邻居", "帮家里", "帮妈", "帮爸",
        "代买", "代购", "代付", "垫付", "报销", "公费", "公司报销", "团建"
    ]

    private static let genericStopWords: Set<String> = [
        "消费", "支出", "付款", "支付", "微信", "支付宝", "转账",
        "其他", "杂项", "商品", "购物", "买东西", "日常"
    ]

    static func distill(
        now: Date,
        calendar: Calendar = .current,
        finance: [FinanceFeatureInput],
        sleep: [HealthSleepFeatureInput],
        steps: [HealthDailyMetricInput],
        activeMinutes: [HealthDailyMetricInput],
        habits: [HabitFeatureInput],
        thoughts: [ThoughtFeatureInput],
        tasks: [TaskFeatureInput],
        goals: [GoalFeatureInput],
        profileMarkdown: String?,
        confirmedLegacyMemories: [String] = []
    ) -> CrossDomainFeaturePacket {
        var anomalies: [CrossDomainAnomalySignal] = []

        let financeSummary = distillFinance(finance, now: now, calendar: calendar)
        let sleepSummary = distillSleep(sleep, now: now, calendar: calendar, anomalies: &anomalies)
        let activitySummary = distillActivity(
            steps: steps,
            activeMinutes: activeMinutes,
            now: now,
            anomalies: &anomalies
        )
        let habitSummary = distillHabits(habits, now: now, anomalies: &anomalies)
        let thoughtExcerpts = distillThoughts(thoughts, now: now)
        let taskTitles = distillTasks(tasks)
        let goalItems = distillGoals(goals)
        let compactProfile = distillProfile(profileMarkdown)
        let cleanLegacy = distillLegacyConfirmed(confirmedLegacyMemories)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        return CrossDomainFeaturePacket(
            schemaVersion: 1,
            generatedAtISO: isoFormatter.string(from: now),
            finance: financeSummary,
            health: HealthFeatureSummary(sleep: sleepSummary, activity: activitySummary),
            habits: habitSummary,
            thoughts: thoughtExcerpts,
            recentTasks: taskTitles,
            activeGoals: goalItems,
            profileSummary: compactProfile,
            confirmedLegacyMemories: cleanLegacy,
            anomalies: anomalies
        )
    }

    /// 判断一条旧记忆是否属于浅层算术或模板复述（不应作为高价值语义记忆展示或原样继承）。
    static func isLegacyShallowTemplate(_ text: String) -> Bool {
        let markers = ["平均每隔", "习惯进行中", "期间有反复", "天一笔"]
        return markers.contains { text.contains($0) }
    }

    private static func distillLegacyConfirmed(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, !isLegacyShallowTemplate(trimmed) else { continue }
            let clipped = String(trimmed.prefix(60))
            if seen.insert(clipped).inserted {
                result.append(clipped)
                if result.count >= 15 { break }
            }
        }
        return result
    }

    // MARK: - 1. 财务蒸馏

    private static func distillFinance(
        _ inputs: [FinanceFeatureInput],
        now: Date,
        calendar: Calendar
    ) -> FinanceFeatureSummary {
        let cutoff30 = now.addingTimeInterval(-30 * 86_400)
        var excludedProxy = 0
        var grouped: [String: [FinanceFeatureInput]] = [:]

        for item in inputs {
            let trimmedNote = item.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isProxyOrOrganization(trimmedNote) {
                excludedProxy += 1
                continue
            }
            guard let concept = extractFinanceConcept(note: trimmedNote, category: item.categoryName) else {
                continue
            }
            grouped[concept, default: []].append(item)
        }

        var concepts: [FinanceConceptFeature] = []
        for (concept, items) in grouped {
            // 至少出现 2 次才进入重复消费语义簇，避免一次性噪声占满上下文。
            guard items.count >= 2 else { continue }
            let dates = items.map(\.occurredAt).sorted()
            let spanDays: Int
            if let first = dates.first, let last = dates.last {
                spanDays = max(0, Int(last.timeIntervalSince(first) / 86_400))
            } else {
                spanDays = 0
            }
            let recent30 = items.filter { $0.occurredAt >= cutoff30 }.count

            var tod = TimeOfDayCounts()
            for item in items where !item.isMidnightDefault {
                let hour = calendar.component(.hour, from: item.occurredAt)
                switch hour {
                case 5..<11: tod.morning += 1
                case 11..<17: tod.afternoon += 1
                case 17..<23: tod.evening += 1
                default: tod.night += 1
                }
            }
            let dominant = dominantTimeBand(tod)
            concepts.append(FinanceConceptFeature(
                concept: concept,
                count: items.count,
                spanDays: spanDays,
                recent30dCount: recent30,
                timeOfDay: tod.totalTimed > 0 ? tod : nil,
                dominantBand: dominant
            ))
        }

        // 优先保留高频 & 近期活跃概念，上限 20 个，控制 token 体积。
        concepts.sort { lhs, rhs in
            if lhs.recent30dCount != rhs.recent30dCount {
                return lhs.recent30dCount > rhs.recent30dCount
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.concept < rhs.concept
        }

        return FinanceFeatureSummary(
            windowDays: financeWindowDays,
            totalTransactions: inputs.count,
            excludedProxyOrOrgCount: excludedProxy,
            recurringConcepts: Array(concepts.prefix(20))
        )
    }

    private static func isProxyOrOrganization(_ note: String) -> Bool {
        guard !note.isEmpty else { return false }
        return proxyKeywords.contains { note.contains($0) }
    }

    /// 优先用简洁备注（保留「猫粮」「咖啡」等两字核心概念）；无备注时回退到具体子类目。
    private static func extractFinanceConcept(note: String, category: String?) -> String? {
        if !note.isEmpty {
            let cleaned = normalizeConcept(note)
            if cleaned.count >= 2 && !genericStopWords.contains(cleaned) {
                return String(cleaned.prefix(16))
            }
        }
        if let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines),
           cat.count >= 2,
           !genericStopWords.contains(cat) {
            return String(cat.prefix(16))
        }
        return nil
    }

    private static func normalizeConcept(_ raw: String) -> String {
        let separators = CharacterSet(charactersIn: " ，,。；;、/\\|-—()（）[]【】")
        let tokens = raw.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let first = tokens.first else { return raw }
        return first
    }

    private static func dominantTimeBand(_ tod: TimeOfDayCounts) -> String? {
        guard tod.totalTimed >= 3 else { return nil }
        let pairs: [(String, Int)] = [
            ("上午", tod.morning),
            ("下午", tod.afternoon),
            ("晚间", tod.evening),
            ("深夜", tod.night)
        ]
        guard let top = pairs.max(by: { $0.1 < $1.1 }),
              Double(top.1) / Double(tod.totalTimed) >= 0.5 else {
            return nil
        }
        return top.0
    }

    // MARK: - 2. 健康睡眠蒸馏

    private static func distillSleep(
        _ inputs: [HealthSleepFeatureInput],
        now: Date,
        calendar: Calendar,
        anomalies: inout [CrossDomainAnomalySignal]
    ) -> SleepFeatureSummary {
        let recentStart = now.addingTimeInterval(-TimeInterval(healthRecentDays) * 86_400)
        let baselineStart = now.addingTimeInterval(-TimeInterval(healthBaselineDays) * 86_400)

        let valid = inputs.filter { $0.totalHours > 0.5 && $0.totalHours <= 20 }
        let recent = valid.filter { $0.wakeDate >= recentStart && $0.wakeDate <= now }
        let baseline = valid.filter { $0.wakeDate >= baselineStart && $0.wakeDate < recentStart }

        let recentDays = Set(recent.map { calendar.startOfDay(for: $0.wakeDate) }).count
        let coverage = coverageLevel(daysWithData: recentDays, windowDays: healthRecentDays)

        guard coverage != .none, !recent.isEmpty else {
            return SleepFeatureSummary(
                coverage: .none,
                recentDaysWithData: recentDays,
                recentWindowDays: healthRecentDays,
                recentAvgHours: nil,
                baselineAvgHours: nil,
                durationDeltaMinutes: nil,
                recentAvgBedtimeHHMM: nil,
                baselineAvgBedtimeHHMM: nil,
                bedtimeShiftMinutes: nil,
                lateSleepRatio: nil,
                shortSleepRatio: nil
            )
        }

        let recentAvgH = round1(recent.map(\.totalHours).reduce(0, +) / Double(recent.count))
        let baselineAvgH: Double? = baseline.count >= 5
            ? round1(baseline.map(\.totalHours).reduce(0, +) / Double(baseline.count))
            : nil
        let durationDeltaMin: Int? = baselineAvgH.map { Int(((recentAvgH - $0) * 60).rounded()) }

        let recentBedMins = recent.compactMap { $0.bedtime.map { bedtimeMinutesSince1800($0, calendar: calendar) } }
        let baselineBedMins = baseline.compactMap { $0.bedtime.map { bedtimeMinutesSince1800($0, calendar: calendar) } }

        let recentAvgBed: Int? = recentBedMins.isEmpty ? nil : recentBedMins.reduce(0, +) / recentBedMins.count
        let baselineAvgBed: Int? = baselineBedMins.count >= 5 ? baselineBedMins.reduce(0, +) / baselineBedMins.count : nil
        let bedtimeShift: Int? = (recentAvgBed != nil && baselineAvgBed != nil)
            ? (recentAvgBed ?? 0) - (baselineAvgBed ?? 0)
            : nil

        // 23:30 距 18:00 为 330 分钟。
        let lateRatio: Double? = recentBedMins.isEmpty
            ? nil
            : round2(Double(recentBedMins.filter { $0 >= 330 }.count) / Double(recentBedMins.count))
        let shortRatio = round2(Double(recent.filter { $0.totalHours < 7.0 }.count) / Double(recent.count))

        if recentAvgH < 6.8 || shortRatio >= 0.6 {
            anomalies.append(CrossDomainAnomalySignal(
                code: "sleep_short",
                domain: "health",
                summary: "近\(healthRecentDays)天平均睡眠\(recentAvgH)小时（不足7小时天数占比\(Int((shortRatio * 100).rounded()))%）"
            ))
        }
        if let shift = bedtimeShift, shift >= 30 {
            anomalies.append(CrossDomainAnomalySignal(
                code: "sleep_later",
                domain: "health",
                summary: "近\(healthRecentDays)天平均入睡较基线推迟约\(shift)分钟（均\(recentAvgBed.map(formatBedtime) ?? "")）"
            ))
        } else if let lr = lateRatio, lr >= 0.6, let avgBed = recentAvgBed {
            anomalies.append(CrossDomainAnomalySignal(
                code: "sleep_late",
                domain: "health",
                summary: "近\(healthRecentDays)天多数较晚入睡（均\(formatBedtime(avgBed))）"
            ))
        }

        return SleepFeatureSummary(
            coverage: coverage,
            recentDaysWithData: recentDays,
            recentWindowDays: healthRecentDays,
            recentAvgHours: recentAvgH,
            baselineAvgHours: baselineAvgH,
            durationDeltaMinutes: durationDeltaMin,
            recentAvgBedtimeHHMM: recentAvgBed.map(formatBedtime),
            baselineAvgBedtimeHHMM: baselineAvgBed.map(formatBedtime),
            bedtimeShiftMinutes: bedtimeShift,
            lateSleepRatio: lateRatio,
            shortSleepRatio: shortRatio
        )
    }

    /// 以 18:00 为 0 点计算入睡偏移分钟（解决 23:30 与 00:30 跨午夜平均失真问题）。
    static func bedtimeMinutesSince1800(_ date: Date, calendar: Calendar) -> Int {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let totalFromMidnight = hour * 60 + minute
        if hour >= 18 {
            return totalFromMidnight - 18 * 60
        } else {
            return totalFromMidnight + 6 * 60
        }
    }

    static func formatBedtime(_ minutesSince1800: Int) -> String {
        let wrapped = ((minutesSince1800 + 18 * 60) % 1440 + 1440) % 1440
        let h = wrapped / 60
        let m = wrapped % 60
        return String(format: "%02d:%02d", h, m)
    }

    // MARK: - 3. 健康活动量蒸馏

    private static func distillActivity(
        steps: [HealthDailyMetricInput],
        activeMinutes: [HealthDailyMetricInput],
        now: Date,
        anomalies: inout [CrossDomainAnomalySignal]
    ) -> ActivityFeatureSummary {
        let recentStart = now.addingTimeInterval(-TimeInterval(healthRecentDays) * 86_400)
        let baselineStart = now.addingTimeInterval(-TimeInterval(healthBaselineDays) * 86_400)

        let recentSteps = steps.filter { $0.date >= recentStart && $0.date <= now && $0.value > 0 }
        let baselineSteps = steps.filter { $0.date >= baselineStart && $0.date < recentStart && $0.value > 0 }

        let recentActive = activeMinutes.filter { $0.date >= recentStart && $0.date <= now && $0.value > 0 }
        let baselineActive = activeMinutes.filter { $0.date >= baselineStart && $0.date < recentStart && $0.value > 0 }

        let daysWithData = max(recentSteps.count, recentActive.count)
        let coverage = coverageLevel(daysWithData: daysWithData, windowDays: healthRecentDays)

        guard coverage != .none else {
            return ActivityFeatureSummary(
                coverage: .none,
                recentDaysWithData: daysWithData,
                recentWindowDays: healthRecentDays,
                recentAvgSteps: nil,
                baselineAvgSteps: nil,
                stepsChangePercent: nil,
                recentAvgActiveMinutes: nil,
                baselineAvgActiveMinutes: nil,
                activeMinutesChangePercent: nil
            )
        }

        let avgRecentSteps: Int? = recentSteps.isEmpty ? nil : Int((recentSteps.map(\.value).reduce(0, +) / Double(recentSteps.count)).rounded())
        let avgBaselineSteps: Int? = baselineSteps.count >= 5 ? Int((baselineSteps.map(\.value).reduce(0, +) / Double(baselineSteps.count)).rounded()) : nil
        let stepsPct = percentChange(recent: avgRecentSteps.map(Double.init), baseline: avgBaselineSteps.map(Double.init))

        let avgRecentActive: Int? = recentActive.isEmpty ? nil : Int((recentActive.map(\.value).reduce(0, +) / Double(recentActive.count)).rounded())
        let avgBaselineActive: Int? = baselineActive.count >= 5 ? Int((baselineActive.map(\.value).reduce(0, +) / Double(baselineActive.count)).rounded()) : nil
        let activePct = percentChange(recent: avgRecentActive.map(Double.init), baseline: avgBaselineActive.map(Double.init))

        if let pct = activePct, pct <= -25 {
            anomalies.append(CrossDomainAnomalySignal(
                code: "activity_drop",
                domain: "health",
                summary: "近\(healthRecentDays)天日均活动时长较基线下降\(abs(pct))%"
            ))
        } else if let pct = stepsPct, pct <= -25 {
            anomalies.append(CrossDomainAnomalySignal(
                code: "activity_drop",
                domain: "health",
                summary: "近\(healthRecentDays)天日均步数较基线下降\(abs(pct))%"
            ))
        }

        return ActivityFeatureSummary(
            coverage: coverage,
            recentDaysWithData: daysWithData,
            recentWindowDays: healthRecentDays,
            recentAvgSteps: avgRecentSteps,
            baselineAvgSteps: avgBaselineSteps,
            stepsChangePercent: stepsPct,
            recentAvgActiveMinutes: avgRecentActive,
            baselineAvgActiveMinutes: avgBaselineActive,
            activeMinutesChangePercent: activePct
        )
    }

    // MARK: - 4. 习惯（打卡型 + 数值型）蒸馏

    private static func distillHabits(
        _ inputs: [HabitFeatureInput],
        now: Date,
        anomalies: inout [CrossDomainAnomalySignal]
    ) -> HabitFeatureSummary {
        let recentStart = now.addingTimeInterval(-TimeInterval(habitRecentDays) * 86_400)
        let baselineStart = now.addingTimeInterval(-TimeInterval(habitRecentDays * 2) * 86_400)

        var grouped: [String: [HabitFeatureInput]] = [:]
        for item in inputs where !item.isPaused {
            grouped[item.habitID, default: []].append(item)
        }

        var checkins: [CheckinHabitTrend] = []
        var numerics: [NumericHabitTrend] = []

        for (_, records) in grouped {
            guard let sample = records.first else { continue }
            let name = String(sample.habitName.prefix(20))

            if sample.isNumeric {
                let valued = records
                    .filter { $0.numericValue != nil }
                    .sorted { $0.date < $1.date }
                guard valued.count >= 3 else { continue }
                let splitCount = max(1, min(3, valued.count / 3))
                let headVals = valued.prefix(splitCount).compactMap(\.numericValue)
                let tailVals = valued.suffix(splitCount).compactMap(\.numericValue)
                guard !headVals.isEmpty, !tailVals.isEmpty else { continue }

                let earliestAvg = round2(headVals.reduce(0, +) / Double(headVals.count))
                let recentAvg = round2(tailVals.reduce(0, +) / Double(tailVals.count))
                let delta = round2(recentAvg - earliestAvg)
                let spanDays: Int
                if let first = valued.first?.date, let last = valued.last?.date {
                    spanDays = max(0, Int(last.timeIntervalSince(first) / 86_400))
                } else {
                    spanDays = 0
                }
                let relative = abs(earliestAvg) > 0.0001 ? abs(delta) / abs(earliestAvg) : 0
                let direction: String
                if relative < 0.015 {
                    direction = "flat"
                } else {
                    direction = delta > 0 ? "up" : "down"
                }

                numerics.append(NumericHabitTrend(
                    name: name,
                    unit: sample.unit,
                    sampleCount: valued.count,
                    spanDays: spanDays,
                    earliestAvg: earliestAvg,
                    recentAvg: recentAvg,
                    delta: delta,
                    direction: direction
                ))

                if direction != "flat" {
                    let sign = delta > 0 ? "+" : ""
                    let unitText = sample.unit ?? ""
                    anomalies.append(CrossDomainAnomalySignal(
                        code: direction == "up" ? "numeric_habit_up" : "numeric_habit_down",
                        domain: "habit",
                        summary: "数值习惯「\(name)」近\(max(1, spanDays))天变化\(sign)\(delta)\(unitText)（\(earliestAvg)→\(recentAvg)\(unitText)）"
                    ))
                }
            } else {
                let completed = records.filter(\.isCompleted)
                guard !completed.isEmpty else { continue }
                let recentCount = completed.filter { $0.date >= recentStart && $0.date <= now }.count
                let baselineCount = completed.filter { $0.date >= baselineStart && $0.date < recentStart }.count
                let direction: String
                if baselineCount >= 3 && Double(recentCount) <= Double(baselineCount) * 0.6 {
                    direction = "down"
                } else if recentCount >= 3 && Double(recentCount) >= Double(max(1, baselineCount)) * 1.4 {
                    direction = "up"
                } else {
                    direction = "flat"
                }
                checkins.append(CheckinHabitTrend(
                    name: name,
                    recent21dCount: recentCount,
                    baseline21dCount: baselineCount,
                    total90dCount: completed.count,
                    direction: direction
                ))
                if direction == "down" {
                    anomalies.append(CrossDomainAnomalySignal(
                        code: "habit_drop",
                        domain: "habit",
                        summary: "习惯「\(name)」近\(habitRecentDays)天打卡回落（\(baselineCount)次→\(recentCount)次）"
                    ))
                }
            }
        }

        checkins.sort { ($0.total90dCount, $0.name) > ($1.total90dCount, $1.name) }
        numerics.sort { ($0.sampleCount, $0.name) > ($1.sampleCount, $1.name) }

        return HabitFeatureSummary(
            checkins: Array(checkins.prefix(12)),
            numerics: Array(numerics.prefix(8))
        )
    }

    // MARK: - 5. 想法 / 任务 / 目标 / 档案蒸馏

    private static func distillThoughts(_ inputs: [ThoughtFeatureInput], now: Date) -> [ThoughtExcerptFeature] {
        let sorted = inputs.sorted { $0.createdAt > $1.createdAt }
        return sorted.prefix(12).compactMap { item in
            let trimmed = item.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let daysAgo = max(0, Int(now.timeIntervalSince(item.createdAt) / 86_400))
            return ThoughtExcerptFeature(daysAgo: daysAgo, excerpt: String(trimmed.prefix(80)))
        }
    }

    private static func distillTasks(_ inputs: [TaskFeatureInput]) -> [String] {
        let sorted = inputs.sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        var titles: [String] = []
        for task in sorted {
            let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let clipped = String(trimmed.prefix(30))
            if seen.insert(clipped).inserted {
                titles.append(clipped)
                if titles.count >= 12 { break }
            }
        }
        return titles
    }

    private static func distillGoals(_ inputs: [GoalFeatureInput]) -> [GoalFeatureItem] {
        inputs.prefix(6).compactMap { goal in
            let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let outcome = goal.desiredOutcome?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return GoalFeatureItem(
                title: String(title.prefix(30)),
                status: goal.status,
                desiredOutcome: (outcome?.isEmpty == false) ? outcome.map { String($0.prefix(40)) } : nil
            )
        }
    }

    private static func distillProfile(_ markdown: String?) -> String? {
        guard let raw = markdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        // 去掉空模板行（如「- 昵称：」后面没有值的行），只保留用户真实填写的内容。
        let meaningfulLines = raw.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("（") else { return false }
            if t.hasSuffix("：") || t.hasSuffix(":") { return false }
            return true
        }
        let joined = meaningfulLines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(600))
    }

    // MARK: - 通用数学工具

    private static func coverageLevel(daysWithData: Int, windowDays: Int) -> FeatureCoverage {
        guard windowDays > 0, daysWithData > 0 else { return .none }
        let ratio = Double(daysWithData) / Double(windowDays)
        if ratio >= 0.6 { return .good }
        if ratio >= 0.2 { return .partial }
        return .none
    }

    private static func percentChange(recent: Double?, baseline: Double?) -> Int? {
        guard let r = recent, let b = baseline, b > 0 else { return nil }
        return Int((((r - b) / b) * 100).rounded())
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
