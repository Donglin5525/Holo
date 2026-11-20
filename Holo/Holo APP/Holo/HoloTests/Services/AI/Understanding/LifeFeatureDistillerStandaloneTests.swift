//
//  LifeFeatureDistillerStandaloneTests.swift
//  Holo
//
//  Phase 1：端侧全模块特征蒸馏器（HoloLifeFeatureDistiller）standalone 回归锁。
//  覆盖东林三大核心场景（猫粮/咖啡+晚睡/体重+运动含无读数分支）+ 代理排除 + 档案瘦身 + Token 体积。
//

import Foundation

enum LifeFeatureDistillerStandaloneTests {

    private static var passed = 0
    private static var failed = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [LifeFeatureDistiller]: \(name)\n", stderr)
        }
    }

    static func run() throws {
        passed = 0
        failed = 0

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12, minute: 0)) ?? Date()

        func date(daysAgo: Int, hour: Int = 12, minute: Int = 0) -> Date {
            let base = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            var comps = cal.dateComponents([.year, .month, .day], from: base)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            return cal.date(from: comps) ?? base
        }

        // MARK: - 场景 1 + 2 + 3A 联合蒸馏（完整数据）
        var finance: [FinanceFeatureInput] = [
            // 案例 1：6 个月 3 笔猫粮 + 1 笔代买（应被排除）
            FinanceFeatureInput(id: "c1", note: "猫粮", categoryName: "宠物", occurredAt: date(daysAgo: 150, hour: 10), isMidnightDefault: false),
            FinanceFeatureInput(id: "c2", note: "猫粮", categoryName: "宠物", occurredAt: date(daysAgo: 75, hour: 20), isMidnightDefault: false),
            FinanceFeatureInput(id: "c3", note: "猫粮", categoryName: "宠物", occurredAt: date(daysAgo: 5, hour: 15), isMidnightDefault: false),
            FinanceFeatureInput(id: "c4", note: "帮邻居买猫粮", categoryName: "宠物", occurredAt: date(daysAgo: 20, hour: 14), isMidnightDefault: false),
        ]
        // 案例 2：近 30 天 16 笔咖啡（14 笔下午 15:00 + 2 笔午夜补账不计入时段）
        for i in 1...14 {
            finance.append(FinanceFeatureInput(
                id: "cof\(i)", note: "咖啡", categoryName: "饮品",
                occurredAt: date(daysAgo: i * 2, hour: 15, minute: 30),
                isMidnightDefault: false
            ))
        }
        finance.append(FinanceFeatureInput(id: "cof_m1", note: "咖啡", categoryName: "饮品", occurredAt: date(daysAgo: 3, hour: 0), isMidnightDefault: true))
        finance.append(FinanceFeatureInput(id: "cof_m2", note: "咖啡", categoryName: "饮品", occurredAt: date(daysAgo: 7, hour: 0), isMidnightDefault: true))

        // 案例 2 健康睡眠：基线 20 晚 23:00 睡 7.5h；近 13 晚 00:05 睡 6.1h
        var sleep: [HealthSleepFeatureInput] = []
        for d in 15...34 {
            sleep.append(HealthSleepFeatureInput(
                wakeDate: date(daysAgo: d, hour: 7),
                totalHours: 7.5,
                bedtime: date(daysAgo: d + 1, hour: 23, minute: 0),
                wakeTime: date(daysAgo: d, hour: 6, minute: 30)
            ))
        }
        for d in 1...13 {
            sleep.append(HealthSleepFeatureInput(
                wakeDate: date(daysAgo: d, hour: 7),
                totalHours: 6.1,
                bedtime: date(daysAgo: d, hour: 0, minute: 5),
                wakeTime: date(daysAgo: d, hour: 6, minute: 11)
            ))
        }

        // 案例 3A 健康活动：基线日均 45min → 近期日均 18min（-60%）
        var activeMinutes: [HealthDailyMetricInput] = []
        for d in 15...34 {
            activeMinutes.append(HealthDailyMetricInput(date: date(daysAgo: d), value: 45))
        }
        for d in 1...13 {
            activeMinutes.append(HealthDailyMetricInput(date: date(daysAgo: d), value: 18))
        }

        // 案例 3A 习惯：体重（数值型 72.0 → 74.0 kg）+ 健身（打卡型 12 次 → 1 次）+ 暂停习惯（应过滤）
        var habits: [HabitFeatureInput] = []
        let weights: [(Int, Double)] = [
            (40, 72.0), (35, 72.1), (30, 72.2), (24, 72.8),
            (18, 73.2), (12, 73.5), (6, 73.9), (2, 74.1)
        ]
        for (daysAgo, w) in weights {
            habits.append(HabitFeatureInput(
                habitID: "h-weight", habitName: "体重", isNumeric: true, unit: "kg",
                isPaused: false, date: date(daysAgo: daysAgo), isCompleted: true, numericValue: w
            ))
        }
        for d in 22...33 {
            habits.append(HabitFeatureInput(
                habitID: "h-gym", habitName: "健身", isNumeric: false, unit: nil,
                isPaused: false, date: date(daysAgo: d), isCompleted: true, numericValue: nil
            ))
        }
        habits.append(HabitFeatureInput(
            habitID: "h-gym", habitName: "健身", isNumeric: false, unit: nil,
            isPaused: false, date: date(daysAgo: 5), isCompleted: true, numericValue: nil
        ))
        habits.append(HabitFeatureInput(
            habitID: "h-paused", habitName: "背单词", isNumeric: false, unit: nil,
            isPaused: true, date: date(daysAgo: 10), isCompleted: true, numericValue: nil
        ))

        let profileMD = """
        # 关于我
        - 昵称：东林
        - 所在城市：
        ## 沟通偏好
        - 回复风格：简洁直接
        """

        let packet = HoloLifeFeatureDistiller.distill(
            now: now,
            calendar: cal,
            finance: finance,
            sleep: sleep,
            steps: [],
            activeMinutes: activeMinutes,
            habits: habits,
            thoughts: [ThoughtFeatureInput(id: "t1", text: "最近晚上总睡不着，白天特别困", createdAt: date(daysAgo: 2))],
            tasks: [TaskFeatureInput(title: "买猫砂", isCompleted: false, updatedAt: date(daysAgo: 1))],
            goals: [GoalFeatureItemInputHelper.goal("减脂到70kg", status: "active", outcome: "恢复每周3次力量训练")],
            profileMarkdown: profileMD,
            confirmedLegacyMemories: [
                "偏好简洁直接的回复风格",
                "最近6个月有3笔「猫粮」支出，平均每隔约93天一笔",
                "「戒烟」习惯进行中，期间有反复"
            ]
        )

        // 校验案例 1：猫粮概念与代买过滤
        let catConcept = packet.finance.recurringConcepts.first { $0.concept == "猫粮" }
        check(catConcept?.count == 3, "猫粮应统计 3 笔（排除代买）")
        check((catConcept?.spanDays ?? 0) >= 140, "猫粮跨度应 >= 140 天")
        check(packet.finance.excludedProxyOrOrgCount == 1, "应排除 1 笔代买")

        // 校验案例 2：咖啡下午主时段 + 睡眠晚睡与不足
        let coffeeConcept = packet.finance.recurringConcepts.first { $0.concept == "咖啡" }
        check(coffeeConcept?.count == 16, "咖啡总计 16 笔")
        check(coffeeConcept?.dominantBand == "下午", "咖啡主时段应为 下午")
        check(coffeeConcept?.timeOfDay?.afternoon == 14, "午夜补账不计入时段，下午应为 14 笔")
        check(packet.health.sleep.coverage == .good, "睡眠覆盖率应为 good")
        check(packet.health.sleep.recentAvgHours == 6.1, "近期均睡应为 6.1h")
        check((packet.health.sleep.bedtimeShiftMinutes ?? 0) >= 60, "跨午夜入睡推迟应 >= 60 分钟（实际 \(packet.health.sleep.bedtimeShiftMinutes ?? -1)）")
        check(packet.anomalies.contains { $0.code == "sleep_short" }, "应产出 sleep_short 异常")
        check(packet.anomalies.contains { $0.code == "sleep_later" }, "应产出 sleep_later 异常")

        // 校验案例 3A：体重上升 + 运动下降 + 健身打卡下降 + 暂停习惯过滤
        let weightTrend = packet.habits.numerics.first { $0.name == "体重" }
        check(weightTrend?.direction == "up", "体重趋势应为 up")
        check((weightTrend?.delta ?? 0) >= 1.5, "体重变化应 >= 1.5kg")
        check(weightTrend?.unit == "kg", "体重单位保留 kg")
        let gymTrend = packet.habits.checkins.first { $0.name == "健身" }
        check(gymTrend?.direction == "down", "健身打卡趋势应为 down")
        check(!packet.habits.checkins.contains { $0.name == "背单词" }, "暂停习惯应被过滤")
        check(packet.health.activity.coverage == .good, "活动覆盖率应为 good")
        check(packet.health.activity.activeMinutesChangePercent == -60, "活动时长变化应为 -60%")
        check(packet.anomalies.contains { $0.code == "activity_drop" }, "应产出 activity_drop 异常")
        check(packet.anomalies.contains { $0.code == "numeric_habit_up" }, "应产出 numeric_habit_up 异常")
        check(packet.anomalies.contains { $0.code == "habit_drop" }, "应产出 habit_drop 异常")

        // 校验档案瘦身与 Token 体积
        check(packet.profileSummary?.contains("东林") == true, "档案保留已填内容")
        check(packet.profileSummary?.contains("所在城市：") == false, "档案剔除空模板行")
        check(packet.confirmedLegacyMemories == ["偏好简洁直接的回复风格"],
              "B方案：保留有价值的已确认旧记忆并自动过滤浅层算术/习惯模板")
        check(packet.estimatedTokens > 100 && packet.estimatedTokens < 2500, "特征包 token 应紧凑（实际 ~\(packet.estimatedTokens)）")

        // MARK: - 场景 3B：HealthKit 无运动读数时必须标记 coverage = .none，不得误报 activity_drop
        let packetNoHealth = HoloLifeFeatureDistiller.distill(
            now: now,
            calendar: cal,
            finance: [],
            sleep: [],
            steps: [],
            activeMinutes: [],
            habits: habits,
            thoughts: [],
            tasks: [],
            goals: [],
            profileMarkdown: nil
        )
        check(packetNoHealth.health.activity.coverage == .none, "无 HealthKit 数据时活动覆盖率必须为 none")
        check(packetNoHealth.health.sleep.coverage == .none, "无 HealthKit 数据时睡眠覆盖率必须为 none")
        check(!packetNoHealth.anomalies.contains { $0.code == "activity_drop" }, "无 HealthKit 数据不得误报 activity_drop")

        print("LifeFeatureDistillerStandaloneTests: \(passed) passed, \(failed) failed (packet ~\(packet.estimatedTokens) tokens)")
        if failed > 0 {
            throw NSError(domain: "LifeFeatureDistillerStandaloneTests", code: 1)
        }
    }
}

private enum GoalFeatureItemInputHelper {
    static func goal(_ title: String, status: String, outcome: String?) -> GoalFeatureInput {
        GoalFeatureInput(title: title, status: status, desiredOutcome: outcome)
    }
}
