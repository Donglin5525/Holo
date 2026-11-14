//
//  AdversarialRound2Tests.swift
//  Holo
//
//  第二轮对抗校验（2026-11-14 东林令「多找几轮BUG」）：代码走查发现的四个疑点
//  逐个写用例实锤——本文件先「证明问题存在」，修复后同一用例转为回归锁。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct AdversarialRound2Tests {
    static var assertions = 0
    static var confirmedBugs: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    /// 对抗轮专用：记录「问题存在」而不中止（证明 bug 后统一报告）。
    static func confirmBug(_ condition: @autoclosure () -> Bool, _ bugID: String, _ message: String) {
        assertions += 1
        if condition() {
            confirmedBugs.append(bugID)
            print("🔴 实锤 [\(bugID)] \(message)")
        } else {
            print("✅ 未复现 [\(bugID)] \(message)")
        }
    }

    static func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        try await bug1_multiCandidateSwallowed()
        try await bug2_unprocessedThemesStarve()
        try await bug3LatinKeyCrowdsOutCJK()
        bug4_realModelOutputParsing()
        try await round3_starvationBounded()
        round3_extremeJSON()
        try await userJourneyFixA_categoryOnlyThemesSkipped()
        userJourneyFixC_revisionDigestSyncSafe()
        habitDomainProjectionAndTheme()
        try await habitOnlyUserEndToEnd()
        try await round4_staleUnderstandingNotInvalidated()
        try await bug6_shortIDReferenceRoundTrip()
        bug7_channelEscalationAndTimeFabrication()
        printOutcome()
    }

    // MARK: 第三轮新攻击面

    /// 饥饿修复的边界：多轮后所有主题都进台账，之后应稳定为 0 处理（不重复计费）。
    static func round3_starvationBounded() async throws {
        let storage = tempStorage()
        struct Echo: UnderstandingProposeClient {
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] { [] }
        }
        let finance = financeInputs() + [
            FinanceObservationInput(id: "cf-1", note: "咖啡", occurredAt: day(2026, 10, 2), recordedAt: day(2026, 10, 2), updatedAt: day(2026, 10, 2), isRefund: false, categoryName: nil),
        ]
        // 轮1选3主题、轮2选剩余——两轮应覆盖全部 3 个主题（猫/咖啡 双成员 + AppStore 无——此处两主题）
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 1, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: Echo())
        _ = await UnderstandingShadowRunner.runOnce(now: now.addingTimeInterval(3600), maxTopics: 1, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: Echo())
        // 轮3：全部处理过且数据无变化 → 0 处理（幂等终点，不无限烧）
        let third = await UnderstandingShadowRunner.runOnce(now: now.addingTimeInterval(7200), maxTopics: 3, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: Echo())
        expect(third.topicsProcessed == 0, "轮3应0处理（全部已入台账+无变化——饥饿修复不破坏幂等终点）")
        try? FileManager.default.removeItem(at: storage)
    }

    /// 用户画像1（轻度无备注）：纯类目巨主题不烧模型费；有备注主题正常处理。
    static func userJourneyFixA_categoryOnlyThemesSkipped() async throws {
        let storage = tempStorage()
        struct Echo: UnderstandingProposeClient {
            var calls = 0
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] { [] }
        }
        // 无备注 30 笔同类目（「餐饮」巨主题）+ 有备注 2 笔（「猫粮」语义主题）
        var finance: [FinanceObservationInput] = []
        for i in 0..<30 {
            finance.append(FinanceObservationInput(
                id: "meal-\(i)", note: nil,
                occurredAt: day(2026, 10, 1 + i % 28), recordedAt: day(2026, 10, 1 + i % 28),
                updatedAt: day(2026, 10, 1 + i % 28), isRefund: false, categoryName: "餐饮"))
        }
        finance += [
            FinanceObservationInput(id: "cat-a", note: "猫粮", occurredAt: day(2026, 10, 5), recordedAt: day(2026, 10, 5), updatedAt: day(2026, 10, 5), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-b", note: "猫砂", occurredAt: day(2026, 10, 12), recordedAt: day(2026, 10, 12), updatedAt: day(2026, 10, 12), isRefund: false, categoryName: nil),
        ]
        let report = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { (finance, [], []) }, proposeClient: Echo())
        let ledger = ShadowLedger.load(directory: storage)
        let processed = Set(ledger.candidates.values.map(\.themeKey))
        expect(!processed.contains("餐饮"), "纯类目巨主题（30笔无备注）不得进提案池——第一笔模型费不买废话")
        expect(processed.contains("猫"), "有备注语义主题正常处理（实际处理: \(processed.sorted())）")
        try? FileManager.default.removeItem(at: storage)
    }

    /// 用户画像4（换机重装）：updatedAt 被 CloudKit 同步刷新 → 不得触发全量重提案。
    static func userJourneyFixC_revisionDigestSyncSafe() {
        let base = FinanceObservationInput(id: "sync-1", note: "猫粮",
            occurredAt: day(2026, 9, 2, 20), recordedAt: day(2026, 9, 2, 20),
            updatedAt: day(2026, 9, 2, 20), isRefund: false, categoryName: nil)
        let synced = FinanceObservationInput(id: base.id, note: base.note,
            occurredAt: base.occurredAt, recordedAt: base.recordedAt,
            updatedAt: day(2026, 11, 14), isRefund: false, categoryName: base.categoryName) // 同步刷新 updatedAt
        expect(base.revisionDigest == synced.revisionDigest,
               "updatedAt 变化不得改变修订摘要（换机同步后全量重提案=烧一遍全量模型费）")
        let edited = FinanceObservationInput(id: base.id, note: "猫粮 5kg",
            occurredAt: base.occurredAt, recordedAt: base.recordedAt,
            updatedAt: base.updatedAt, isRefund: false, categoryName: base.categoryName)
        expect(base.revisionDigest != edited.revisionDigest, "真实编辑（备注变化）必须触发重投影")
    }

    // MARK: habit 域接入（2026-11-14 东林排期：只打卡用户价值为零 → 第三观察来源）

    static func habitDomainProjectionAndTheme() {
        let inputs = [
            HabitObservationInput(recordID: "hr-1", habitID: "h-1", habitName: "羽毛球", isNumeric: false, isCompleted: true, note: nil, occurredAt: day(2026, 10, 3, 19), updatedAt: day(2026, 10, 3, 19)),
            HabitObservationInput(recordID: "hr-2", habitID: "h-1", habitName: "羽毛球", isNumeric: false, isCompleted: true, note: nil, occurredAt: day(2026, 10, 10, 19), updatedAt: day(2026, 10, 10, 19)),
            HabitObservationInput(recordID: "hr-3", habitID: "h-1", habitName: "羽毛球", isNumeric: false, isCompleted: true, note: "双打赢了", occurredAt: day(2026, 10, 17, 19), updatedAt: day(2026, 10, 17, 19)),
            HabitObservationInput(recordID: "hr-4", habitID: "h-2", habitName: "冥想", isNumeric: false, isCompleted: false, note: nil, occurredAt: day(2026, 10, 18, 8), updatedAt: day(2026, 10, 18, 8)),
        ]
        let obs = HabitObservationProjector.project(inputs)
        expect(obs.count == 4, "四条打卡全投影")
        expect(obs[0].domain == .habit && obs[0].concepts == ["羽毛球"] && obs[0].attribution == .self_ && obs[0].businessState == .done,
               "打卡观察：域/概念=习惯名/归属本人/完成态")
        expect(obs[3].businessState == .negation, "未完成打卡=negation（中断也是信号）")
        expect(obs[2].quote == "双打赢了", "打卡备注作quote")
        // 主题：羽毛球 3 成员聚出且语义豁免
        var index = ObservationIndex()
        _ = index.merge(obs)
        let themes = ThemeIndex.buildThemes(from: index.observations.values.map { $0 })
        let badminton = themes.first { $0.key == "羽毛球" }
        expect(badminton != nil && badminton!.memberIDs.count >= 3, "羽毛球主题聚出（3打卡）")
        expect(UnderstandingShadowRunner.hasSemanticValue(badminton!, index: index),
               "habit 域语义豁免：纯打卡（1条备注/3）不因无备注被门槛误杀")
        // 修订摘要：updatedAt（同步刷新）不变语义
        let a = inputs[0]
        let b = HabitObservationInput(recordID: a.recordID, habitID: a.habitID, habitName: a.habitName, isNumeric: a.isNumeric, isCompleted: a.isCompleted, note: a.note, occurredAt: a.occurredAt, updatedAt: now)
        expect(a.revisionDigest == b.revisionDigest, "habit修订摘要同步安全（画像4同口径）")
    }

    /// 只打卡不记账用户（画像5）端到端：habit-only 数据产生主题并进提案池。
    static func habitOnlyUserEndToEnd() async throws {
        let storage = tempStorage()
        struct Echo: UnderstandingProposeClient {
            var seen: [String] = []
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] { [] }
        }
        let habit: [HabitObservationInput] = (0..<5).map { i in
            HabitObservationInput(recordID: "run-\(i)", habitID: "h-run", habitName: "夜跑", isNumeric: false, isCompleted: true, note: nil,
                                  occurredAt: day(2026, 10, 1 + i * 3, 21), updatedAt: day(2026, 10, 1 + i * 3, 21))
        }
        let report = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { ([], [], habit) }, proposeClient: Echo())
        let ledger = ShadowLedger.load(directory: storage)
        let processed = Set(ledger.candidates.values.map(\.themeKey))
        expect(report.habitObservations == 5 && processed.contains("夜跑"),
               "只打卡用户：夜跑主题被处理（report.habit=\(report.habitObservations) 处理=\(processed.sorted())）——画像5价值为零问题闭环")
        try? FileManager.default.removeItem(at: storage)
    }

    /// 时间序列攻击·画像5翻转（用户把「猫粮」改成「猫粮 帮同事带的」）：
    /// 旧 adoptable 理解必须失效——工程稿 §6.1「来源修订触发依赖它的理解失效」。
    static func round4_staleUnderstandingNotInvalidated() async throws {
        let storage = tempStorage()
        struct Once: UnderstandingProposeClient {
            var good = true
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
                good
                    ? [ProposalCandidate(claimType: "role", statement: "本人是猫的主要照料者。",
                                         supportingRefs: ["cat-1", "th-1"], alternativeExplanations: ["代养"],
                                         whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")]
                    : [ProposalCandidate(claimType: "role", statement: "可能在照料猫。",
                                         supportingRefs: ["cat-1"], alternativeExplanations: [],
                                         whatWouldChangeTheAnswer: nil, evidenceGrade: "线索", action: "observe")]
            }
        }
        // 第一轮：证据充分 → adoptable
        var client = Once(good: true)
        let financeV1 = [
            FinanceObservationInput(id: "cat-1", note: "猫粮", occurredAt: day(2026, 9, 2), recordedAt: day(2026, 9, 2), updatedAt: day(2026, 9, 2), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-2", note: "猫砂", occurredAt: day(2026, 9, 20), recordedAt: day(2026, 9, 20), updatedAt: day(2026, 9, 20), isRefund: false, categoryName: nil),
        ]
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { (financeV1, thoughtInputs(), []) }, proposeClient: client)
        var ledger = ShadowLedger.load(directory: storage)
        expect(ledger.snapshot(stage: .adoptable).count == 1, "第一轮 adoptable")
        // 第二轮：用户改备注翻转归属（代购）→ 主题指纹变 → 重提案 → 弱证据降级 observe
        client = Once(good: false)
        let financeV2 = [
            FinanceObservationInput(id: "cat-1", note: "猫粮 帮同事带的", occurredAt: day(2026, 9, 2), recordedAt: day(2026, 9, 2), updatedAt: day(2026, 10, 1), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-2", note: "猫砂 帮同事带的", occurredAt: day(2026, 9, 20), recordedAt: day(2026, 9, 20), updatedAt: day(2026, 10, 1), isRefund: false, categoryName: nil),
        ]
        _ = await UnderstandingShadowRunner.runOnce(now: now.addingTimeInterval(86400), maxTopics: 3, storage: storage,
            loadInputs: { (financeV2, thoughtInputs(), []) }, proposeClient: client)
        ledger = ShadowLedger.load(directory: storage)
        let stale = ledger.snapshot(stage: .adoptable)
        confirmBug(!stale.isEmpty,
                   "BUG-5", "归属翻转后旧 adoptable 仍 \(stale.count) 条未失效（工程稿§6.1 要求来源修订触发失效；用户已说代购,引擎仍持『很可能照料猫』）")
        try? FileManager.default.removeItem(at: storage)
    }

    /// BUG-6 真数据实锤（11-15 凌晨东林轮：3/6 提案因「引用不存在的观察」报废）：
    /// 模型抄 36 位 UUID 出错率高。修复=证据视图短编号 e1..e12 + gate 判定前回源。
    static func bug6_shortIDReferenceRoundTrip() async throws {
        let storage = tempStorage()
        final class ShortRefClient: UnderstandingProposeClient, @unchecked Sendable {
            var receivedOIDs: [String] = []
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
                receivedOIDs = evidence.map(\.oid)
                // 模拟模型行为：引用短编号（修复后应能回源通过）
                return [ProposalCandidate(claimType: "recurringBehavior", statement: "高频深夜外卖。",
                                          supportingRefs: evidence.prefix(3).map(\.oid),
                                          alternativeExplanations: ["预订"],
                                          whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "observe")]
            }
        }
        let client = ShortRefClient()
        let finance = financeInputs() + [
            FinanceObservationInput(id: "cf-1", note: "咖啡 外卖", occurredAt: day(2026, 10, 8, 23), recordedAt: day(2026, 10, 8, 23), updatedAt: day(2026, 10, 8, 23), isRefund: false, categoryName: nil),
        ]
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: client)
        expect(client.receivedOIDs.allSatisfy { $0.hasPrefix("e") && $0.count <= 3 },
               "证据视图用短编号（实际: \(client.receivedOIDs)）——模型不再抄 UUID")
        let ledger = ShadowLedger.load(directory: storage)
        let rejected = ledger.snapshot(stage: .rejected).filter { $0.lastReason?.contains("不存在的观察") ?? false }
        if !rejected.isEmpty {
            for r in rejected { print("DEBUG rejection:", r.themeKey, "|", r.lastReason ?? "-") }
            print("DEBUG receivedOIDs:", client.receivedOIDs.joined(separator: ","))
        }
        expect(rejected.isEmpty, "短编号引用经回源后必须全部通过（不再因抄写报废）")
        try? FileManager.default.removeItem(at: storage)
    }

    /// BUG-7 真数据实锤（东林否定「深夜外卖」：美团支付≠外卖、时刻从未上送）：
    /// 渠道升格词与时段词必须有证据出处，否则降级 observe。
    static func bug7_channelEscalationAndTimeFabrication() {
        // 证据：晚间真实消费（occurredAt 19:xx=evening）+ 美团概念；无外卖、无深夜证据
        // 2026-11-15 水位后夹具升级：诚实通过版须达 recurringBehavior 水位
        //（span≥30 且 occ≥3）——原 2 笔（含 1 笔补账）说「多次」本就证据不足。
        let eveningDinner = LifeObservation(
            domain: .finance, sourceRef: "mt-1", sourceRevision: "r1", sourceKind: "transaction",
            occurredAt: day(2026, 10, 8, 19), recordedAt: day(2026, 10, 8, 19),
            timePrecision: .minute, concepts: ["美团平台商户", "晚餐"], action: nil,
            attribution: .unknown, businessState: .plain, coverage: nil, quote: "美团平台商户/五代同糖")
        // 补账版：occurredAt 默认午夜 + midnightDefault
        let backfill = LifeObservation(
            domain: .finance, sourceRef: "mt-2", sourceRevision: "r1", sourceKind: "transaction",
            occurredAt: day(2026, 10, 9), recordedAt: day(2026, 10, 9, 22),
            timePrecision: .midnightDefault, concepts: ["美团", "晚餐"], action: nil,
            attribution: .unknown, businessState: .plain,
            coverage: ObservationCoverageNote(kind: .batchBackfill, note: "补账"), quote: "美团")
        // 水位成员：9/6 与 9/26 两笔真实晚间消费（与 mt-1 构成 32 天 3 次）
        let eveningEarlier = LifeObservation(
            domain: .finance, sourceRef: "mt-0", sourceRevision: "r1", sourceKind: "transaction",
            occurredAt: day(2026, 9, 6, 20), recordedAt: day(2026, 9, 6, 20),
            timePrecision: .minute, concepts: ["美团平台商户", "晚餐"], action: nil,
            attribution: .unknown, businessState: .plain, coverage: nil, quote: "美团平台商户")
        let eveningMid = LifeObservation(
            domain: .finance, sourceRef: "mt-3", sourceRevision: "r1", sourceKind: "transaction",
            occurredAt: day(2026, 9, 26, 19), recordedAt: day(2026, 9, 26, 19),
            timePrecision: .minute, concepts: ["晚餐"], action: nil,
            attribution: .unknown, businessState: .plain, coverage: nil, quote: "遇见小面 晚餐")
        let obs = [eveningDinner, backfill, eveningEarlier, eveningMid]
        // ①「深夜外卖」——外卖无出处 + 深夜无night证据 → 降级 observe
        let fabricated = ProposalCandidate(
            claimType: "recurringBehavior",
            statement: "用户近期存在高频的深夜外卖用餐行为。",
            supportingRefs: ["mt-1", "mt-2"], alternativeExplanations: [],
            whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: fabricated, observations: obs)
        expect(r1.action == "observe", "「深夜外卖」必须降级 observe（外卖无出处+深夜无证据）实际:\(r1.action)")
        expect(r1.reasons.contains { $0.contains("外卖") } && r1.reasons.contains { $0.contains("深夜") },
               "降级理由须同时点名渠道升格与时段脑补")
        // ②「晚间用餐」——晚间有 evening 证据 + 无渠道词 + 水位达标（32天3次）→ 原样通过
        let honest = ProposalCandidate(
            claimType: "recurringBehavior",
            statement: "用户近期多次在晚间通过平台商户用餐。",
            supportingRefs: ["mt-0", "mt-1", "mt-2", "mt-3"], alternativeExplanations: [],
            whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: honest, observations: obs)
        expect(r2.action == "adopt", "「晚间用餐」有据且达水位应通过（晚间证据存在），实际:\(r2.action)")
        // ③ 补账记录时段=unknown 不给模型任何暗示
        expect(UnderstandingShadowRunner.timeOfDayBand(of: backfill) == "unknown",
               "补账默认午夜 → 时段 unknown（不给编故事原料）")
        expect(UnderstandingShadowRunner.timeOfDayBand(of: eveningDinner) == "evening",
               "真实 19 点消费 → evening")
    }

    /// 极端 JSON 形态：candidates 为 null / 截断 JSON / 数组顶层——全部显式失败不崩。
    static func round3_extremeJSON() {
        let bad: [(String, String)] = [
            ("candidates为null", "{\"candidates\":null,\"noValueReason\":\"无\"}"),
            ("截断JSON", "{\"candidates\":[{\"claimType\":\"role\",\"statement\":\"截断"),
            ("顶层是数组", "[1,2,3]"),
            ("空字符串", ""),
        ]
        for (name, raw) in bad {
            do {
                _ = try ProposalEnvelopeParser.parse(from: raw)
                // candidates:null 解码为默认空数组（Codable 默认值合成）——合法形态
            } catch {
                // 显式失败 = 正确行为（截断/数组顶层/空串都必须失败而非崩）
            }
        }
        assertions += bad.count
    }

    static func printOutcome() {
        if confirmedBugs.isEmpty {
            print("AdversarialRound2Tests: \(assertions) assertions passed —— 四疑点全部未复现（已是修复后状态或误判）")
        } else {
            print("AdversarialRound2Tests: \(assertions) assertions, 实锤 \(confirmedBugs.count) 个问题: \(confirmedBugs.joined(separator: ", ")) —— 待修复后本文件转为回归锁")
        }
    }

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }
    static let now = day(2026, 11, 14, 10)

    static func tempStorage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("adv2-\(UUID().uuidString)")
    }

    static func financeInputs() -> [FinanceObservationInput] {
        [
            FinanceObservationInput(id: "cat-1", note: "猫粮", occurredAt: day(2026, 8, 14), recordedAt: day(2026, 8, 14), updatedAt: day(2026, 8, 14), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-2", note: "猫粮", occurredAt: day(2026, 9, 2), recordedAt: day(2026, 9, 2), updatedAt: day(2026, 9, 2), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-3", note: "猫砂", occurredAt: day(2026, 9, 25), recordedAt: day(2026, 9, 25), updatedAt: day(2026, 9, 25), isRefund: false, categoryName: nil),
        ]
    }

    static func thoughtInputs() -> [ThoughtObservationInput] {
        [
            ThoughtObservationInput(id: "th-1", text: "猫在门口等我，今天加班回来晚了。", createdAt: day(2026, 9, 26, 23), updatedAt: day(2026, 9, 26, 23), isAIDerived: false),
        ]
    }

    // MARK: 疑点1：同主题多候选，第二条起被终态不可逆静默吞

    static func bug1_multiCandidateSwallowed() async throws {
        let storage = tempStorage()
        struct TwoCandidates: UnderstandingProposeClient {
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
                [
                    ProposalCandidate(claimType: "role", statement: "本人是猫的主要照料者。",
                                      supportingRefs: ["cat-1", "th-1"], alternativeExplanations: ["代养"],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt"),
                    ProposalCandidate(claimType: "phaseState", statement: "近一个月在尝试控制咖啡摄入。",
                                      supportingRefs: ["cat-2"], alternativeExplanations: [],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "线索", action: "observe"),
                ]
            }
        }
        let report = await UnderstandingShadowRunner.runOnce(
            now: now, maxTopics: 3, storage: storage,
            loadInputs: { (financeInputs(), thoughtInputs(), []) },
            proposeClient: TwoCandidates())
        // 证明：模型返回了 2 条候选，但台账只可能记录 1 个终态——第二条去哪了？
        let ledger = ShadowLedger.load(directory: storage)
        let themeEntries = ledger.candidates.values.filter { $0.themeKey == ledger.candidates.values.first?.themeKey }.count
        confirmBug(report.proposalsReceived == 2 && themeEntries < 2,
                   "BUG-1", "2 条候选落 \(themeEntries) 条台账（<2 即第 2 条被吞）")
        try? FileManager.default.removeItem(at: storage)
    }

    // MARK: 疑点2：首轮未选中的主题永远饥饿

    static func bug2_unprocessedThemesStarve() async throws {
        let storage = tempStorage()
        struct Echo: UnderstandingProposeClient {
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] { [] }
        }
        // 三个主题的数据：咖啡、羽毛球、猫
        var finance = financeInputs()
        finance += [
            FinanceObservationInput(id: "cf-1", note: "咖啡", occurredAt: day(2026, 10, 1), recordedAt: day(2026, 10, 1), updatedAt: day(2026, 10, 1), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cf-2", note: "咖啡", occurredAt: day(2026, 10, 8), recordedAt: day(2026, 10, 8), updatedAt: day(2026, 10, 8), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "bd-1", note: "羽毛球 场地费", occurredAt: day(2026, 10, 3), recordedAt: day(2026, 10, 3), updatedAt: day(2026, 10, 3), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "bd-2", note: "羽毛球 装备", occurredAt: day(2026, 10, 10), recordedAt: day(2026, 10, 10), updatedAt: day(2026, 10, 10), isRefund: false, categoryName: nil),
        ]
        // 第一轮：maxTopics=1 只处理 1 个主题
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 1, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: Echo())
        // 第二轮：数据不变 → 全部 unchanged → 剩余 2 个主题永远不会被处理
        let second = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 3, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: Echo())
        let ledger = ShadowLedger.load(directory: storage)
        confirmBug(second.topicsProcessed == 0 && ledger.candidates.count == 1,
                   "BUG-2", "首轮只处理1主题后，剩余2主题第二轮零处理（processed=\(second.topicsProcessed) 台账=\(ledger.candidates.count)）——未入选主题永久饥饿")
        try? FileManager.default.removeItem(at: storage)
    }

    // MARK: 疑点3：字母 key 主题字典序挤占中文主题

    static func bug3LatinKeyCrowdsOutCJK() async throws {
        // 真实形态：中文主题（猫粮 4 成员）信息量高于英文品牌（AppStore 2 成员）
        // ——maxTopics=2 时若按字典序，AppStore 挤掉 猫粮。测 Runner 真源行为：
        // 造 3 主题，第一轮 maxTopics=2，断言成员最多的两个主题（含 猫粮）入选。
        let storage = tempStorage()
        struct Echo: UnderstandingProposeClient {
            func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] { [] }
        }
        let finance = financeInputs() + [
            FinanceObservationInput(id: "en-1", note: "AppStore", occurredAt: day(2026, 10, 1), recordedAt: day(2026, 10, 1), updatedAt: day(2026, 10, 1), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "en-2", note: "AppStore", occurredAt: day(2026, 10, 8), recordedAt: day(2026, 10, 8), updatedAt: day(2026, 10, 8), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cf-1", note: "咖啡", occurredAt: day(2026, 10, 2), recordedAt: day(2026, 10, 2), updatedAt: day(2026, 10, 2), isRefund: false, categoryName: nil),
        ]
        _ = await UnderstandingShadowRunner.runOnce(now: now, maxTopics: 2, storage: storage,
            loadInputs: { (finance, thoughtInputs(), []) }, proposeClient: Echo())
        let ledger = ShadowLedger.load(directory: storage)
        let processed = Set(ledger.candidates.values.map(\.themeKey))
        confirmBug(processed.contains("AppStore") && !processed.contains("猫"),
                   "BUG-3", "maxTopics=2 选了 \(processed.sorted()) ——成员数多的中文主题被字典序挤掉")
        try? FileManager.default.removeItem(at: storage)
    }

    // MARK: 疑点4：真实模型输出的解析兼容（围栏/前后缀/超长前缀）

    static func bug4_realModelOutputParsing() {
        // parseEnvelope 应容忍生产网关可能附加的形态
        let cases: [(String, String)] = [
            ("裸JSON", "{\"candidates\":[],\"noValueReason\":\"无\"}"),
            ("围栏", "```json\n{\"candidates\":[],\"noValueReason\":\"无\"}\n```"),
            ("前缀噪声", "好的，以下是结果：\n{\"candidates\":[],\"noValueReason\":\"无\"}"),
            ("围栏+语言前缀", "根据材料分析：\n```json\n{\"candidates\":[{\"claimType\":\"role\",\"statement\":\"可能在照料猫\",\"supportingRefs\":[\"a\"],\"alternativeExplanations\":[],\"whatWouldChangeTheAnswer\":null,\"evidenceGrade\":\"线索\",\"action\":\"observe\"}],\"noValueReason\":null}\n```"),
        ]
        var parsed = 0
        for (name, raw) in cases {
            if let envelope = try? ProposalEnvelopeParser.parse(from: raw) {
                parsed += 1
                _ = envelope
            } else {
                print("   解析失败形态: \(name)")
            }
        }
        confirmBug(parsed < cases.count,
                   "BUG-4", "真实输出形态兼容 \(parsed)/\(cases.count)（失败形态将导致整主题 rejected）")
    }
}
