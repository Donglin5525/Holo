//
//  CrossDomainCheckupLedgerBuilderTests.swift
//  HoloTests
//
//  全景体检台账纯函数单测（2026-11-01 全景版跨域洞察）：
//  锁定同变候选预筛口径——对齐 ≥10 天、|r|≥0.35 才入选、按强度取前三；
//  习惯体检行（达标判定复用 HabitRepository.evaluatePerformance，本文件只锁
//  台账怎么「说」：每周型给周频次对周目标、测量型不说累计、负向型给累计与日均）。
//  习惯用例取自东林真实习惯形态（维生素每周 4 次 / 体重测量 / 戒烟每日上限 10 支）。
//

import XCTest
@testable import Holo

final class CrossDomainCheckupLedgerBuilderTests: XCTestCase {

    private func days(_ n: Int, _ f: (Int) -> Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: (0..<n).map { ("d\($0)", f($0)) })
    }

    private func positive(_ name: String, done: Int, total: Int = 30, value: Double? = nil, unit: String? = nil) -> HabitPerformanceSnapshot {
        HabitPerformanceSnapshot(
            habitName: name, polarity: .positive, successRule: .completeWhenDone,
            completionRate: Double(done) / Double(total), totalValue: value, targetValue: nil, unit: unit,
            controlledDays: nil, overLimitDays: nil, completedDays: done, totalDays: total
        )
    }

    func testLedgerWindows_上期紧贴本期且满窗口天数() {
        // 2026-11-01 实锤：两份台账都把上期取数上界放在上期最后一天零点（date < end 排他），
        // 上期永远少一天、环比被夸大。共用窗口后上期必须是 [baselineStart, currentStart) 满 30 天。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 2, minute: 50))!
        let w = EvidenceLedgerWindows.make(now: now, windowDays: 30, calendar: cal)
        XCTAssertEqual(w.currentStart, cal.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        XCTAssertEqual(w.currentEnd, now)
        XCTAssertEqual(w.baselineStart, cal.date(from: DateComponents(year: 2026, month: 9, day: 3)))
        XCTAssertEqual(w.baselineLastDay, cal.date(from: DateComponents(year: 2026, month: 10, day: 2)))
        XCTAssertEqual(cal.dateComponents([.day], from: w.baselineStart, to: w.currentStart).day, 30)
        // 默认 180 天财务台账同一函数、同一口径
        let long = EvidenceLedgerWindows.make(now: now, windowDays: 180, calendar: cal)
        XCTAssertEqual(cal.dateComponents([.day], from: long.baselineStart, to: long.currentStart).day, 180)
    }

    func testHabitLine_每周型给周频次对周目标不给完成率() {
        let line = CrossDomainCheckupLedgerBuilder.habitLine(HabitCheckupEntry(
            current: positive("维生素", done: 20),
            previous: positive("维生素", done: 18),
            isMeasure: false, frequency: .weekly, targetCount: 4
        ))
        XCTAssertTrue(line.hasPrefix("维生素（每周目标 4 次）："), line)
        XCTAssertTrue(line.contains("本期 完成 20/30 天，平均每周 4.7 次"), line)
        XCTAssertTrue(line.contains("上期 完成 18/30 天，平均每周 4.2 次"), line)
        XCTAssertFalse(line.contains("%"), "每周型读成完成率会把达标写成不及格：\(line)")
    }

    func testHabitLine_测量型只给测量天数与均值不说累计() {
        let line = CrossDomainCheckupLedgerBuilder.habitLine(HabitCheckupEntry(
            current: positive("体重", done: 8, value: 660.1, unit: "KG"),
            previous: positive("体重", done: 0, unit: "KG"),
            isMeasure: true, frequency: .daily, targetCount: nil
        ))
        XCTAssertEqual(line, "体重：本期 测量 8 天，均值 82.5 KG；上期 无测量记录")
        XCTAssertFalse(line.contains("累计"), "测量值相加没有意义：\(line)")
    }

    func testHabitLine_负向计数型给上限内天数累计与日均() {
        let smoking = HabitPerformanceSnapshot(
            habitName: "戒烟", polarity: .negative, successRule: .stayBelowTarget,
            completionRate: 1, totalValue: 117, targetValue: 10, unit: "支",
            controlledDays: 30, overLimitDays: 0, completedDays: 30, totalDays: 30
        )
        let line = CrossDomainCheckupLedgerBuilder.habitLine(HabitCheckupEntry(
            current: smoking, previous: nil, isMeasure: false, frequency: .daily, targetCount: nil
        ))
        XCTAssertEqual(line, "戒烟：本期 每日上限 10 支，守住 30/30 天，累计 117 支，日均 3.9 支；上期 习惯还没建立")
    }

    func testHabitLine_每日打卡型保留完成率() {
        let line = CrossDomainCheckupLedgerBuilder.habitLine(HabitCheckupEntry(
            current: positive("英语对话学习", done: 2),
            previous: positive("英语对话学习", done: 0),
            isMeasure: false, frequency: .daily, targetCount: 1
        ))
        XCTAssertEqual(line, "英语对话学习：本期 完成 2/30 天（7%）；上期 完成 0/30 天（0%）")
    }

    func testCorrelationCandidates_同向反向都能取到且方向正确() {
        var s = DailySeries()
        s.sleep = days(15) { Double($0) }
        s.spend = days(15) { Double($0) * 10 + 5 }
        s.steps = days(12) { 8000 - Double($0) * 3 } // 与前两者反向，对齐 12 天
        let c = s.correlationCandidates()
        XCTAssertEqual(c.count, 3, "三组两两组合都对齐 ≥10 天")
        // 序列顺序：每日支出、睡眠时长、步数……配对 left/right 按该顺序
        XCTAssertTrue(c.contains { $0.left == "每日支出" && $0.right == "睡眠时长" && $0.r > 0.99 && $0.strength == "强" })
        XCTAssertTrue(c.contains { $0.left == "睡眠时长" && $0.right == "步数" && $0.r < -0.99 })
        XCTAssertTrue(c.contains { $0.left == "每日支出" && $0.right == "步数" && $0.r < -0.99 })
    }

    func testCorrelationCandidates_对齐不足与弱相关都不入选() {
        var s = DailySeries()
        s.sleep = days(20) { Double($0 % 7) }
        s.spend = days(9) { Double($0) }   // 只有 9 天，对齐不足
        s.steps = days(20) { _ in 9000 }        // 零方差，无相关
        let c = s.correlationCandidates()
        XCTAssertTrue(c.isEmpty, "9 天对齐与零方差都必须被滤掉")
    }

    func testCorrelationCandidates_最多取前三() {
        var s = DailySeries()
        s.sleep = days(30) { Double($0) }
        s.spend = days(30) { Double($0) * 2 }
        s.steps = days(30) { Double($0) * 3 }
        s.thoughts = days(30) { Double($0) * 4 }
        s.tasksDone = days(30) { Double($0) * 5 } // 5 条两两全强相关 → 10 组，只取 3
        let c = s.correlationCandidates()
        XCTAssertEqual(c.count, 3)
    }
}
