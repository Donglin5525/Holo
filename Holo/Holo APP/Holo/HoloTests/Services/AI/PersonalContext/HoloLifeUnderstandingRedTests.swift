//
//  HoloLifeUnderstandingRedTests.swift
//  HoloTests
//
//  「Holo 生活理解与 Matter 主动筹备」R0 确定性红测（方案 2026-09-23 §4.2 R0）。
//
//  三个红测钉死当前检索层的已定位缺陷（R0 审查 R1/R9/R10），R3 修复后转绿：
//    红 1  「护照」经单字「护/照」重叠误命中「照护」候选（R1：CJK 单字 token 切分）；
//    红 2  存在 linkedContextIDs 即无条件构成条件命中（R9：链接不构成独立召回理由）；
//    红 3  时间匹配不用冻结旅行区间（R10）。R0 实测发现实际缺陷形态比方案描述更宽：
//          recurring 规则不做发生日期比对、活跃即恒判重叠（3b，含 10-15 房贷误入）；
//          event 类才走 now+30 固定窗（3c，12 月事件漏检）；3a 锁定期望行为
//          （修复后 12 月区间必须命中 12 月事项，防止修过头）。
//
//  两条绿断言锁修复边界（R3 修词法/链接/时间窗时不得误伤）：
//    绿 A  Q0 纯净性（不含宠物词与「护/照」单字，防止编辑用例重新引入词面线索）；
//    绿 B  「护照」对证件类候选（真整词命中）仍应命中。
//
//  红测不挂 XCTest 桥接（预期失败，fatalError/exit(1) 会中断测试进程）；
//  standalone 脚本以 expectedRed 标记登记，R3 修复转绿后移除标记并挂桥接。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloLifeUnderstandingRedTests.main()
    }
}
#endif

struct HoloLifeUnderstandingRedTests {
    /// 红测专用断言：收集失败继续执行，结束时统一报告（一次跑完三个缺陷）。
    private static var failures: [String] = []

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { failures.append(message) }
    }

    static func main() async throws {
        testGreenQueryPurity()                       // 绿 A
        try await testRed1PassportSingleCharCross()  // 红 1（R1）
        testRed2OrphanLinkedContextIDs()             // 红 2（R9）
        try await testRed3FixedWindowMissesTravel()  // 红 3（R10）

        if !failures.isEmpty {
            print("HoloLifeUnderstandingRedTests：\(failures.count) 处断言未过——")
            for failure in failures { print("  - \(failure)") }
            print("（R0 预期红：以上为已冻结缺陷，R3 修复后本套件转绿）")
            exit(1)
        }
        print("HoloLifeUnderstandingRedTests：全部断言通过")
        print("（红测转绿：若 R3 尚未实施，说明断言失效，需人工核对检索层是否已被并行改动修复）")
    }

    // MARK: 绿 A：Q0 纯净性（方案 §2.2 自动检查）

    static func testGreenQueryPurity() {
        let purityFailures = HoloLifeUnderstandingQueries.purityFailures()
        expect(purityFailures.isEmpty, "Q0/Q1 纯净性被破坏：\(purityFailures.joined(separator: "；"))")
    }

    // MARK: 红 1：护照/照护单字交叉误召回（R1）

    static func testRed1PassportSingleCharCross() async throws {
        // Q1 对抗输入（含「护照已经办好」）对「照护」候选：
        // 中文按单字切分后「护照」与「照护」共享「护」「照」，
        // conditionMatches 只要一个字重叠即 true，lexicalScores 只要一个字重叠即给分。
        let frame = HoloLifeUnderstandingQueries.travelFrame(
            utterance: HoloLifeUnderstandingQueries.q1,
            timeRangeExpression: "10 月 1 日到 7 日"
        )
        let petCare = HoloLifeUnderstandingCandidateFactory.adviceCandidate(
            recordID: "r-petcare",
            statement: "离家期间家中宠物需要照护",
            conditionText: "用户离家出行时需要安排宠物照护"
        )
        expect(
            !HoloContextRetrievalService.conditionMatches(frame: frame, payload: petCare.payload),
            "红1-条件路径：Q1（护照）不得经单字「护/照」重叠命中「照护」候选（R1）"
        )
        let scores = HoloContextRetrievalService.lexicalScores(frame: frame, catalog: [petCare])
        // A02 语义：「护照」不得构成召回原因——Q1 与 Q0 对照护候选的词法分必须相同
        //（分数只能来自真实的检索方向词重叠，而非护照/照护单字交叉）。
        let q0Frame = HoloLifeUnderstandingQueries.travelFrame(
            utterance: HoloLifeUnderstandingQueries.q0,
            timeRangeExpression: "10 月 1 日到 7 日"
        )
        let scoresQ0 = HoloContextRetrievalService.lexicalScores(frame: q0Frame, catalog: [petCare])
        expect(
            scores["r-petcare"] == scoresQ0["r-petcare"],
            "红1-词法路径：护照的存在不得改变照护候选的词法分（R1，实际 Q1=\(scores["r-petcare"] ?? 0) Q0=\(scoresQ0["r-petcare"] ?? 0)）"
        )

        // 绿 B：真整词命中不得被 R3 修复误伤——「护照」对证件类候选仍应命中。
        let passport = HoloLifeUnderstandingCandidateFactory.adviceCandidate(
            recordID: "r-passport",
            statement: "出行前需确认护照有效期",
            conditionText: "出境行程需核对护照有效期与签证要求"
        )
        expect(
            HoloContextRetrievalService.conditionMatches(frame: frame, payload: passport.payload),
            "绿B-条件路径：「护照」对证件类候选（真整词命中）应保持命中"
        )
        let passportScores = HoloContextRetrievalService.lexicalScores(frame: frame, catalog: [passport])
        expect(
            passportScores["r-passport"] != nil,
            "绿B-词法路径：证件类候选应保持可召回（R3 修词法不得把真命中修没）"
        )
    }

    // MARK: 红 2：孤立 linkedContextIDs 无条件命中（R9）

    static func testRed2OrphanLinkedContextIDs() {
        // 候选与 frame 无任何词面/主体/时间交集，仅 linkedContextIDs 非空
        // （且指向的情境与本次旅行无关）。链接只能用于已命中候选的受控扩展，
        // 不构成独立召回理由——当前实现存在链接即 return true。
        let frame = HoloLifeUnderstandingQueries.travelFrame(
            utterance: HoloLifeUnderstandingQueries.q0,
            timeRangeExpression: "10 月 1 日到 7 日"
        )
        let orphan = HoloLifeUnderstandingCandidateFactory.adviceCandidate(
            recordID: "r-orphan-link",
            statement: "公司季度考评加分项",
            conditionText: nil,
            linkedContextIDs: ["ctx-unrelated-quarterly-review"]
        )
        expect(
            !HoloContextRetrievalService.conditionMatches(frame: frame, payload: orphan.payload),
            "红2：与本次情境无关的候选不得仅凭 linkedContextIDs 非空构成条件命中（R9）"
        )
    }

    // MARK: 红 3：now+30 天固定窗 vs 冻结旅行区间（R10）

    /// 语义提供方假件（空分：不干扰，让时间窗成为唯一信号）。
    private final class EmptySemantic: HoloContextSemanticSearchProviding, @unchecked Sendable {
        func semanticCandidateIDs(query: String, directions: [String]) async throws -> [String: Double] {
            [:]
        }
    }

    static func testRed3FixedWindowMissesTravel() async throws {
        let now = HoloLifeUnderstandingFrozenClock.referenceDate
        let service = HoloContextRetrievalService(semanticProvider: EmptySemantic())

        // 3a 远期漏检：12 月 1—8 日出行，责任是「每年 12 月 1 日缴暖气费」。
        // 冻结旅行区间 [12-01, 12-08) 应命中。
        // 注：当前实现对 recurring 规则不做发生日期比对、恒判重叠（见 3b 注），
        // 本断言当前「碰巧绿」但命中理由错误；R3 修复后应因区间匹配而正确转绿。
        let decemberTrip = HoloLifeUnderstandingQueries.travelFrame(
            utterance: "我 12 月 1 日到 8 日回老家，请帮我安排出发前家里的事。",
            timeRangeExpression: "12 月 1 日到 8 日",
            interval: (start: HoloLifeUnderstandingFrozenClock.localDayStart("2026-12-01"),
                       end: HoloLifeUnderstandingFrozenClock.localDayStart("2026-12-08"))
        )
        let heatingFee = HoloLifeUnderstandingCandidateFactory.adviceCandidate(
            recordID: "r-heating-dec",
            statement: "每年 12 月 1 日前需缴纳家中暖气费",
            temporal: HoloContextTemporalV1(
                kind: .recurring,
                originalExpression: "每年 12 月 1 日",
                recurrence: HoloContextRecurrenceV1(frequency: .yearly, dayOfMonth: 1, month: 12)
            )
        )
        let decemberResult = await service.retrieve(
            frame: decemberTrip,
            catalog: [heatingFee],
            calendar: HoloLifeUnderstandingFrozenClock.calendar,
            now: now
        )
        expect(
            decemberResult.entries.contains { $0.recordID == "r-heating-dec" },
            "红3a：12 月出行的冻结区间应命中 12 月 1 日暖气费（当前 now+30 固定窗漏检，R10）"
        )

        // 3b 近期误入：10 月 1—7 日出行（Q0），事项是「每月 15 号房贷扣款」。
        // 10-15 不在冻结旅行区间 [10-01, 10-08) 内 → 不应命中。
        // 注：当前实现对 recurring 规则不比对发生日期、活跃即恒判重叠（overlaps
        // 的 .recurring 分支无日期计算），因此 10-15 房贷被误入——R10 的实际缺陷
        // 形态比「now+30 固定窗」更宽：recurring 恒真 + event 才走固定窗（见 3c）。
        let octoberTrip = HoloLifeUnderstandingQueries.travelFrame(
            utterance: HoloLifeUnderstandingQueries.q0,
            timeRangeExpression: "10 月 1 日到 7 日",
            interval: HoloLifeUnderstandingFrozenClock.travelInterval
        )
        let mortgage = HoloLifeUnderstandingCandidateFactory.adviceCandidate(
            recordID: "r-mortgage-15",
            statement: "房贷每月 15 号自动扣款",
            temporal: HoloContextTemporalV1(
                kind: .recurring,
                originalExpression: "每月 15 号",
                recurrence: HoloContextRecurrenceV1(frequency: .monthly, dayOfMonth: 15)
            )
        )
        let octoberResult = await service.retrieve(
            frame: octoberTrip,
            catalog: [mortgage],
            calendar: HoloLifeUnderstandingFrozenClock.calendar,
            now: now
        )
        expect(
            !octoberResult.entries.contains { $0.recordID == "r-mortgage-15" },
            "红3b：10 月 1—7 日出行不得把 10-15 房贷扣款纳入本次影响（recurring 不做日期比对恒真，R10）"
        )

        // 3c event 类固定窗漏检：12 月 1—4 日家里要做全屋消毒（一次性事件，
        // validFrom=12-01）。当前 event 分支用固定窗 [now, now+30] 判重叠：
        // 12-01 > 10-23 → 不重叠 → 漏检；冻结旅行区间 [12-01, 12-08) 应命中。
        let sanitizeEvent = HoloLifeUnderstandingCandidateFactory.adviceCandidate(
            recordID: "r-sanitize-dec",
            statement: "预约了师傅 12 月初上门做全屋消毒",
            temporal: HoloContextTemporalV1(
                kind: .event,
                originalExpression: "12 月 1 日到 4 日",
                validFrom: HoloLifeUnderstandingFrozenClock.localDayStart("2026-12-01"),
                validTo: HoloLifeUnderstandingFrozenClock.localDayStart("2026-12-04")
            )
        )
        let sanitizeResult = await service.retrieve(
            frame: decemberTrip,
            catalog: [sanitizeEvent],
            calendar: HoloLifeUnderstandingFrozenClock.calendar,
            now: now
        )
        expect(
            sanitizeResult.entries.contains { $0.recordID == "r-sanitize-dec" },
            "红3c：12 月出行的冻结区间应命中 12 月 1—4 日消毒事件（当前 event 用 now+30 固定窗漏检，R10）"
        )
    }
}
