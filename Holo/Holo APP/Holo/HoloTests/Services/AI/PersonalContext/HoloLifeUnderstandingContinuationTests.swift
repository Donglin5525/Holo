//
//  HoloLifeUnderstandingContinuationTests.swift
//  HoloTests
//
//  R4 Matter 延续门禁测试（方案 2026-09-23 §5.1.1 A09—A14/A19）：
//    A09 频次未知 → 覆盖待核实（不标 covered）；
//    A10 明确 1/2/3 每天喂食换水 → 只认前三天，提示 4—7 日；
//    A11 朋友尚未回复（asked）→ 不标已安排；
//    A12 1—7 日每天都有明确安排 → covered → skip（不添重复任务）；
//    A14 行程改期 → requirementKey 变化（旧提案失效）；
//    A19 增量接受中途失败/重试 → 同 proposalKey 幂等，只生效一次。
//
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloLifeUnderstandingContinuationTests.main()
    }
}
#endif

struct HoloLifeUnderstandingContinuationTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    static func day(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: string)!
    }

    /// 主旅程需求：10-01…10-07 宠物照护（喂食/换水）。
    static var petCareRequirement: HoloLifeSituationRequirement {
        let start = day("2026-10-01")
        let end = day("2026-10-08")
        return HoloLifeSituationRequirement(
            requirementKey: HoloLifeSituationRequirement.stableKey(
                responsibilityStatement: "用户可能存在宠物照料责任",
                situationType: "离家旅行",
                intervalStart: start,
                intervalEnd: end,
                dutyItems: ["喂食", "换水"]
            ),
            relationContextIDs: ["ctx-petcare"],
            intervalStart: start,
            intervalEnd: end,
            dutyItems: ["喂食", "换水"],
            evidenceRefs: ["ev-1"]
        )
    }

    static func main() async throws {
        testA09UnknownFrequencyStaysPartial()
        testA10FirstThreeDaysCoveredOnly()
        testA11AskedIsNotCommitted()
        testA12FullCoverageMapsToSkip()
        testA14IntervalChangeChangesRequirementKey()
        testA19ProposalIdempotency()
        print("HoloLifeUnderstandingContinuationTests: \(assertionCount) 断言全部通过")
    }

    // MARK: A09 频次未知 → 待核实

    static func testA09UnknownFrequencyStaysPartial() {
        let assessment = HoloLifeArrangementCoverageCalculator.assess(
            requirement: petCareRequirement,
            claims: [
                HoloLifeArrangementClaim(
                    startDay: day("2026-10-01"),
                    endDayInclusive: day("2026-10-03"),
                    dutyItems: ["喂食", "换水"],
                    frequency: .unknown,
                    executor: "朋友",
                    commitment: .committed
                ),
            ],
            calendar: calendar
        )
        expect(assessment.status == .partial, "A09：频次未知不得标 covered（实际 \(assessment.status.rawValue)）")
        expect(
            assessment.pendingVerificationText?.contains("还需确认") == true,
            "A09：待核实文案（实际：\(assessment.pendingVerificationText ?? "无")）"
        )
        expect(
            assessment.unknownDimensions.contains { $0.contains("频次未知") },
            "A09：频次维度记录为未知"
        )
    }

    // MARK: A10 只认前三天

    static func testA10FirstThreeDaysCoveredOnly() {
        let assessment = HoloLifeArrangementCoverageCalculator.assess(
            requirement: petCareRequirement,
            claims: [
                HoloLifeArrangementClaim(
                    startDay: day("2026-10-01"),
                    endDayInclusive: day("2026-10-03"),
                    dutyItems: ["喂食", "换水"],
                    frequency: .daily,
                    executor: "朋友",
                    commitment: .committed
                ),
            ],
            calendar: calendar
        )
        expect(assessment.status == .partial, "A10：前三天覆盖 + 4—7 缺口 → partial")
        expect(assessment.coveredDayCount == 3, "A10：只认 3 天（实际 \(assessment.coveredDayCount)）")
        if let firstCovered = assessment.coveredDays.first {
            expect(
                calendar.isDate(firstCovered, equalTo: day("2026-10-01"), toGranularity: .day),
                "A10：覆盖从 10-01 起（实际 \(firstCovered)）"
            )
        } else {
            expect(false, "A10：应存在覆盖日")
        }
        expect(
            HoloLifeEffectMapper.effectKind(for: assessment.status) == "adjust",
            "A10：partial → adjust（调整核实 4—7 日）"
        )
    }

    // MARK: A11 asked ≠ committed

    static func testA11AskedIsNotCommitted() {
        let assessment = HoloLifeArrangementCoverageCalculator.assess(
            requirement: petCareRequirement,
            claims: [
                HoloLifeArrangementClaim(
                    startDay: day("2026-10-01"),
                    endDayInclusive: day("2026-10-07"),
                    dutyItems: ["喂食", "换水"],
                    frequency: .daily,
                    executor: "朋友",
                    commitment: .asked
                ),
            ],
            calendar: calendar
        )
        expect(assessment.status == .unknown, "A11：问了没回复不标已安排（实际 \(assessment.status.rawValue)）")
        expect(assessment.coveredDays.isEmpty, "A11：无覆盖日")
    }

    // MARK: A12 全覆盖 → skip

    static func testA12FullCoverageMapsToSkip() {
        let assessment = HoloLifeArrangementCoverageCalculator.assess(
            requirement: petCareRequirement,
            claims: [
                HoloLifeArrangementClaim(
                    startDay: day("2026-10-01"),
                    endDayInclusive: day("2026-10-07"),
                    dutyItems: ["喂食", "换水"],
                    frequency: .daily,
                    executor: "朋友",
                    commitment: .committed
                ),
            ],
            calendar: calendar
        )
        expect(assessment.status == .covered, "A12：1—7 每天明确安排 → covered")
        expect(assessment.coveredDayCount == 7, "A12：7 天全覆盖")
        expect(
            HoloLifeEffectMapper.effectKind(for: assessment.status) == "skip",
            "A12：covered → skip（不添重复照护任务）"
        )
    }

    // MARK: A14 行程变化 → requirementKey 变化

    static func testA14IntervalChangeChangesRequirementKey() {
        let original = HoloLifeSituationRequirement.stableKey(
            responsibilityStatement: "用户可能存在宠物照料责任",
            situationType: "离家旅行",
            intervalStart: day("2026-10-01"),
            intervalEnd: day("2026-10-08"),
            dutyItems: ["喂食", "换水"]
        )
        let rescheduled = HoloLifeSituationRequirement.stableKey(
            responsibilityStatement: "用户可能存在宠物照料责任",
            situationType: "离家旅行",
            intervalStart: day("2026-11-05"),
            intervalEnd: day("2026-11-12"),
            dutyItems: ["喂食", "换水"]
        )
        expect(original != rescheduled, "A14：行程改期产生新 requirementKey（旧提案失效）")
        // 自然语言标题变体不改变键（「猫的事」=「照顾宠物」按归一化命题处理）。
        let variantWording = HoloLifeSituationRequirement.stableKey(
            responsibilityStatement: "用户可能存在宠物照料责任",  // 同命题
            situationType: "离家旅行",
            intervalStart: day("2026-10-01"),
            intervalEnd: day("2026-10-08"),
            dutyItems: ["换水", "喂食"]  // 事项顺序不同
        )
        expect(original == variantWording, "A14：事项顺序变化不改变键（同逻辑需求）")
    }

    // MARK: A19 提案幂等

    static func testA19ProposalIdempotency() {
        let matterID = UUID()
        let key = HoloLifeIncrementalProposal.stableProposalKey(
            matterID: matterID,
            logicalActionKey: "宠物照护|核实安排|10-01..10-07",
            before: "待核实 1—7 日",
            after: "已核实 1—3 日，剩 4—7 日"
        )
        let proposal = HoloLifeIncrementalProposal(
            proposalKey: key,
            matterID: matterID,
            targetTaskID: UUID(),
            logicalActionKey: "宠物照护|核实安排|10-01..10-07",
            expectedMatterRevision: 3,
            expectedTaskRevision: 2,
            action: .adjustTask,
            before: "待核实 1—7 日",
            after: "已核实 1—3 日，剩 4—7 日",
            reasonEffectID: "effect-1"
        )
        var ledger = HoloLifeProposalLedger()
        expect(ledger.apply(proposal), "A19：首次提案生效")
        expect(!ledger.apply(proposal), "A19：同 proposalKey 重复提交被幂等拦截")
        // 重试场景：中途失败后用户重试 —— 同 before/after 同键，仍只一次。
        expect(!ledger.apply(proposal), "A19：重试仍不重复执行")
        // 内容变化（after 不同）→ 新键 → 可再次生效。
        let newKey = HoloLifeIncrementalProposal.stableProposalKey(
            matterID: matterID,
            logicalActionKey: "宠物照护|核实安排|10-01..10-07",
            before: "待核实 1—7 日",
            after: "全部已核实"
        )
        expect(key != newKey, "A19：内容变化产生新提案键")
    }
}
