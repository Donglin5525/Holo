//
//  HealthWorkoutTests.swift
//  HoloTests
//
//  运动会话级模型测试：会话折叠、配速换算与格式化、心率五区间分桶（含间隔封顶）、
//  最大心率估算（生日缺失回退）、模拟会话按日种子化稳定性。
//

import XCTest
import HealthKit
@testable import Holo

final class HealthWorkoutTests: XCTestCase {

    private func makeSession(
        start: Date,
        minutes: Double,
        typeName: String = "跑步",
        distanceMeters: Double? = nil,
        source: String = "Apple Watch"
    ) -> WorkoutSessionData {
        WorkoutSessionData(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(minutes * 60),
            activityTypeRaw: HKWorkoutActivityType.running.rawValue,
            typeName: typeName,
            distanceMeters: distanceMeters,
            kilocalories: 300,
            averageHeartRate: 150,
            maxHeartRate: 172,
            sourceName: source
        )
    }

    // MARK: - 会话折叠

    func testFoldSessionsAggregatesMinutesCountAndTopTypeByDuration() {
        let day = Calendar.current.startOfDay(for: Date())
        let sessions = [
            makeSession(start: day.addingTimeInterval(8 * 3600), minutes: 30, typeName: "跑步"),
            makeSession(start: day.addingTimeInterval(19 * 3600), minutes: 45, typeName: "力量训练")
        ]

        let folded = WorkoutSessionData.fold(sessions, on: day)

        XCTAssertEqual(folded.totalMinutes, 75, accuracy: 0.001)
        XCTAssertEqual(folded.sessionCount, 2)
        XCTAssertEqual(folded.topType, "力量训练", "topType 应取时长最长的类型")
    }

    func testFoldEmptySessionsProducesZeroAggregate() {
        let day = Calendar.current.startOfDay(for: Date())
        let folded = WorkoutSessionData.fold([], on: day)

        XCTAssertEqual(folded.totalMinutes, 0)
        XCTAssertEqual(folded.sessionCount, 0)
        XCTAssertNil(folded.topType)
    }

    // MARK: - 配速

    func testPaceSecondsPerKmRequiresAtLeastOneKilometer() {
        let day = Calendar.current.startOfDay(for: Date())
        // 42 分钟跑 6.8 公里 → 2520 / 6.8 ≈ 370.6 秒/公里
        let longRun = makeSession(start: day, minutes: 42, distanceMeters: 6800)
        XCTAssertEqual(longRun.paceSecondsPerKm ?? 0, 370.588, accuracy: 0.01)

        // 800 米散步不产出配速（短距离误差放大）
        let shortWalk = makeSession(start: day, minutes: 10, distanceMeters: 800)
        XCTAssertNil(shortWalk.paceSecondsPerKm)

        // 无距离运动（力量训练）不产出配速
        XCTAssertNil(makeSession(start: day, minutes: 45).paceSecondsPerKm)
    }

    func testPaceFormatterRendersMinutesAndSeconds() {
        XCTAssertEqual(WorkoutPaceFormatter.paceText(secondsPerKm: 372), "6'12\"")
        XCTAssertEqual(WorkoutPaceFormatter.paceText(secondsPerKm: 315), "5'15\"")
        XCTAssertNil(WorkoutPaceFormatter.paceText(secondsPerKm: nil))
        XCTAssertNil(WorkoutPaceFormatter.paceText(secondsPerKm: 0))
    }

    // MARK: - 心率五区间

    func testZoneIndexFollowsMaxHeartRatePercentBands() {
        let maxHeartRate: Double = 190
        // 50-60/60-70/70-80/80-90/90+ 五档边界
        XCTAssertEqual(WorkoutHeartZoneAnalyzer.zoneIndex(bpm: 100, maxHeartRate: maxHeartRate), 0)
        XCTAssertEqual(WorkoutHeartZoneAnalyzer.zoneIndex(bpm: 125, maxHeartRate: maxHeartRate), 1)
        XCTAssertEqual(WorkoutHeartZoneAnalyzer.zoneIndex(bpm: 145, maxHeartRate: maxHeartRate), 2)
        XCTAssertEqual(WorkoutHeartZoneAnalyzer.zoneIndex(bpm: 168, maxHeartRate: maxHeartRate), 3)
        XCTAssertEqual(WorkoutHeartZoneAnalyzer.zoneIndex(bpm: 180, maxHeartRate: maxHeartRate), 4)
    }

    func testZoneMinutesAttributesGapsToEarlierSampleZone() {
        let base = Date()
        // 3 分钟 Z1（100bpm）+ 2 分钟 Z4（170bpm）
        let points = [
            WorkoutHeartRatePoint(date: base, bpm: 100),
            WorkoutHeartRatePoint(date: base.addingTimeInterval(60), bpm: 100),
            WorkoutHeartRatePoint(date: base.addingTimeInterval(120), bpm: 100),
            WorkoutHeartRatePoint(date: base.addingTimeInterval(180), bpm: 170),
            WorkoutHeartRatePoint(date: base.addingTimeInterval(240), bpm: 170),
            WorkoutHeartRatePoint(date: base.addingTimeInterval(300), bpm: 170)
        ]

        let minutes = WorkoutHeartZoneAnalyzer.zoneMinutes(points: points, maxHeartRate: 190)

        XCTAssertEqual(minutes[0], 3, accuracy: 0.001, "前三个 Z1 样本间的 3 分钟应归 Z1")
        XCTAssertEqual(minutes[3], 2, accuracy: 0.001, "三个 Z4 样本间的 2 分钟应归 Z4")
        XCTAssertEqual(minutes.reduce(0, +), 5, accuracy: 0.001, "末位样本不再向后归因")
    }

    func testZoneMinutesCapsLongGapsToPreventPauseInflation() {
        let base = Date()
        // 两次记录间隔 10 分钟（典型暂停），封顶 120 秒
        let points = [
            WorkoutHeartRatePoint(date: base, bpm: 150),
            WorkoutHeartRatePoint(date: base.addingTimeInterval(600), bpm: 150)
        ]

        let minutes = WorkoutHeartZoneAnalyzer.zoneMinutes(points: points, maxHeartRate: 190)

        XCTAssertEqual(minutes[2], 2, accuracy: 0.001, "10 分钟间隔按 120 秒封顶计入")
    }

    // MARK: - 最大心率估算

    func testEstimatedMaxHeartRateUsesBirthYearAndFallsBack() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!
        let birth = DateComponents(year: 1994, month: 6, day: 1)

        let fromBirth = WorkoutHeartZoneAnalyzer.estimatedMaxHeartRate(birthComponents: birth, now: now, calendar: calendar)
        // 1994-06 出生、2026-09 已满 32 岁 → 220-32=188
        XCTAssertEqual(fromBirth.value, 188, accuracy: 0.001)
        XCTAssertFalse(fromBirth.isEstimated)

        let missing = WorkoutHeartZoneAnalyzer.estimatedMaxHeartRate(birthComponents: nil, now: now, calendar: calendar)
        XCTAssertEqual(missing.value, 190)
        XCTAssertTrue(missing.isEstimated, "生日缺失应回退 190 并标记估算")

        let toddler = WorkoutHeartZoneAnalyzer.estimatedMaxHeartRate(
            birthComponents: DateComponents(year: 2020, month: 1, day: 1), now: now, calendar: calendar
        )
        XCTAssertTrue(toddler.isEstimated, "年龄越界（<13）按估算回退")
    }

    // MARK: - 模拟数据

    func testMockWorkoutSessionsAreStableForSameDay() {
        let day = Calendar.current.startOfDay(for: Date())

        let first = HealthRepository.mockWorkoutSessions(for: day)
        let second = HealthRepository.mockWorkoutSessions(for: day)

        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.map(\.start), second.map(\.start))
        XCTAssertEqual(first.map(\.minutes), second.map(\.minutes))
    }

    func testSeededRandomGeneratorStaysInRange() {
        var rng = SeededRandomNumberGenerator(seed: 42)
        for _ in 0..<100 {
            let value = rng.next(7...20)
            XCTAssertTrue((7...20).contains(value))
        }
    }
}
