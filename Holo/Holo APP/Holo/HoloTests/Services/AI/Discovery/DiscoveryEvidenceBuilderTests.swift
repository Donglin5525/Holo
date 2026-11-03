//
//  DiscoveryEvidenceBuilderTests.swift
//  HoloTests
//
//  「一个发现」G2 证据构建测试（02 §2.4 / §3.2 末段；04 验收矩阵
//  T27/T28/T31/T32）：独立事件计数、ambiguous、补签时间精度、不推断习惯达标、
//  语义切块（转折随块、超长弃用记 coverage）。fixtures 用 #filePath 定位，缺文件跳过。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
@testable import Holo

final class DiscoveryEvidenceBuilderTests: XCTestCase {

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    /// Asia/Shanghai 固定时区（窗口/日界确定性）
    private var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)!
    }

    // MARK: - 快照工厂

    private func thoughtSnapshot(
        id: String,
        text: String,
        occurredAt: Date?,
        anchors: [String] = [],
        refs: [String] = []
    ) -> DiscoverySourceSnapshot {
        DiscoverySourceSnapshot(
            domain: .thought, kind: .thought, localID: id,
            occurredAt: occurredAt, occurredOnlyDateKnown: false,
            recordedAt: occurredAt ?? fixedNow,
            text: text, numericValue: nil, numericUnit: nil,
            entityRefs: refs, eventAnchors: anchors,
            revisionFields: ["discovery.thought.v1", id, text]
        )
    }

    private func taskSnapshot(
        id: String,
        title: String,
        completedAt: Date?,
        anchors: [String] = [],
        refs: [String] = []
    ) -> DiscoverySourceSnapshot {
        DiscoverySourceSnapshot(
            domain: .task, kind: .task, localID: id,
            occurredAt: completedAt, occurredOnlyDateKnown: false,
            recordedAt: completedAt ?? fixedNow,
            text: title, numericValue: nil, numericUnit: nil,
            entityRefs: refs, eventAnchors: anchors,
            revisionFields: ["discovery.task.v1", id, title]
        )
    }

    private func habitSnapshot(
        id: String,
        habitID: String,
        occurredAt: Date,
        retroactive: Bool = false,
        value: Double? = nil,
        unit: String? = nil,
        text: String = "习惯「跑步」；打卡",
        refs: [String] = []
    ) -> DiscoverySourceSnapshot {
        DiscoverySourceSnapshot(
            domain: .habit, kind: .habitEvent, localID: id,
            occurredAt: occurredAt, occurredOnlyDateKnown: retroactive,
            recordedAt: fixedNow,
            text: text, numericValue: value, numericUnit: unit,
            entityRefs: ["habit:\(habitID)"] + refs,
            eventAnchors: ["habitEvent:\(id)"],
            revisionFields: ["discovery.habitEvent.v1", id, habitID, String(occurredAt.timeIntervalSince1970)]
        )
    }

    private func build(_ snapshots: [DiscoverySourceSnapshot], domains: [DiscoverySourceDomain] = [.thought], denominatorKnown: Bool = true) -> DiscoveryEvidenceBatch {
        DiscoveryEvidenceBuilder().buildAtoms(
            from: snapshots,
            coverageInput: DiscoveryCoverageInput(
                domains: domains,
                windowStart: date(2026, 10, 1),
                windowEnd: date(2026, 10, 23),
                matchedBlockCount: snapshots.count,
                truncatedBlockCount: 0,
                denominatorKnown: denominatorKnown
            ),
            accessRevision: "access-rev-1",
            calendar: shanghaiCalendar,
            now: fixedNow
        )
    }

    // MARK: - T27：同一事件跨来源不重复计数

    func test_T27_同一事件被任务与想法复述_独立计数仍为1() {
        let eventDate = date(2026, 10, 12)
        let snapshots = [
            taskSnapshot(id: "task-1", title: "完成：整理作品集封面。", completedAt: eventDate, anchors: ["task:task-1"]),
            // 想法显式关联同一任务（createdTasks 锚）→ 同 lineage
            thoughtSnapshot(id: "thought-1", text: "今天把作品集封面整理好了。", occurredAt: eventDate, anchors: ["task:task-1"]),
            // 另一条想法再次复述，仍锚同一任务
            thoughtSnapshot(id: "thought-2", text: "本日完成作品集封面，挺顺利。", occurredAt: eventDate, anchors: ["task:task-1"]),
        ]
        let batch = build(snapshots, domains: [.thought, .task])

        XCTAssertEqual(batch.independentEventCount, 1, "同一显式事件的跨来源复述只算 1 次（§2.4 规则 1）")
        // computedFact 原子是程序计数产物（.group("computed")），不参与事件血缘空间
        let lineages = Set(batch.atoms
            .filter { $0.sourceKind != .computedFact }
            .compactMap { atom -> String? in
                if case .group(let label) = atom.lineageGroup { return label } else { return nil }
            })
        XCTAssertEqual(lineages, ["L01"], "三个来源归同一组")
        XCTAssertFalse(batch.atoms.contains { atom in
            if case .ambiguous = atom.lineageGroup { return true } else { return false }
        })
    }

    func test_T27_不同来源ID不是独立性证明_时间重合文本相似也只算一次() {
        let eventDate = date(2026, 10, 12)
        let snapshots = [
            taskSnapshot(id: "task-a", title: "完成：整理作品集封面。", completedAt: eventDate, anchors: ["task:task-a"]),
            // 无显式锚，但同日高度相似复述 → ambiguous（不是第二个独立事件）
            thoughtSnapshot(id: "thought-a", text: "完成：整理作品集封面。", occurredAt: eventDate),
        ]
        let batch = build(snapshots, domains: [.thought, .task])
        XCTAssertEqual(batch.independentEventCount, 0, "ambiguous 不增加规律样本数")
        XCTAssertEqual(batch.ambiguousGroupCount, 2)
    }

    // MARK: - T28：关联不确定 → ambiguous

    func test_T28_原文高度相似且时间重合_标ambiguous不增计数() {
        let base = date(2026, 10, 8, 9)
        let snapshots = [
            thoughtSnapshot(id: "t1", text: "今天先走了十分钟，慢慢开始。", occurredAt: base),
            thoughtSnapshot(id: "t2", text: "今天先走了十分钟，慢慢开始。", occurredAt: base.addingTimeInterval(3600)),
            // 第三条不同内容、不同日期 → 独立
            thoughtSnapshot(id: "t3", text: "今晚只翻了两页，别要求太高。", occurredAt: date(2026, 10, 16)),
        ]
        let batch = build(snapshots)

        XCTAssertEqual(batch.independentEventCount, 1, "两条疑似复述合并语义上不计数，第三条独立")
        XCTAssertEqual(batch.ambiguousGroupCount, 2, "两条疑似复述各自标 ambiguous")
        let ambiguousTexts = batch.atoms
            .filter { if case .ambiguous = $0.lineageGroup { return true } else { return false } }
            .map(\.sourceBlock)
        XCTAssertEqual(ambiguousTexts.count, 2)
        XCTAssertTrue(ambiguousTexts.allSatisfy { $0.contains("先走了十分钟") })
    }

    func test_T28_相似但时间不重合_不算ambiguous() {
        let snapshots = [
            thoughtSnapshot(id: "t1", text: "今天先走了十分钟，慢慢开始。", occurredAt: date(2026, 10, 1)),
            thoughtSnapshot(id: "t2", text: "今天先走了十分钟，慢慢开始。", occurredAt: date(2026, 10, 20)),
        ]
        let batch = build(snapshots)
        XCTAssertEqual(batch.independentEventCount, 2, "时间不重合 → 不同日期真实事件（§2.4 规则 3 同口径）")
    }

    func test_共享标签不构成同一事件() {
        let snapshots = [
            thoughtSnapshot(id: "t1", text: "周一跑了三公里，状态一般。", occurredAt: date(2026, 10, 5), refs: ["tag:跑步"]),
            thoughtSnapshot(id: "t2", text: "周四夜跑很轻松，配速稳定。", occurredAt: date(2026, 10, 8), refs: ["tag:跑步"]),
        ]
        let batch = build(snapshots)
        XCTAssertEqual(batch.independentEventCount, 2, "同标签 ≠ 同实体/事件（entityRefs 不参与 lineage 合并）")
    }

    func test_同一习惯不同日期_不同事件() {
        let snapshots = [
            habitSnapshot(id: "r1", habitID: "h1", occurredAt: date(2026, 10, 5, 8)),
            habitSnapshot(id: "r2", habitID: "h1", occurredAt: date(2026, 10, 6, 8)),
        ]
        let batch = build(snapshots, domains: [.habit])
        XCTAssertEqual(batch.independentEventCount, 2, "同一习惯不同日期的真实打卡是不同事件（§2.4 规则 3）")
    }

    // MARK: - T31：补签与时区边界（发生时间不伪造精度）

    func test_T31_补签occurredRange用日区间_不把零点当真实时刻() {
        // 2026-10-16 23:30 +08 记录补签 2026-10-16（date=当日零点 +08 = 前一天 16:00 UTC）
        let retroDate = date(2026, 10, 16, 0, 0)
        let snapshots = [habitSnapshot(id: "r1", habitID: "h1", occurredAt: retroDate, retroactive: true)]
        let batch = build(snapshots, domains: [.habit])
        let atom = batch.atoms[0]

        XCTAssertEqual(atom.occurredRange.precision, .day)
        let calendar = shanghaiCalendar
        XCTAssertEqual(atom.occurredRange.start, calendar.startOfDay(for: retroDate), "start=目标日零点（本地时区日界）")
        XCTAssertEqual(atom.occurredRange.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: retroDate)), "end=次日零点：只知道日期，不编时刻")
    }

    func test_T31_实时打卡保留真实时刻_时区边界归日正确() {
        // 2026-10-16 23:30 +08 = 15:30 UTC：+08 日界归 10-16，不会漂到 10-17
        // （数值型记录才产 recorded_value 事实——给数值以验证窗口归日；纯打卡无数值事实）
        let checkInDate = date(2026, 10, 16, 23, 30)
        let snapshots = [habitSnapshot(
            id: "r1", habitID: "h1", occurredAt: checkInDate, retroactive: false,
            value: 20, unit: "分钟", text: "习惯「散步」；记录 20分钟"
        )]
        let batch = build(snapshots, domains: [.habit])
        let atom = batch.atoms[0]

        XCTAssertEqual(atom.occurredRange.start, checkInDate, "非补签保留真实时刻")
        XCTAssertEqual(atom.occurredRange.end, checkInDate)
        XCTAssertEqual(atom.occurredRange.precision, .day)
        // 数值事实窗口按发生日（+08 日界）：23:30 归 10-16 当天零点，不漂日
        let fact = atom.computedFacts.first { $0.metricID == "recorded_value" }
        XCTAssertNotNil(fact, "带显式数值的记录必须产 recorded_value 事实")
        XCTAssertEqual(fact?.windowStart, shanghaiCalendar.startOfDay(for: checkInDate))
        XCTAssertEqual(fact?.value, 20)
        XCTAssertEqual(fact?.unit, "分钟")
    }

    func test_发生时间未知_不伪造() {
        let snapshots = [thoughtSnapshot(id: "t1", text: "补记：很久以前有过一次小步开始。", occurredAt: nil)]
        let batch = build(snapshots)
        let atom = batch.atoms[0]
        XCTAssertNil(atom.occurredRange.start)
        XCTAssertNil(atom.occurredRange.end)
        XCTAssertEqual(atom.occurredRange.precision, .unknown, "只知道「很久以前」→ 精度 unknown（F13）")
    }

    // MARK: - T32：习惯不推断历史达标

    func test_T32_习惯当前目标与历史缺版本_不推断达标() {
        let snapshots = [
            habitSnapshot(id: "r1", habitID: "h1", occurredAt: date(2026, 10, 5, 8), retroactive: false, value: 2, unit: "杯", text: "习惯「喝水」；记录 2杯"),
            habitSnapshot(id: "r2", habitID: "h1", occurredAt: date(2026, 10, 6, 8), retroactive: false, value: 3, unit: "杯", text: "习惯「喝水」；记录 3杯"),
        ]
        let batch = build(snapshots, domains: [.habit])

        let allMetricIDs = batch.atoms.flatMap { $0.computedFacts.map(\.metricID) }
        XCTAssertEqual(Set(allMetricIDs), ["recorded_value", "independent_events"], "只产确定性计数与显式数值")
        XCTAssertFalse(allMetricIDs.contains { $0.contains("target") || $0.contains("goal") || $0.contains("compliance") },
                       "无历史目标版本 → 不推断当时是否达标（G0 §1.3）")
        // 独立事件计数是「打卡记录数」，不是「达标天数」
        XCTAssertEqual(batch.independentEventCount, 2)
    }

    // MARK: - computedFact atom

    func test_computedFact原子携带独立计数与批次摘要() {
        let snapshots = [
            thoughtSnapshot(id: "t1", text: "第一次。", occurredAt: date(2026, 10, 1)),
            thoughtSnapshot(id: "t2", text: "第二次，不同内容。", occurredAt: date(2026, 10, 9)),
        ]
        let batch = build(snapshots)
        guard let computed = batch.atoms.first(where: { $0.sourceKind == .computedFact }) else {
            return XCTFail("必须产 computedFact atom")
        }
        XCTAssertEqual(computed.evidenceID, "E03", "前两个块为 E01/E02，计数原子排最后")
        XCTAssertNil(computed.localSourceRef)
        XCTAssertEqual(computed.computedFacts.first?.metricID, "independent_events")
        XCTAssertEqual(computed.computedFacts.first?.value, 2)
        XCTAssertEqual(computed.computedFacts.first?.formulaVersion, "count_v1")
    }

    // MARK: - 语义切块

    func test_切块_句界切分且每块不超上限() {
        let sentence = "这一段正文内容长度约五十字，描述一次会议前的准备过程，写提纲之后理清了问题。"   // 35 字左右
        let text = Array(repeating: sentence, count: 30).joined()   // ~1050 字
        let outcome = DiscoveryEvidenceBuilder.segment(text: text)
        XCTAssertFalse(outcome.blocks.isEmpty)
        XCTAssertTrue(outcome.blocks.allSatisfy { $0.count <= 520 }, "硬上限 520")
        XCTAssertGreaterThanOrEqual(outcome.blocks.count, 3, "千字文本切成多块")
        XCTAssertEqual(outcome.blocks.joined().utf16.count, text.utf16.count, "块的拼接=原文（UTF-16 口径不丢字符）")
        XCTAssertFalse(outcome.blocks.contains { $0.hasPrefix("，") }, "不从句中断开")
    }

    func test_切块_转折句必须随块保留() {
        // 前句 350+ 字把块顶到接近上限，随后「但是」句出现 → 必须同块（允许溢出到 520 内）
        let filler = String(repeating: "字", count: 360)
        let text = "今天写了提纲，" + filler + "。但是我到最后还是没想清楚重点，反而越列越乱。"
        let outcome = DiscoveryEvidenceBuilder.segment(text: text)
        XCTAssertEqual(outcome.blocks.count, 1, "转折句不单独成块")
        XCTAssertTrue(outcome.blocks[0].contains("但是"), "否定/转折必须随块保留（§3.2）")
        XCTAssertLessThanOrEqual(outcome.blocks[0].count, 520)
    }

    func test_切块_超硬上限的转折句弃用并记coverage() {
        let first = String(repeating: "甲", count: 510) + "。"
        let transition = "但是" + String(repeating: "乙", count: 500) + "。"   // >520 保不住同块
        let text = first + transition
        let outcome = DiscoveryEvidenceBuilder.segment(text: text)
        XCTAssertEqual(outcome.blocks, [first], "原句保留")
        XCTAssertEqual(outcome.droppedBlockCount, 1, "保不住上下文的转折句弃用并记 coverage（不截否定）")
    }

    func test_切块_单句超硬上限整句弃用() {
        let text = String(repeating: "长", count: 600) + "。"
        let outcome = DiscoveryEvidenceBuilder.segment(text: text)
        XCTAssertTrue(outcome.blocks.isEmpty)
        XCTAssertEqual(outcome.droppedBlockCount, 1, "无法不切断从句地成块 → 整句弃用")
    }

    func test_切块_quoteLocator带回UTF16范围() {
        let text = "第一句话。第二句话比较长一些，包含逗号。"
        let batch = build([thoughtSnapshot(id: "t1", text: text, occurredAt: date(2026, 10, 10))])
        let first = batch.atoms.first { $0.sourceKind != .computedFact }!
        XCTAssertTrue(first.quoteLocator!.hasPrefix("utf16:0-"), "定位串带原文 UTF-16 范围")
        let text2 = thoughtSnapshot(id: "t1", text: text, occurredAt: date(2026, 10, 10))
        XCTAssertEqual(text2.text.utf16.count, text.utf16.count)
    }

    // MARK: - coverage

    func test_coverage_字段如实透传() {
        let snapshots = [thoughtSnapshot(id: "t1", text: "一句话。", occurredAt: date(2026, 10, 10))]
        let batch = DiscoveryEvidenceBuilder().buildAtoms(
            from: snapshots,
            coverageInput: DiscoveryCoverageInput(
                domains: [.thought, .habit],
                windowStart: date(2026, 10, 1), windowEnd: date(2026, 10, 23),
                matchedBlockCount: 8, truncatedBlockCount: 3,
                denominatorKnown: false, indexVersion: nil
            ),
            accessRevision: "a", calendar: shanghaiCalendar, now: fixedNow
        )
        XCTAssertEqual(batch.coverage.matchedCount, 8)
        XCTAssertEqual(batch.coverage.usedCount, 1)
        XCTAssertEqual(batch.coverage.truncatedCount, 3)
        XCTAssertFalse(batch.coverage.denominatorKnown, "习惯域分母未知（F14：缺记录 ≠ 没做）")
        XCTAssertEqual(batch.coverage.domains, [.thought, .habit])
    }

    // MARK: - fixtures（#filePath 定位，缺文件 XCTSkip）

    private static let planDirectory = "docs/_common/plans/2026-10-23-holo-ai-discovery-implementation"

    private func loadFixtures() throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent(Self.planDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let url = candidate.appendingPathComponent("synthetic-fixtures.json")
                guard let data = try? Data(contentsOf: url) else { break }
                return data
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("未定位到 synthetic-fixtures.json，跳过 fixture 语义用例")
    }

    private struct FixtureEvidence {
        let id: String
        let domain: String
        let occurredAt: String?
        let recordedAt: String?
        let lineage: String
        let text: String
    }

    private func fixtureCase(id: String) throws -> (name: String, evidence: [FixtureEvidence]) {
        let object = try JSONSerialization.jsonObject(with: loadFixtures()) as? [String: Any]
        let cases = try XCTUnwrap(object?["cases"] as? [[String: Any]])
        let target = try XCTUnwrap(cases.first { ($0["id"] as? String) == id })
        let evidence = try XCTUnwrap(target["evidence"] as? [[String: Any]]).map {
            FixtureEvidence(
                id: $0["id"] as? String ?? "",
                domain: $0["domain"] as? String ?? "thought",
                occurredAt: $0["occurredAt"] as? String,
                recordedAt: $0["recordedAt"] as? String,
                lineage: $0["lineage"] as? String ?? "",
                text: $0["text"] as? String ?? ""
            )
        }
        return (target["name"] as? String ?? "", evidence)
    }

    /// fixture 的 lineage 字段映射为共享事件锚：同 lineage = 同一底层事件（同 anchor）。
    /// derivedReport 等非三域来源直接排除——模型摘要不是独立证据，V1 不会进入快照
    /// （02 §2.2；此前 default 分支把它当 thought 是测试漏洞）。
    private func snapshotsFromFixture(_ evidence: [FixtureEvidence]) -> [DiscoverySourceSnapshot] {
        evidence.compactMap { item in
            guard item.domain == "thought" || item.domain == "task" || item.domain == "habit" else { return nil }
            let occurred = item.occurredAt.flatMap { fixtureDate($0) }
            switch item.domain {
            case "task":
                return taskSnapshot(id: "fx-\(item.id)", title: item.text, completedAt: occurred, anchors: ["fixture:\(item.lineage)"])
            case "habit":
                return habitSnapshot(id: "fx-\(item.id)", habitID: "fx-habit", occurredAt: occurred ?? fixedNow, retroactive: false, text: item.text)
            default:
                return thoughtSnapshot(id: "fx-\(item.id)", text: item.text, occurredAt: occurred, anchors: ["fixture:\(item.lineage)"])
            }
        }
    }

    /// fixture 日期 "2026-10-12" / 区间 "2026-10-01/2026-10-07"（区间取起点，只知日期）
    private func fixtureDate(_ raw: String) -> Date? {
        let day = raw.split(separator: "/").first.map(String.init) ?? raw
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return date(parts[0], parts[1], parts[2], 12)
    }

    func test_Fixture_F04_同一事件跨来源重复计数_独立计数为1() throws {
        let (_, evidence) = try fixtureCase(id: "F04")
        let snapshots = snapshotsFromFixture(evidence)
        XCTAssertEqual(snapshots.count, 2, "derivedReport 非三域来源，不进快照")
        let batch = build(snapshots, domains: [.thought, .task])
        XCTAssertEqual(batch.independentEventCount, 1, "fixture F04：同一底层事件不因跨来源而 ×3")
    }

    func test_Fixture_F13_发生日期不明_不伪造精确先后() throws {
        let (_, evidence) = try fixtureCase(id: "F13")
        let snapshots = snapshotsFromFixture(evidence)
        let batch = build(snapshots)
        let unknownAtom = batch.atoms.first { $0.sourceBlock.contains("很久以前") }
        let knownAtom = batch.atoms.first { $0.sourceBlock.contains("今晚先读两页") }
        XCTAssertEqual(unknownAtom?.occurredRange.precision, .unknown)
        XCTAssertEqual(knownAtom?.occurredRange.precision, .day)
    }

    func test_Fixture_F01_两次独立经历_计数为2() throws {
        let (_, evidence) = try fixtureCase(id: "F01")
        let batch = build(snapshotsFromFixture(evidence))
        XCTAssertEqual(batch.independentEventCount, 2, "不同日期、不同 lineage 的两次经历是两个独立事件")
        XCTAssertEqual(batch.independentGroupLabels, ["L01", "L02"])
    }
}
