//
//  HabitTodayDetailMetrics.swift
//  Holo
//
//  习惯今日详情抽屉：核心 3 列 KPI 与本地节律观察组件（纯值快照输入，不在 body 查库）。
//

import SwiftUI

// MARK: - 元信息快照（从 Habit 提取的轻量值）

struct HabitTodayDetailMeta: Equatable {
    let reminderText: String?
    let folderName: String?
    let dayEndMinutes: Int
    let createdAt: Date
}

// MARK: - KPI 单项模型

struct HabitTodayKPIMetric: Identifiable, Equatable {
    enum Tone: Equatable {
        case primary
        case accent
        case positive
        case negative
    }

    let id: String
    let label: String
    let value: String
    let unit: String
    let subtitle: String
    let valueTone: Tone
    let subtitleTone: Tone
}

// MARK: - 本地节律观察模型

struct HabitTodayRhythmModel: Equatable {
    /// 稀疏起步态（有效记录日 < 5）：不硬算统计，给温和里程碑提示
    let sparseHint: String?
    /// 常记录时段文案（如「21:30 – 23:00」）
    let timeWindowText: String?
    let timeWindowTitle: String
    /// 12 档 2 小时分布（0..24h）
    let twoHourBuckets: [Int]
    /// 工作日 vs 周末规律文案
    let patternText: String?
    let patternSubtext: String?
}

// MARK: - 汇总投影（纯函数）

struct HabitTodayDetailSummary: Equatable {
    let chips: [String]
    let kpis: [HabitTodayKPIMetric]
    let countProgress: Double?
    let rhythm: HabitTodayRhythmModel

    static func build(
        row: HabitRowSnapshot,
        meta: HabitTodayDetailMeta,
        monthSnapshot: HabitRangeSnapshot?,
        prevMonthSnapshot: HabitRangeSnapshot?,
        last30Snapshot: HabitRangeSnapshot?,
        allTimeSnapshot: HabitRangeSnapshot?,
        today: Date,
        calendar: Calendar = .current
    ) -> HabitTodayDetailSummary {
        let chips = buildChips(row: row, meta: meta)
        let kpis = buildKPIs(
            row: row,
            meta: meta,
            monthSnapshot: monthSnapshot,
            prevMonthSnapshot: prevMonthSnapshot,
            last30Snapshot: last30Snapshot,
            allTimeSnapshot: allTimeSnapshot,
            today: today,
            calendar: calendar
        )
        let progress: Double? = {
            guard row.kind == .count,
                  let target = row.target?.value, target > 0 else { return nil }
            let val = row.today.todayValue ?? 0
            return min(max(val / target, 0), 1)
        }()
        let rhythm = buildRhythm(
            row: row,
            meta: meta,
            allTimeSnapshot: allTimeSnapshot,
            today: today,
            calendar: calendar
        )
        return HabitTodayDetailSummary(
            chips: chips,
            kpis: kpis,
            countProgress: progress,
            rhythm: rhythm
        )
    }

    // MARK: 规则胶囊

    private static func buildChips(row: HabitRowSnapshot, meta: HabitTodayDetailMeta) -> [String] {
        var result: [String] = []
        if row.isBadHabit {
            result.append(String(localized: "想减少的事"))
        } else {
            let freqLabel: String = {
                switch row.frequency {
                case .daily: return String(localized: "每日")
                case .weekly: return String(localized: "每周")
                case .monthly: return String(localized: "每月")
                }
            }()
            let kindLabel: String = {
                switch row.kind {
                case .checkIn: return String(localized: "打卡")
                case .count: return String(localized: "计数")
                case .measure: return String(localized: "测量")
                }
            }()
            result.append("\(freqLabel)\(kindLabel)")
        }

        if let target = row.target {
            if let value = target.value, value > 0 {
                let formatted = HabitPresentationProjector.formatValue(value)
                let unit = (target.unit ?? row.unit).trimmingCharacters(in: .whitespaces)
                let suffix = unit.isEmpty ? "" : " \(unit)"
                let prefix = target.isControlTarget ? String(localized: "上限") : String(localized: "目标")
                result.append("\(prefix) \(formatted)\(suffix)")
            } else if let count = target.count, count > 0, row.frequency != .daily {
                result.append(String(localized: "目标 \(count) 次"))
            }
        }

        if let reminder = meta.reminderText {
            result.append(String(localized: "提醒 \(reminder)"))
        }

        if let folderName = meta.folderName, !folderName.isEmpty {
            result.append(folderName)
        }

        return Array(result.prefix(3))
    }

    // MARK: 3 列 KPI

    private static func buildKPIs(
        row: HabitRowSnapshot,
        meta: HabitTodayDetailMeta,
        monthSnapshot: HabitRangeSnapshot?,
        prevMonthSnapshot: HabitRangeSnapshot?,
        last30Snapshot: HabitRangeSnapshot?,
        allTimeSnapshot: HabitRangeSnapshot?,
        today: Date,
        calendar: Calendar
    ) -> [HabitTodayKPIMetric] {
        let creationDay = allTimeSnapshot?.creationDay(calendar: calendar)
            ?? HabitDayAttribution.attributedDay(meta.createdAt, dayEndMinutes: meta.dayEndMinutes, calendar: calendar)
        let daysSinceCreation = max((calendar.dateComponents([.day], from: creationDay, to: today).day ?? 0) + 1, 1)
        let isSparse = daysSinceCreation <= 7 || (allTimeSnapshot?.recordedDayCount ?? 0) <= 3

        switch row.kind {
        case .checkIn:
            if row.isBadHabit {
                return buildBadCheckInKPIs(
                    row: row,
                    monthSnapshot: monthSnapshot,
                    prevMonthSnapshot: prevMonthSnapshot,
                    last30Snapshot: last30Snapshot,
                    allTimeSnapshot: allTimeSnapshot,
                    creationDay: creationDay,
                    today: today,
                    calendar: calendar
                )
            }
            return buildGoodCheckInKPIs(
                row: row,
                monthSnapshot: monthSnapshot,
                prevMonthSnapshot: prevMonthSnapshot,
                allTimeSnapshot: allTimeSnapshot,
                creationDay: creationDay,
                daysSinceCreation: daysSinceCreation,
                isSparse: isSparse,
                calendar: calendar
            )

        case .count:
            return buildCountKPIs(
                row: row,
                monthSnapshot: monthSnapshot,
                prevMonthSnapshot: prevMonthSnapshot,
                allTimeSnapshot: allTimeSnapshot
            )

        case .measure:
            return buildMeasureKPIs(
                row: row,
                allTimeSnapshot: allTimeSnapshot
            )
        }
    }

    private static func buildGoodCheckInKPIs(
        row: HabitRowSnapshot,
        monthSnapshot: HabitRangeSnapshot?,
        prevMonthSnapshot: HabitRangeSnapshot?,
        allTimeSnapshot: HabitRangeSnapshot?,
        creationDay: Date,
        daysSinceCreation: Int,
        isSparse: Bool,
        calendar: Calendar
    ) -> [HabitTodayKPIMetric] {
        let currentStreak = row.streak?.value ?? 0
        let streakUnit = row.streak?.unitName ?? String(localized: "天")
        let bestStreak = max(currentStreak, computeBestCheckInStreak(allTimeSnapshot, calendar: calendar))

        let monthDone = monthSnapshot?.recordedDayCount ?? 0
        let monthElapsed = max(monthSnapshot?.elapsedDays ?? 1, 1)
        let monthRate = Int((Double(monthDone) / Double(monthElapsed) * 100).rounded())

        let monthSub: String
        let monthSubTone: HabitTodayKPIMetric.Tone
        if isSparse {
            monthSub = String(localized: "创建第 \(daysSinceCreation) 天")
            monthSubTone = .primary
        } else if let prev = prevMonthSnapshot, prev.elapsedDays >= 5 {
            let prevRate = Int((Double(prev.recordedDayCount) / Double(max(prev.elapsedDays, 1)) * 100).rounded())
            let diff = monthRate - prevRate
            if diff > 0 {
                monthSub = "\(monthRate)% · ↑\(diff)%"
                monthSubTone = .positive
            } else if diff < 0 {
                monthSub = "\(monthRate)% · ↓\(abs(diff))%"
                monthSubTone = .primary
            } else {
                monthSub = String(localized: "\(monthRate)% · 持平")
                monthSubTone = .primary
            }
        } else {
            monthSub = String(localized: "完成率 \(monthRate)%")
            monthSubTone = .primary
        }

        let totalDays = allTimeSnapshot?.recordedDayCount ?? 0
        let sinceText = String(localized: "始于 \(shortDate(creationDay))")

        return [
            HabitTodayKPIMetric(
                id: "streak",
                label: String(localized: "当前连续"),
                value: "\(currentStreak)",
                unit: streakUnit,
                subtitle: isSparse ? String(localized: "正在起步") : String(localized: "最长 \(bestStreak) 天"),
                valueTone: .accent,
                subtitleTone: .primary
            ),
            HabitTodayKPIMetric(
                id: "month",
                label: isSparse ? String(localized: "创建至今") : String(localized: "本月完成"),
                value: "\(monthDone)",
                unit: "/\(monthElapsed)天",
                subtitle: monthSub,
                valueTone: .primary,
                subtitleTone: monthSubTone
            ),
            HabitTodayKPIMetric(
                id: "total",
                label: String(localized: "累计坚持"),
                value: "\(totalDays)",
                unit: String(localized: "天"),
                subtitle: sinceText,
                valueTone: .primary,
                subtitleTone: .primary
            )
        ]
    }

    private static func buildBadCheckInKPIs(
        row: HabitRowSnapshot,
        monthSnapshot: HabitRangeSnapshot?,
        prevMonthSnapshot: HabitRangeSnapshot?,
        last30Snapshot: HabitRangeSnapshot?,
        allTimeSnapshot: HabitRangeSnapshot?,
        creationDay: Date,
        today: Date,
        calendar: Calendar
    ) -> [HabitTodayKPIMetric] {
        let occurredDays = allTimeSnapshot?.recordedDays ?? []
        let cleanStreak = computeCleanStreak(occurredDays: occurredDays, creationDay: creationDay, today: today, calendar: calendar)
        let bestClean = max(cleanStreak, computeBestCleanStreak(occurredDays: occurredDays, creationDay: creationDay, today: today, calendar: calendar))

        let monthOccurred = monthSnapshot?.recordedDayCount ?? 0
        let prevOccurred = prevMonthSnapshot?.recordedDayCount ?? 0
        let monthSub: String
        let monthSubTone: HabitTodayKPIMetric.Tone
        if prevOccurred > 0 {
            let diffPct = Int(((Double(monthOccurred - prevOccurred) / Double(prevOccurred)) * 100).rounded())
            if diffPct < 0 {
                monthSub = String(localized: "↓\(abs(diffPct))% 较上月")
                monthSubTone = .positive
            } else if diffPct > 0 {
                monthSub = String(localized: "↑\(diffPct)% 较上月")
                monthSubTone = .negative
            } else {
                monthSub = String(localized: "与上月持平")
                monthSubTone = .primary
            }
        } else {
            monthSub = String(localized: "本月至今")
            monthSubTone = .primary
        }

        let elapsed30 = max(last30Snapshot?.elapsedDays ?? 1, 1)
        let occurred30 = last30Snapshot?.recordedDayCount ?? 0
        let cleanRate = max(0, Int((Double(elapsed30 - occurred30) / Double(elapsed30) * 100).rounded()))

        return [
            HabitTodayKPIMetric(
                id: "clean-streak",
                label: String(localized: "已连续克制"),
                value: "\(cleanStreak)",
                unit: String(localized: "天"),
                subtitle: String(localized: "最长 \(bestClean) 天"),
                valueTone: cleanStreak > 0 ? .positive : .primary,
                subtitleTone: .primary
            ),
            HabitTodayKPIMetric(
                id: "month-occur",
                label: String(localized: "本月发生"),
                value: "\(monthOccurred)",
                unit: String(localized: "次"),
                subtitle: monthSub,
                valueTone: .primary,
                subtitleTone: monthSubTone
            ),
            HabitTodayKPIMetric(
                id: "restraint-rate",
                label: String(localized: "克制率"),
                value: "\(cleanRate)%",
                unit: "",
                subtitle: String(localized: "近 \(elapsed30) 天"),
                valueTone: .primary,
                subtitleTone: .primary
            )
        ]
    }

    private static func buildCountKPIs(
        row: HabitRowSnapshot,
        monthSnapshot: HabitRangeSnapshot?,
        prevMonthSnapshot: HabitRangeSnapshot?,
        allTimeSnapshot: HabitRangeSnapshot?
    ) -> [HabitTodayKPIMetric] {
        let unit = row.unit
        let todayVal = row.today.todayValue ?? 0
        let todayFormatted = HabitPresentationProjector.formatValue(todayVal)

        let todayUnit: String
        let todaySub: String
        let todaySubTone: HabitTodayKPIMetric.Tone
        if let target = row.target?.value, target > 0 {
            let targetText = HabitPresentationProjector.formatValue(target)
            todayUnit = "/\(targetText)\(unit)"
            if todayVal >= target {
                todaySub = String(localized: "今日已达标")
                todaySubTone = .positive
            } else {
                let remain = HabitPresentationProjector.formatValue(target - todayVal)
                todaySub = String(localized: "还差 \(remain) \(unit)")
                todaySubTone = .primary
            }
        } else {
            todayUnit = unit
            todaySub = row.today.isRecorded ? String(localized: "今日已记录") : String(localized: "今日未记录")
            todaySubTone = .primary
        }

        let monthValues = monthSnapshot?.dailyValues ?? []
        let monthTotal = monthSnapshot?.countTotal ?? 0
        let recordedDays = max(monthValues.count, 1)
        let avg = monthValues.isEmpty ? 0 : monthTotal / Double(recordedDays)
        let avgText = monthValues.isEmpty ? "—" : HabitPresentationProjector.formatValue(avg)

        let avgSub: String
        if let target = row.target?.value, target > 0, !monthValues.isEmpty {
            let metDays = monthValues.filter { $0.value >= target }.count
            avgSub = String(localized: "达标 \(metDays) 天")
        } else {
            avgSub = String(localized: "记录 \(monthValues.count) 天")
        }

        let totalText = HabitPresentationProjector.formatValue(monthTotal)
        let totalSub: String
        let totalSubTone: HabitTodayKPIMetric.Tone
        if let prevTotal = prevMonthSnapshot?.countTotal, prevTotal > 0, monthTotal > 0 {
            let pct = Int(((monthTotal - prevTotal) / prevTotal * 100).rounded())
            if pct > 0 {
                totalSub = String(localized: "↑\(pct)% 较上月")
                totalSubTone = .positive
            } else if pct < 0 {
                totalSub = String(localized: "↓\(abs(pct))% 较上月")
                totalSubTone = .primary
            } else {
                totalSub = String(localized: "与上月持平")
                totalSubTone = .primary
            }
        } else {
            let allDays = allTimeSnapshot?.recordedDayCount ?? 0
            totalSub = String(localized: "累计 \(allDays) 天")
            totalSubTone = .primary
        }

        return [
            HabitTodayKPIMetric(
                id: "today",
                label: String(localized: "今日进度"),
                value: todayFormatted,
                unit: todayUnit,
                subtitle: todaySub,
                valueTone: .accent,
                subtitleTone: todaySubTone
            ),
            HabitTodayKPIMetric(
                id: "avg",
                label: String(localized: "本月日均"),
                value: avgText,
                unit: monthValues.isEmpty ? "" : unit,
                subtitle: avgSub,
                valueTone: .primary,
                subtitleTone: .primary
            ),
            HabitTodayKPIMetric(
                id: "month-total",
                label: String(localized: "本月累计"),
                value: totalText,
                unit: unit,
                subtitle: totalSub,
                valueTone: .primary,
                subtitleTone: totalSubTone
            )
        ]
    }

    private static func buildMeasureKPIs(
        row: HabitRowSnapshot,
        allTimeSnapshot: HabitRangeSnapshot?
    ) -> [HabitTodayKPIMetric] {
        let unit = row.unit
        let validRecords: [(date: Date, value: Double)] = (allTimeSnapshot?.records ?? [])
            .compactMap { fact in
                fact.finiteValue.map { (date: fact.recordedAt, value: $0) }
            }
            .sorted { $0.date < $1.date }
        let recent = Array(validRecords.suffix(10))

        guard let latest = recent.last else {
            return []
        }

        let latestText = HabitPresentationProjector.formatValue(latest.value)
        if recent.count == 1 {
            // 单条记录态：不重复三列相同数字，给有区分度的 3 项真实信息
            let targetSub: String
            let targetVal: String
            if let target = row.target?.value {
                let gap = latest.value - target
                let sign = gap > 0 ? "+" : ""
                targetVal = "\(sign)\(HabitPresentationProjector.formatValue(gap))"
                targetSub = String(localized: "目标 \(HabitPresentationProjector.formatValue(target))")
            } else {
                targetVal = shortDate(latest.date)
                targetSub = String(localized: "首次记录")
            }
            return [
                HabitTodayKPIMetric(
                    id: "latest",
                    label: String(localized: "最新记录"),
                    value: latestText,
                    unit: unit,
                    subtitle: shortDate(latest.date),
                    valueTone: .accent,
                    subtitleTone: .primary
                ),
                HabitTodayKPIMetric(
                    id: "count",
                    label: String(localized: "累计记录"),
                    value: "1",
                    unit: String(localized: "次"),
                    subtitle: String(localized: "再记一次看变化"),
                    valueTone: .primary,
                    subtitleTone: .primary
                ),
                HabitTodayKPIMetric(
                    id: "anchor",
                    label: row.target?.value != nil ? String(localized: "距目标") : String(localized: "起始日期"),
                    value: targetVal,
                    unit: row.target?.value != nil ? unit : "",
                    subtitle: targetSub,
                    valueTone: .primary,
                    subtitleTone: .primary
                )
            ]
        }

        let prev = recent[recent.count - 2]
        let diff = latest.value - prev.value
        let sign = diff > 0 ? "+" : ""
        let latestSub = String(localized: "较上次 \(sign)\(HabitPresentationProjector.formatValue(diff))")

        let avg = recent.map(\.value).reduce(0, +) / Double(recent.count)
        let avgText = HabitPresentationProjector.formatValue(avg)
        let avgSub: String
        if let target = row.target?.value {
            let gap = latest.value - target
            let gapSign = gap > 0 ? "+" : ""
            avgSub = String(localized: "距目标 \(gapSign)\(HabitPresentationProjector.formatValue(gap))")
        } else {
            avgSub = String(localized: "近 \(recent.count) 次均值")
        }

        let minV = recent.map(\.value).min() ?? latest.value
        let maxV = recent.map(\.value).max() ?? latest.value
        let rangeText = minV == maxV
            ? HabitPresentationProjector.formatValue(minV)
            : "\(HabitPresentationProjector.formatValue(minV))–\(HabitPresentationProjector.formatValue(maxV))"

        return [
            HabitTodayKPIMetric(
                id: "latest",
                label: String(localized: "最新记录"),
                value: latestText,
                unit: unit,
                subtitle: latestSub,
                valueTone: .accent,
                subtitleTone: .primary
            ),
            HabitTodayKPIMetric(
                id: "avg",
                label: String(localized: "近期均值"),
                value: avgText,
                unit: unit,
                subtitle: avgSub,
                valueTone: .primary,
                subtitleTone: .primary
            ),
            HabitTodayKPIMetric(
                id: "range",
                label: String(localized: "区间范围"),
                value: rangeText,
                unit: "",
                subtitle: String(localized: "共 \(validRecords.count) 次记录"),
                valueTone: .primary,
                subtitleTone: .primary
            )
        ]
    }

    // MARK: 本地节律观察

    private static func buildRhythm(
        row: HabitRowSnapshot,
        meta: HabitTodayDetailMeta,
        allTimeSnapshot: HabitRangeSnapshot?,
        today: Date,
        calendar: Calendar
    ) -> HabitTodayRhythmModel {
        let creationDay = allTimeSnapshot?.creationDay(calendar: calendar)
            ?? HabitDayAttribution.attributedDay(meta.createdAt, dayEndMinutes: meta.dayEndMinutes, calendar: calendar)
        let daysSinceCreation = max((calendar.dateComponents([.day], from: creationDay, to: today).day ?? 0) + 1, 1)

        let validFacts: [HabitRecordFact] = (allTimeSnapshot?.records ?? []).filter { fact in
            row.kind == .checkIn ? fact.isCompleted : fact.finiteValue != nil
        }
        let recordedDayCount = allTimeSnapshot?.recordedDayCount ?? 0

        // 稀疏态保护（< 5 个记录日）：不硬算百分比，给温和起步提示
        if recordedDayCount < 5 {
            let hint: String
            if recordedDayCount == 0 {
                hint = String(localized: "记录满 5 天后，这里会自动总结你的习惯时段与周内节律。")
            } else if !row.isBadHabit, let streak = row.streak, streak.value > 0, streak.value < 3 {
                hint = String(localized: "刚起步第 \(daysSinceCreation) 天 · 再坚持 \(3 - streak.value) 天达成「连续 3 天」小里程碑")
            } else {
                hint = String(localized: "已记录 \(recordedDayCount) 天 · 满 5 天后解锁你的常记录时段与周内规律")
            }
            return HabitTodayRhythmModel(
                sparseHint: hint,
                timeWindowText: nil,
                timeWindowTitle: "",
                twoHourBuckets: [],
                patternText: nil,
                patternSubtext: nil
            )
        }

        // 12 档 2 小时时间分布（按真实 recordedAt）
        var buckets = Array(repeating: 0, count: 12)
        for fact in validFacts {
            let hour = calendar.component(.hour, from: fact.recordedAt)
            let idx = min(max(hour / 2, 0), 11)
            buckets[idx] += 1
        }
        let peakIdx = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) ?? 0
        let startHour = peakIdx * 2
        let endHour = (startHour + 2) % 24
        let windowText = String(format: "%02d:00 – %02d:00", startHour, endHour)

        // 工作日 vs 周末规律（基于最近 30 天内有效日）
        let pattern = buildWeekdayPattern(
            row: row,
            allTimeSnapshot: allTimeSnapshot,
            creationDay: creationDay,
            today: today,
            calendar: calendar
        )

        return HabitTodayRhythmModel(
            sparseHint: nil,
            timeWindowText: windowText,
            timeWindowTitle: row.isBadHabit ? String(localized: "高发时段") : String(localized: "常记录时段"),
            twoHourBuckets: buckets,
            patternText: pattern.main,
            patternSubtext: pattern.sub
        )
    }

    private static func buildWeekdayPattern(
        row: HabitRowSnapshot,
        allTimeSnapshot: HabitRangeSnapshot?,
        creationDay: Date,
        today: Date,
        calendar: Calendar
    ) -> (main: String, sub: String) {
        let start30 = max(creationDay, calendar.date(byAdding: .day, value: -29, to: today) ?? today)
        let recordedDays = allTimeSnapshot?.recordedDays ?? []

        if row.kind == .measure {
            let values = allTimeSnapshot?.dailyValues ?? []
            if values.count >= 2, let first = values.first, let last = values.last {
                let spanDays = max(calendar.dateComponents([.day], from: first.date, to: last.date).day ?? 1, 1)
                let avgGap = Double(spanDays) / Double(values.count - 1)
                let gapText = HabitPresentationProjector.formatValue(avgGap)
                let diff = last.value - first.value
                let sign = diff > 0 ? "+" : ""
                let sub = String(localized: "累计变化 \(sign)\(HabitPresentationProjector.formatValue(diff)) \(row.unit)")
                return (String(localized: "约每 \(gapText) 天测一次"), sub)
            }
            return (String(localized: "已记录 \(values.count) 次"), String(localized: "继续保持定期记录"))
        }

        if row.kind == .count {
            let recentValues = (allTimeSnapshot?.dailyValues ?? []).filter { $0.date >= start30 }
            var wdVals: [Double] = []
            var weVals: [Double] = []
            for item in recentValues {
                let wd = calendar.component(.weekday, from: item.date)
                if wd == 1 || wd == 7 { weVals.append(item.value) } else { wdVals.append(item.value) }
            }
            let wdAvg = wdVals.isEmpty ? 0 : wdVals.reduce(0, +) / Double(wdVals.count)
            let weAvg = weVals.isEmpty ? 0 : weVals.reduce(0, +) / Double(weVals.count)
            let main = String(localized: "工作日 \(HabitPresentationProjector.formatValue(wdAvg)) · 周末 \(HabitPresentationProjector.formatValue(weAvg))")
            let sub: String = {
                if weVals.isEmpty { return String(localized: "近 30 天主要在工作日记录") }
                if wdAvg > weAvg * 1.15 { return String(localized: "工作日完成量更稳") }
                if weAvg > wdAvg * 1.15 { return String(localized: "周末投入更多") }
                return String(localized: "工作日与周末节奏均衡")
            }()
            return (main, sub)
        }

        // Check-in (good / bad)
        var wdTotal = 0, wdHit = 0, weTotal = 0, weHit = 0
        var cursor = start30
        while cursor <= today {
            let wd = calendar.component(.weekday, from: cursor)
            let hit = recordedDays.contains(cursor)
            if wd == 1 || wd == 7 {
                weTotal += 1
                if hit { weHit += 1 }
            } else {
                wdTotal += 1
                if hit { wdHit += 1 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        if row.isBadHabit {
            let main = String(localized: "工作日 \(wdHit) 次 · 周末 \(weHit) 次")
            let sub = weHit > wdHit
                ? String(localized: "周末相对更容易发生")
                : (wdHit > weHit ? String(localized: "工作日发生更集中") : String(localized: "近 30 天分布平稳"))
            return (main, sub)
        }

        let wdRate = wdTotal > 0 ? Int((Double(wdHit) / Double(wdTotal) * 100).rounded()) : 0
        let weRate = weTotal > 0 ? Int((Double(weHit) / Double(weTotal) * 100).rounded()) : 0
        let main = String(localized: "工作日 \(wdRate)% · 周末 \(weRate)%")
        let sub: String = {
            if wdRate >= weRate + 15 { return String(localized: "工作日更稳定，周末容易漏卡") }
            if weRate >= wdRate + 15 { return String(localized: "周末完成率更高") }
            return String(localized: "全周节奏比较均匀")
        }()
        return (main, sub)
    }

    // MARK: 连续计算辅助

    private static func computeBestCheckInStreak(_ snapshot: HabitRangeSnapshot?, calendar: Calendar) -> Int {
        guard let days = snapshot?.recordedDays, !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1
        var current = 1
        for idx in 1..<sorted.count {
            let diff = calendar.dateComponents([.day], from: sorted[idx - 1], to: sorted[idx]).day ?? 0
            if diff == 1 {
                current += 1
                best = max(best, current)
            } else if diff > 1 {
                current = 1
            }
        }
        return best
    }

    private static func computeCleanStreak(
        occurredDays: Set<Date>,
        creationDay: Date,
        today: Date,
        calendar: Calendar
    ) -> Int {
        var count = 0
        var cursor = today
        while cursor >= creationDay {
            if occurredDays.contains(cursor) { break }
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    private static func computeBestCleanStreak(
        occurredDays: Set<Date>,
        creationDay: Date,
        today: Date,
        calendar: Calendar
    ) -> Int {
        var best = 0
        var current = 0
        var cursor = creationDay
        while cursor <= today {
            if occurredDays.contains(cursor) {
                current = 0
            } else {
                current += 1
                best = max(best, current)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return best
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter.string(from: date)
    }
}

// MARK: - 3 列 KPI 卡片（叶子组件）

struct HabitTodayKPICard: View {
    let kpis: [HabitTodayKPIMetric]
    let accent: Color
    let countProgress: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(kpis.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.holoToolBorder.opacity(0.75))
                            .frame(width: 0.5)
                            .padding(.vertical, 6)
                    }
                    kpiColumn(item)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, HoloSpacing.xs)

            if let progress = countProgress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.holoToolInset)
                        Capsule()
                            .fill(accent)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 14)
                .padding(.bottom, 13)
                .animation(HoloAnimation.standard, value: progress)
            }
        }
        .holoSurface(.independent)
    }

    private func kpiColumn(_ item: HabitTodayKPIMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label)
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.value)
                    .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(toneColor(item.valueTone))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !item.unit.isEmpty {
                    Text(item.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Text(item.subtitle)
                .font(.system(size: 11, weight: item.subtitleTone == .primary ? .regular : .medium))
                .foregroundStyle(subtitleColor(item.subtitleTone))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private func toneColor(_ tone: HabitTodayKPIMetric.Tone) -> Color {
        switch tone {
        case .primary: return .holoToolText
        case .accent: return accent
        case .positive: return .holoToolSuccess
        case .negative: return .holoToolError
        }
    }

    private func subtitleColor(_ tone: HabitTodayKPIMetric.Tone) -> Color {
        switch tone {
        case .primary: return .holoToolTextSecondary
        case .accent: return accent
        case .positive: return .holoToolSuccess
        case .negative: return .holoToolError
        }
    }
}

// MARK: - 本地节律观察条（叶子组件）

struct HabitTodayRhythmStrip: View {
    let model: HabitTodayRhythmModel
    let accent: Color

    var body: some View {
        Group {
            if let hint = model.sparseHint {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "起步阶段"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Text(hint)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    if let windowText = model.timeWindowText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.timeWindowTitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.holoToolTextSecondary)
                            Text(windowText)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.holoToolText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            sparkBars
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Rectangle()
                        .fill(Color.holoToolBorder.opacity(0.75))
                        .frame(width: 0.5)
                        .padding(.vertical, 2)

                    if let patternText = model.patternText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "节律观察"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.holoToolTextSecondary)
                            Text(patternText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.holoToolText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if let sub = model.patternSubtext {
                                Text(sub)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.holoToolTextSecondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(Color.holoToolInset.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .strokeBorder(Color.holoToolBorder.opacity(0.7), lineWidth: 0.5)
        )
    }

    private var sparkBars: some View {
        let maxVal = max(model.twoHourBuckets.max() ?? 1, 1)
        return VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(model.twoHourBuckets.indices, id: \.self) { idx in
                    let count = model.twoHourBuckets[idx]
                    let ratio = CGFloat(count) / CGFloat(maxVal)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent.opacity(count == 0 ? 0.14 : (0.35 + Double(ratio) * 0.65)))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2.5, ratio * 15))
                }
            }
            .frame(height: 16, alignment: .bottom)

            HStack {
                Text("0h")
                Spacer()
                Text("12h")
                Spacer()
                Text("24h")
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(Color.holoToolTextSecondary.opacity(0.75))
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}
