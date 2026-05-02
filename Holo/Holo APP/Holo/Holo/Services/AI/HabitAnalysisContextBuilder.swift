//
//  HabitAnalysisContextBuilder.swift
//  Holo
//
//  习惯分析上下文构建器
//  调用 HabitRepository 的统计方法获取打卡和完成率数据
//

import Foundation
import os.log

struct HabitAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "HabitAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> HabitAnalysisContext? {
        let repo = HabitRepository.shared
        let calendar = Calendar.current
        let startInclusive = calendar.startOfDay(for: request.start)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            return nil
        }
        let range = startInclusive...endExclusive

        let activeHabits = repo.activeHabits
        let checkInHabits = activeHabits.filter { $0.isCheckInType }

        guard !checkInHabits.isEmpty else {
            return nil
        }

        let completedRecordCount = calculateCompletedRecords(
            habits: checkInHabits,
            range: range,
            repo: repo
        )

        // 完成率
        let dayCount = max(calendar.dateComponents([.day], from: startInclusive, to: endExclusive).day ?? 1, 1)
        let expectedTotal = checkInHabits.count * dayCount
        let averageCompletionRate: Double? = expectedTotal > 0
            ? Double(completedRecordCount) / Double(expectedTotal)
            : nil

        // 按习惯统计完成率
        var habitRates: [(habit: Habit, rate: Double, streak: Int)] = []
        for habit in checkInHabits {
            let records = repo.getRecords(for: habit, in: range)
            let completed = records.filter { $0.isCompleted }.count
            let rate = dayCount > 0 ? Double(completed) / Double(dayCount) : 0
            let streak = repo.calculateStreak(for: habit)
            habitRates.append((habit, rate, streak))
        }

        // Top 5 表现最好的习惯
        let topPerforming = habitRates
            .filter { $0.rate > 0 }
            .sorted { $0.rate > $1.rate }
            .prefix(5)
            .map { HabitPerformanceItem(habitName: $0.habit.name, completionRate: $0.rate, streak: $0.streak) }

        // 掉队习惯（完成率 < 50%）
        let struggling = habitRates
            .filter { $0.rate > 0 && $0.rate < 0.5 }
            .sorted { $0.rate < $1.rate }
            .prefix(3)
            .map { HabitPerformanceItem(habitName: $0.habit.name, completionRate: $0.rate, streak: $0.streak) }

        // Streaks
        let streaks = habitRates
            .filter { $0.streak > 0 }
            .sorted { $0.streak > $1.streak }
            .prefix(5)
            .map { HabitStreakItem(habitName: $0.habit.name, currentStreak: $0.streak, longestStreak: $0.streak) }

        // 日完成趋势
        let dailyTrend = buildDailyCompletionTrend(
            habits: checkInHabits,
            range: range,
            start: startInclusive,
            end: endExclusive,
            calendar: calendar,
            repo: repo
        )

        // 上周期对比
        var previousPeriodCompletedRecordCount: Int?
        if let compStart = request.comparisonStart,
           let compEnd = request.comparisonEnd {
            let compStartDay = calendar.startOfDay(for: compStart)
            let compEndExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: compEnd))
            if let compEndExcl = compEndExclusive {
                previousPeriodCompletedRecordCount = calculateCompletedRecords(
                    habits: checkInHabits,
                    range: compStartDay...compEndExcl,
                    repo: repo
                )
            }
        }

        return HabitAnalysisContext(
            activeHabitCount: checkInHabits.count,
            completedRecordCount: completedRecordCount,
            averageCompletionRate: averageCompletionRate,
            topPerformingHabits: topPerforming,
            strugglingHabits: struggling,
            streaks: streaks,
            dailyCompletionTrend: dailyTrend,
            previousPeriodCompletedRecordCount: previousPeriodCompletedRecordCount
        )
    }

    // MARK: - Helpers

    @MainActor
    private func calculateCompletedRecords(
        habits: [Habit],
        range: ClosedRange<Date>,
        repo: HabitRepository
    ) -> Int {
        var total = 0
        for habit in habits {
            let records = repo.getRecords(for: habit, in: range)
            total += records.filter { $0.isCompleted }.count
        }
        return total
    }

    @MainActor
    private func buildDailyCompletionTrend(
        habits: [Habit],
        range: ClosedRange<Date>,
        start: Date,
        end: Date,
        calendar: Calendar,
        repo: HabitRepository
    ) -> [DailyRatePoint] {
        guard habits.count > 0 else { return [] }

        var dailyCompleted: [Date: Int] = [:]
        var current = start
        while current <= end {
            dailyCompleted[calendar.startOfDay(for: current)] = 0
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        for habit in habits {
            let records = repo.getRecords(for: habit, in: range)
            for record in records where record.isCompleted {
                let day = calendar.startOfDay(for: record.date)
                dailyCompleted[day, default: 0] += 1
            }
        }

        let totalDays = dailyCompleted.count
        return dailyCompleted.sorted { $0.key < $1.key }
            .prefix(31)
            .map { date, count in
                let rate = totalDays > 0 ? Double(count) / Double(habits.count) : 0
                return DailyRatePoint(date: Self.dateFmt.string(from: date), rate: min(rate, 1.0))
            }
    }
}
