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
        if !repo.isReady { repo.setup() }

        let calendar = Calendar.current
        let startInclusive = calendar.startOfDay(for: request.start)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            return nil
        }
        let range = startInclusive...endExclusive

        let activeHabits = repo.activeHabits

        guard !activeHabits.isEmpty else {
            return nil
        }

        let successDayCount = calculateSuccessDays(
            habits: activeHabits,
            range: range,
            repo: repo
        )

        let dayCount = max(calendar.dateComponents([.day], from: startInclusive, to: endExclusive).day ?? 1, 1)
        let expectedTotal = activeHabits.count * dayCount
        let averageCompletionRate: Double? = expectedTotal > 0 ? Double(successDayCount) / Double(expectedTotal) : nil

        var habitRates: [(habit: Habit, snapshot: HabitPerformanceSnapshot, streak: HabitStreak)] = []
        for habit in activeHabits {
            let snapshot = repo.evaluatePerformance(for: habit, in: range)
            let streak = repo.calculateStreakInfo(for: habit)
            habitRates.append((habit, snapshot, streak))
        }

        let topPerforming = habitRates
            .filter { $0.snapshot.completionRate > 0 }
            .sorted { $0.snapshot.completionRate > $1.snapshot.completionRate }
            .prefix(5)
            .map { item in
                makePerformanceItem(snapshot: item.snapshot, streak: item.streak.value)
            }

        let struggling = habitRates
            .filter { $0.snapshot.completionRate > 0 && $0.snapshot.completionRate < 0.5 }
            .sorted { $0.snapshot.completionRate < $1.snapshot.completionRate }
            .prefix(3)
            .map { item in
                makePerformanceItem(snapshot: item.snapshot, streak: item.streak.value)
            }

        // Streaks
        let streaks = habitRates
            .filter { $0.streak.value > 0 }
            .sorted { $0.streak.value > $1.streak.value }
            .prefix(5)
            .map { HabitStreakItem(habitName: $0.habit.name, currentStreak: $0.streak.value, longestStreak: $0.streak.value) }

        // 日完成趋势
        let dailyTrend = buildDailySuccessTrend(
            habits: activeHabits,
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
                previousPeriodCompletedRecordCount = calculateSuccessDays(
                    habits: activeHabits,
                    range: compStartDay...compEndExcl,
                    repo: repo
                )
            }
        }

        return HabitAnalysisContext(
            activeHabitCount: activeHabits.count,
            completedRecordCount: successDayCount,
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
    private func calculateSuccessDays(
        habits: [Habit],
        range: ClosedRange<Date>,
        repo: HabitRepository
    ) -> Int {
        habits.reduce(0) { $0 + repo.evaluatePerformance(for: $1, in: range).completedDays }
    }

    @MainActor
    private func buildDailySuccessTrend(
        habits: [Habit],
        start: Date,
        end: Date,
        calendar: Calendar,
        repo: HabitRepository
    ) -> [DailyRatePoint] {
        guard habits.count > 0 else { return [] }

        var dailyRates: [Date: Double] = [:]
        var current = start
        while current < end {
            let dayStart = calendar.startOfDay(for: current)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }

            let rate = habits.reduce(0.0) { sum, habit in
                sum + repo.evaluatePerformance(for: habit, in: dayStart...dayEnd).completionRate
            } / Double(habits.count)
            dailyRates[dayStart] = rate

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return dailyRates.sorted { $0.key < $1.key }
            .prefix(31)
            .map { date, rate in
                return DailyRatePoint(date: Self.dateFmt.string(from: date), rate: min(rate, 1.0))
            }
    }

    private func makePerformanceItem(snapshot: HabitPerformanceSnapshot, streak: Int) -> HabitPerformanceItem {
        HabitPerformanceItem(
            habitName: snapshot.habitName,
            completionRate: snapshot.completionRate,
            streak: streak,
            polarity: snapshot.polarity,
            successRule: snapshot.successRule,
            totalValue: snapshot.totalValue,
            targetValue: snapshot.targetValue,
            unit: snapshot.unit,
            controlledDays: snapshot.controlledDays,
            overLimitDays: snapshot.overLimitDays,
            completedDays: snapshot.completedDays,
            totalDays: snapshot.totalDays
        )
    }
}
