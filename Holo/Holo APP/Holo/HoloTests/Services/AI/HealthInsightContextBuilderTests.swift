//
//  HealthInsightContextBuilderTests.swift
//  HoloTests
//
//  健康洞察上下文构建器测试：跨域候选算法、evidence id 规范、数据不足、contextHash 稳定性。
//

import XCTest
@testable import Holo

final class HealthInsightContextBuilderTests: XCTestCase {

    private let now: Date = {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 12))
            ?? Date(timeIntervalSince1970: 0)
    }()
    private let cal = Calendar(identifier: .gregorian)

    // MARK: - 完整数据：跨域候选生成

    func testBuildProducesSleepCoffeeCorrelationWhenLiftMeetsThreshold() async throws {
        let result = await HealthInsightContextBuilder(dataSource: fullMock(), now: now, calendar: cal).build()

        XCTAssertTrue(result.isDataSufficient)
        XCTAssertEqual(result.period.days, 14)

        let context = try decodeContext(result.contextJSON)
        XCTAssertEqual(context.candidateCorrelations.count, 1)

        let corr = try XCTUnwrap(context.candidateCorrelations.first)
        XCTAssertEqual(corr.id, "candidate-sleep-coffee")
        XCTAssertTrue(corr.evidenceIds.contains("health-sleep-20260622"))
        XCTAssertTrue(corr.evidenceIds.contains("finance-keyword-coffee-20260622"))
        XCTAssertEqual(corr.confidenceHint, 0.75, accuracy: 0.001)

        XCTAssertEqual(context.healthSummary.lowSleepDays, 3)
        // (11 * 7.5 + 3 * 5.5) / 14 ≈ 7.07 → round1 7.1
        XCTAssertEqual(context.healthSummary.sleepAverageHours, 7.1, accuracy: 0.05)
        XCTAssertEqual(context.healthSummary.stepsGoalMetDays, 0)
    }

    // MARK: - 数据不足

    func testBuildReturnsInsufficientWhenNoSleepData() async {
        var mock = fullMock()
        mock.sleep = []

        let result = await HealthInsightContextBuilder(dataSource: mock, now: now, calendar: cal).build()

        XCTAssertFalse(result.isDataSufficient)
    }

    // MARK: - 低睡眠不达门槛：无候选，但单域睡眠 evidence 仍产出

    func testBuildOmitsCandidateWhenLowSleepBelowThreshold() async throws {
        let sleepDays: [DailyHealthData] = (14...27).map { d in
            DailyHealthData(date: makeDay(2026, 6, d), value: d == 22 ? 5.5 : 7.5)
        }
        var mock = fullMock()
        mock.sleep = sleepDays

        let result = await HealthInsightContextBuilder(dataSource: mock, now: now, calendar: cal).build()
        let context = try decodeContext(result.contextJSON)

        XCTAssertTrue(context.candidateCorrelations.isEmpty)
        XCTAssertEqual(context.healthSummary.lowSleepDays, 1)
        XCTAssertTrue(result.legalEvidenceIds.contains("health-sleep-20260622"))
    }

    // MARK: - evidence id 统一规范（4.4）

    func testEvidenceIdsFollowUnifiedSpec() async throws {
        let result = await HealthInsightContextBuilder(dataSource: fullMock(), now: now, calendar: cal).build()

        let regex = try NSRegularExpression(pattern: #"^(health-sleep|health-workout|task-completion|habit-completion|thought-count|finance-keyword-coffee)-\d{8}$"#)
        for id in result.legalEvidenceIds {
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(regex.firstMatch(in: id, range: range), "非法 evidence id：\(id)")
        }
    }

    // MARK: - contextHashInput 稳定性 + 不含逐笔 evidence（P6）

    func testContextHashInputExcludesPerDayEvidence() async {
        let result = await HealthInsightContextBuilder(dataSource: fullMock(), now: now, calendar: cal).build()

        XCTAssertFalse(result.contextHashInput.contains("20260622"))
        XCTAssertFalse(result.contextHashInput.contains("health-sleep"))
    }

    func testContextHashInputStableForSameData() async {
        let r1 = await HealthInsightContextBuilder(dataSource: fullMock(), now: now, calendar: cal).build()
        let r2 = await HealthInsightContextBuilder(dataSource: fullMock(), now: now, calendar: cal).build()

        XCTAssertEqual(r1.contextHashInput, r2.contextHashInput)
    }

    // MARK: - 同日多笔交易聚合（回归：byDay 曾用 Dictionary(uniqueKeysWithValues:)，
    //                         真实数据一天多笔 expense 时重复 key → fatalError 崩溃）

    func testBuildAggregatesMultipleTransactionsSameDayWithoutCrash() async throws {
        let sleepDays: [DailyHealthData] = (14...27).map { d in
            DailyHealthData(date: makeDay(2026, 6, d), value: (d == 22 || d == 23 || d == 24) ? 5.5 : 7.5)
        }
        let mock = MockHealthInsightDataSource(
            sleep: sleepDays,
            steps: (14...27).map { DailyHealthData(date: makeDay(2026, 6, $0), value: 5_000) },
            stand: [],
            active: [],
            finance: [
                // 6/22 同日两笔咖啡：修复前 byDay 重复 key 会 fatalError
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 22), searchableText: "瑞幸咖啡", amount: 15),
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 22), searchableText: "星巴克", amount: 20),
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 23), searchableText: "咖啡", amount: 35),
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 20), searchableText: "午餐", amount: 30)
            ]
        )

        let result = await HealthInsightContextBuilder(dataSource: mock, now: now, calendar: cal).build()

        // 6/22 咖啡支出应为当日聚合 15 + 20 = 35
        let evidence = try XCTUnwrap(result.evidence.first { $0.id == "finance-keyword-coffee-20260622" })
        let metricValue = try XCTUnwrap(evidence.metricValue)
        XCTAssertEqual(metricValue, 35, accuracy: 0.001)
    }

    // MARK: - 多域候选（P2）

    func testBuildProducesSleepTaskCorrelationWhenLowTaskOnLowSleepDays() async throws {
        let sleepDays: [DailyHealthData] = (14...27).map { d in
            DailyHealthData(date: makeDay(2026, 6, d), value: (d == 22 || d == 23 || d == 24) ? 5.5 : 7.5)
        }
        // 低睡眠日(22/23/24)待办完成 0；其余日完成 5（低待办）
        let taskDays: [HealthInsightTaskRecord] = (14...27).map { d in
            HealthInsightTaskRecord(date: makeDay(2026, 6, d), completedCount: (d == 22 || d == 23 || d == 24) ? 0 : 5)
        }
        let mock = MockHealthInsightDataSource(
            sleep: sleepDays,
            steps: (14...27).map { DailyHealthData(date: makeDay(2026, 6, $0), value: 5_000) },
            stand: [], active: [], workout: [], finance: [],
            habit: [], task: taskDays, thought: []
        )

        let result = await HealthInsightContextBuilder(dataSource: mock, now: now, calendar: cal).build()
        let context = try decodeContext(result.contextJSON)

        let taskCorr = try XCTUnwrap(context.candidateCorrelations.first { $0.id == "candidate-sleep-task" })
        XCTAssertTrue(taskCorr.evidenceIds.contains { $0.hasPrefix("task-completion-") })
        XCTAssertTrue(result.legalEvidenceIds.contains { $0.hasPrefix("task-completion-") })
    }

    func testBuildCapsCandidatesToTopFour() async throws {
        // 四个 target 域都命中：7 个低睡眠日(20-26)，各自 target 也集中在这几天
        let sleepDays: [DailyHealthData] = (14...27).map { d in
            DailyHealthData(date: makeDay(2026, 6, d), value: (d >= 20 && d <= 26) ? 5.5 : 7.5)
        }
        let taskDays: [HealthInsightTaskRecord] = (14...27).map { d in
            HealthInsightTaskRecord(date: makeDay(2026, 6, d), completedCount: (d >= 20 && d <= 26) ? 0 : 5)
        }
        let habitDays: [HealthInsightHabitRecord] = (14...27).map { d in
            HealthInsightHabitRecord(date: makeDay(2026, 6, d), completionRate: (d >= 20 && d <= 26) ? 0.1 : 0.8)
        }
        let thoughtDays: [HealthInsightThoughtRecord] = (14...27).map { d in
            HealthInsightThoughtRecord(date: makeDay(2026, 6, d), count: (d >= 20 && d <= 26) ? 3 : 0)
        }
        let financeDays: [HealthInsightFinanceRecord] = (20...26).map { d in
            HealthInsightFinanceRecord(date: makeDay(2026, 6, d), searchableText: "咖啡", amount: 20)
        }
        let mock = MockHealthInsightDataSource(
            sleep: sleepDays,
            steps: (14...27).map { DailyHealthData(date: makeDay(2026, 6, $0), value: 5_000) },
            stand: [], active: [], workout: [],
            finance: financeDays, habit: habitDays, task: taskDays, thought: thoughtDays
        )

        let result = await HealthInsightContextBuilder(dataSource: mock, now: now, calendar: cal).build()
        let context = try decodeContext(result.contextJSON)

        XCTAssertLessThanOrEqual(context.candidateCorrelations.count, 4, "候选最多 top-4")
        XCTAssertGreaterThanOrEqual(context.candidateCorrelations.count, 1, "应至少生成一个候选")
    }

    // MARK: - Helpers

    private func decodeContext(_ json: String) throws -> HealthInsightGenerationContext {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HealthInsightGenerationContext.self, from: Data(json.utf8))
    }

    private func makeDay(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: year, month: month, day: day, hour: hour))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// 14 天数据：6/22、6/23、6/24 低睡眠（5.5h），其余 7.5h；
    /// 咖啡交易命中 6/22、6/23（与低睡眠交集 2 天，lift ≈ 4.67 ≥ 1.5）。
    private func fullMock() -> MockHealthInsightDataSource {
        let sleepDays: [DailyHealthData] = (14...27).map { d in
            DailyHealthData(date: makeDay(2026, 6, d), value: (d == 22 || d == 23 || d == 24) ? 5.5 : 7.5)
        }
        let stepsDays = (14...27).map { DailyHealthData(date: makeDay(2026, 6, $0), value: 5_000) }
        return MockHealthInsightDataSource(
            sleep: sleepDays,
            steps: stepsDays,
            stand: [],
            active: [],
            finance: [
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 22), searchableText: "瑞幸咖啡", amount: 15),
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 23), searchableText: "星巴克 咖啡", amount: 35),
                HealthInsightFinanceRecord(date: makeDay(2026, 6, 20), searchableText: "午餐", amount: 30)
            ]
        )
    }
}

// MARK: - Mock DataSource

private struct MockHealthInsightDataSource: HealthInsightDataSource {
    var sleep: [DailyHealthData] = []
    var steps: [DailyHealthData] = []
    var stand: [DailyHealthData] = []
    var active: [DailyHealthData] = []
    var workout: [DailyWorkoutData] = []
    var finance: [HealthInsightFinanceRecord] = []
    var habit: [HealthInsightHabitRecord] = []
    var task: [HealthInsightTaskRecord] = []
    var thought: [HealthInsightThoughtRecord] = []

    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData] { sleep }
    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData] { steps }
    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData] { stand }
    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData] { active }
    func dailyWorkouts(from start: Date, to end: Date) async -> [DailyWorkoutData] { workout }
    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] { finance }
    func habitDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightHabitRecord] { habit }
    func taskDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightTaskRecord] { task }
    func thoughtDailyCount(from start: Date, to end: Date) async -> [HealthInsightThoughtRecord] { thought }
}
