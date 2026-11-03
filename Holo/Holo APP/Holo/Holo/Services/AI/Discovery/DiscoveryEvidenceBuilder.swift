//
//  DiscoveryEvidenceBuilder.swift
//  Holo
//
//  「HoloAI 一个发现」G2：快照 → FactAtom（02 §2.2 / §2.4 / §3.2 末段）。
//
//  · 原文语义切块：每块 ≤ 约 400 汉字（硬上限 520，容纳「转折句必须随块保留」的溢出）；
//    只按句界（。！？；!?; 换行）切分，永不切断句子内部——否定词天然随句保留；
//    转折/条件/因果连接词开头的句子必须与前句同块，保不住（超硬上限）则弃用该句并记 coverage。
//    单句超硬上限无法在不切断从句的情况下成块 → 整句弃用并记 coverage（02 §3.2：
//    「切断造成含义不完整则不用该块」）。
//  · lineageGroup（02 §2.4 五条规则全实现）：
//    1. 有同一显式事件/实体关联（共享任一 eventAnchor，如同一任务 id）→ 归同组；
//    2. 无显式关联但原文高度相似（同一归一化口径下相等或包含，短端 ≥12 码元）
//       且时间重合（发生时间均已知且相差 ≤36h）→ 标 ambiguous，不能用来增加重复次数
//       （习惯事件之间不适用：构成文是模板文，规则 3 不同日期打卡即不同事件）；
//    3. 同一习惯不同日期的记录是不同事件（每条记录独立锚）；
//    4. 不同来源 ID / 不同数据域不自动当成独立性证明（独立计数只认 lineage 组）；
//    5. 证明不足可输出单次事实——builder 照常产出 atom，发布门槛归 G4。
//  · computedFacts 只做确定性计数：批内独立事件数（非 ambiguous 组数）、习惯显式数值。
//    不推断历史达标、不推断缺记录语义（F14：缺打卡不等于没做）。
//  · coverage：查询窗口/命中/采用/截断（含弃块）/分母是否已知（含习惯域时分母未知）。
//

import Foundation

// MARK: - coverage 输入

/// builder 聚合用 coverage 组件（matched/truncated 由检索层按通道聚合后传入）。
struct DiscoveryCoverageInput: Equatable, Sendable {
    var domains: [DiscoverySourceDomain] = []
    var windowStart: Date? = nil
    var windowEnd: Date? = nil
    /// 符合条件的块数（含未采用的）
    var matchedBlockCount: Int = 0
    /// 预算截断 + 因含义不完整弃用的块数
    var truncatedBlockCount: Int = 0
    /// 分母是否已知：习惯域缺记录 ≠ 没做（F14），含习惯材料即未知
    var denominatorKnown: Bool = true
    var indexVersion: String? = nil
}

// MARK: - 批输出

/// 一批快照产出的证据包。
struct DiscoveryEvidenceBatch: Equatable, Sendable {
    let atoms: [DiscoveryFactAtom]
    let coverage: DiscoveryFactAtom.Coverage
    /// 独立事件计数（02 §2.4：非 ambiguous 的 lineage 组数；ambiguous 不计入）
    let independentEventCount: Int
    /// 标了 ambiguous 的组数（诊断；发布门槛在 G4）
    let ambiguousGroupCount: Int
    /// 独立组的 lineage 标签（排序后；computedFact atom 不在内）
    let independentGroupLabels: [String]
}

// MARK: - Builder

struct DiscoveryEvidenceBuilder: Sendable {

    /// 切块参数（02 §3.2：每块建议不超过约 400 汉字）
    enum Segmentation {
        static let preferredBlockLength = 400
        /// 「约 400」的容差上限：转折句随块保留允许溢出到 520，超过则弃用
        static let hardBlockLength = 520
        /// 转折/条件/因果连接词：以此开头的句子不能脱离前句单独成块
        static let transitionLeads: [String] = [
            "但是", "但", "不过", "然而", "却", "可是", "只是", "其实", "反而", "倒是",
            "后来", "因为", "所以", "因此", "于是", "如果", "要是", "假如", "结果",
        ]
        /// 句界终止符（保持原字符不丢）
        static let sentenceTerminators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n", "\r"]
        /// 高度相似判定的最短包含长度（归一化码元）
        static let minSimilarLength = 12
        /// 时间重合窗口（小时）：疑似复述的时间上限
        static let similarTimeOverlapSeconds: TimeInterval = 36 * 3600
    }

    // MARK: 语义切块

    struct SegmentationOutcome: Equatable, Sendable {
        let blocks: [String]
        /// 每块在原文中的 UTF-16 范围（quoteLocator 与引用对齐块提示共用）
        let blockUTF16Ranges: [Range<Int>]
        /// 因切断致含义不完整而弃用的块数（进 coverage.truncatedCount）
        let droppedBlockCount: Int
    }

    /// 原文语义切块（纯函数）。
    static func segment(text: String) -> SegmentationOutcome {
        let sentences = splitSentences(text)

        var blocks: [String] = []
        var ranges: [Range<Int>] = []
        var dropped = 0
        var current = ""
        var currentStart: Int? = nil
        var currentEnd = 0

        func flush() {
            guard !current.isEmpty, let start = currentStart else { return }
            blocks.append(current)
            ranges.append(start..<currentEnd)
            current = ""
            currentStart = nil
        }

        for sentence in sentences {
            if sentence.text.allSatisfy({ $0.isWhitespace }) { continue }
            // 单句超硬上限：无法不切断从句地成块 → 整句弃用（不截否定）
            if sentence.text.count > Segmentation.hardBlockLength {
                flush()
                dropped += 1
                continue
            }
            let leadsWithTransition = Segmentation.transitionLeads.contains { sentence.text.hasPrefix($0) }
            if current.isEmpty {
                // 段首（含反例块常见的「后来/但是」起句）：不是切断，正常成块；
                // 跨块的上下文完整性由核验阶段看整段保证（02 §2.3 第 4 条）
                current = sentence.text
                currentStart = sentence.utf16Start
                currentEnd = sentence.utf16End
                continue
            }
            let combinedLength = current.count + sentence.text.count
            if combinedLength <= Segmentation.preferredBlockLength {
                current += sentence.text
                currentEnd = sentence.utf16End
                continue
            }
            if leadsWithTransition {
                if combinedLength <= Segmentation.hardBlockLength {
                    // 转折句必须随块保留：允许溢出到硬上限
                    current += sentence.text
                    currentEnd = sentence.utf16End
                    continue
                }
                // 与前句强绑但保不住同块 → 独立成块含义不完整 → 弃用并记 coverage
                dropped += 1
                flush()
                continue
            }
            flush()
            current = sentence.text
            currentStart = sentence.utf16Start
            currentEnd = sentence.utf16End
        }
        flush()
        return SegmentationOutcome(blocks: blocks, blockUTF16Ranges: ranges, droppedBlockCount: dropped)
    }

    private struct Sentence {
        let text: String
        let utf16Start: Int
        let utf16End: Int
    }

    /// 按句界终止符切句（终止符归属句尾；无终止符的尾句也算一句）
    private static func splitSentences(_ text: String) -> [Sentence] {
        var sentences: [Sentence] = []
        var buffer = ""
        var start = 0
        var cursor = 0
        for character in text {
            buffer.append(character)
            cursor += String(character).utf16.count
            if Segmentation.sentenceTerminators.contains(character) {
                sentences.append(Sentence(text: buffer, utf16Start: start, utf16End: cursor))
                buffer = ""
                start = cursor
            }
        }
        if !buffer.isEmpty {
            sentences.append(Sentence(text: buffer, utf16Start: start, utf16End: cursor))
        }
        return sentences
    }

    // MARK: 快照 → FactAtom

    /// 一批快照 → 证据包。快照顺序即通道优先级顺序（变化对象在前），
    /// evidenceID（E01…）按该顺序分配，确定性可复算。
    func buildAtoms(
        from snapshots: [DiscoverySourceSnapshot],
        coverageInput: DiscoveryCoverageInput,
        accessRevision: String,
        calendar: Calendar,
        now: Date,
        evidenceIDPrefix: String = "E"
    ) -> DiscoveryEvidenceBatch {
        // 1) 切块 + evidenceID 分配
        struct BlockUnit {
            let snapshotIndex: Int
            let snapshot: DiscoverySourceSnapshot
            let block: String
            let utf16Range: Range<Int>
        }
        var blockUnits: [BlockUnit] = []
        var droppedBlockCount = 0
        for (index, snapshot) in snapshots.enumerated() {
            let outcome = Self.segment(text: snapshot.text)
            droppedBlockCount += outcome.droppedBlockCount
            for (blockIndex, block) in outcome.blocks.enumerated() {
                blockUnits.append(BlockUnit(
                    snapshotIndex: index,
                    snapshot: snapshot,
                    block: block,
                    utf16Range: outcome.blockUTF16Ranges[blockIndex]
                ))
            }
        }
        func evidenceID(_ ordinal: Int) -> String {
            String(format: "%@%02d", evidenceIDPrefix, ordinal)
        }

        // 2) coverage（usedCount=实际产出块数；含丢弃块计入截断）
        let coverage = DiscoveryFactAtom.Coverage(
            domains: coverageInput.domains,
            windowStart: coverageInput.windowStart,
            windowEnd: coverageInput.windowEnd,
            matchedCount: coverageInput.matchedBlockCount,
            usedCount: blockUnits.count,
            truncatedCount: coverageInput.truncatedBlockCount + droppedBlockCount,
            denominatorKnown: coverageInput.denominatorKnown,
            indexVersion: coverageInput.indexVersion
        )

        // 3) 血缘判定（§2.4）
        let lineage = Self.lineageAssignments(for: snapshots)
        var ordinal = 1
        var atoms: [DiscoveryFactAtom] = []
        var numericFactsBySnapshot: [Int: DiscoveryFactAtom.ComputedFact] = [:]
        for unit in blockUnits {
            var atom = DiscoveryFactAtom(
                localSourceRef: unit.snapshot.localSourceRef,
                sourceRevision: unit.snapshot.sourceRevision,
                evidenceID: evidenceID(ordinal),
                sourceKind: unit.snapshot.kind,
                occurredRange: Self.occurredRange(of: unit.snapshot, calendar: calendar),
                recordedAt: unit.snapshot.recordedAt,
                sourceBlock: unit.block,
                quoteLocator: "utf16:\(unit.utf16Range.lowerBound)-\(unit.utf16Range.upperBound)",
                lineageGroup: lineage.lineage(of: unit.snapshotIndex),
                entityRefs: unit.snapshot.entityRefs,
                coverage: coverage,
                accessRevision: accessRevision,
                computedFacts: []
            )
            // 显式记录的数值（习惯数值型）：挂在首块（定量结论只能引用 computedFact）
            if unit.snapshot.numericValue != nil,
               numericFactsBySnapshot[unit.snapshotIndex] == nil,
               let fact = Self.recordedValueFact(of: unit.snapshot, calendar: calendar) {
                numericFactsBySnapshot[unit.snapshotIndex] = fact
                atom.computedFacts = [fact]
            }
            atoms.append(atom)
            ordinal += 1
        }

        // 4) 确定性独立事件计数（§5 门禁 6：定量由程序算，不让模型自由计算）
        let independentFact = DiscoveryFactAtom.ComputedFact(
            metricID: "independent_events",
            formulaVersion: "count_v1",
            numerator: Double(lineage.independentGroupCount),
            denominator: nil,
            unit: "events",
            windowStart: coverageInput.windowStart,
            windowEnd: coverageInput.windowEnd,
            value: Double(lineage.independentGroupCount)
        )
        let computedAtom = DiscoveryFactAtom(
            localSourceRef: nil,
            sourceRevision: DiscoveryContentDigest.sourceRevision(
                from: ["discovery.computed.independent_events.v1"]
                    + snapshots.map(\.sourceRevision).sorted()
            ),
            evidenceID: evidenceID(ordinal),
            sourceKind: .computedFact,
            occurredRange: DiscoveryFactAtom.OccurredRange(
                start: coverageInput.windowStart,
                end: coverageInput.windowEnd,
                precision: coverageInput.windowStart == nil ? .unknown : .day
            ),
            recordedAt: now,
            sourceBlock: "",
            quoteLocator: nil,
            lineageGroup: .group("computed"),
            entityRefs: [],
            coverage: coverage,
            accessRevision: accessRevision,
            computedFacts: [independentFact]
        )
        atoms.append(computedAtom)

        return DiscoveryEvidenceBatch(
            atoms: atoms,
            coverage: coverage,
            independentEventCount: lineage.independentGroupCount,
            ambiguousGroupCount: lineage.ambiguousGroupCount,
            independentGroupLabels: lineage.independentGroupLabels
        )
    }

    // MARK: - 发生时间（T31：只用已知精度，不编时刻）

    static func occurredRange(of snapshot: DiscoverySourceSnapshot, calendar: Calendar) -> DiscoveryFactAtom.OccurredRange {
        guard let occurred = snapshot.occurredAt else {
            // F13：发生时间未知（如想法缺 occurredAt 口径之外的材料）→ 不伪造
            return DiscoveryFactAtom.OccurredRange(start: nil, end: nil, precision: .unknown)
        }
        if snapshot.occurredOnlyDateKnown {
            // 补签：date=目标日零点是写入约定，只知道日期 → 日区间，零点不是真实时刻
            let dayStart = calendar.startOfDay(for: occurred)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            return DiscoveryFactAtom.OccurredRange(start: dayStart, end: dayEnd, precision: .day)
        }
        return DiscoveryFactAtom.OccurredRange(start: occurred, end: occurred, precision: .day)
    }

    /// 显式数值事实（只引用记录值本身；不与目标比较——T32：不推断历史达标）
    private static func recordedValueFact(of snapshot: DiscoverySourceSnapshot, calendar: Calendar) -> DiscoveryFactAtom.ComputedFact? {
        guard let value = snapshot.numericValue else { return nil }
        let dayStart = snapshot.occurredAt.map { calendar.startOfDay(for: $0) }
        let dayEnd = dayStart.map { calendar.date(byAdding: .day, value: 1, to: $0) ?? $0 }
        return DiscoveryFactAtom.ComputedFact(
            metricID: "recorded_value",
            formulaVersion: "record_v1",
            numerator: value,
            denominator: nil,
            unit: snapshot.numericUnit,
            windowStart: dayStart,
            windowEnd: dayEnd,
            value: value
        )
    }

    // MARK: - 血缘判定（§2.4 五条规则）

    struct LineageAssignment {
        let labels: [String]                 // labels[snapshotIndex] = 组标签
        let ambiguousFlags: [Bool]
        let independentGroupCount: Int
        let ambiguousGroupCount: Int
        let independentGroupLabels: [String]

        func lineage(of index: Int) -> DiscoveryFactAtom.Lineage {
            ambiguousFlags[index] ? .ambiguous : .group(labels[index])
        }
    }

    static func lineageAssignments(for snapshots: [DiscoverySourceSnapshot]) -> LineageAssignment {
        let count = snapshots.count

        // 规则 1：共享任一显式事件锚 → 同组（union-find）
        var parent = Array(0..<max(count, 1))
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var current = index
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }
        var anchorOwners: [String: Int] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            for anchor in snapshot.eventAnchors {
                if let owner = anchorOwners[anchor] {
                    union(owner, index)
                } else {
                    anchorOwners[anchor] = index
                }
            }
        }

        // 规则 2：无显式关联但原文高度相似 + 时间重合 → ambiguous（不 union、不计独立）
        var ambiguousFlags = [Bool](repeating: false, count: count)
        let normalizedKeys = snapshots.map { DiscoveryQuoteAlignment.normalizedKey($0.text) }
        for i in 0..<count {
            for j in (i + 1)..<count {
                if find(i) == find(j) { continue }   // 已有显式同组，不叠加 ambiguity
                // §2.4 规则 3：同一习惯不同日期的真实打卡是不同事件。习惯事件的 text 是
                // 适配器构成的模板文（习惯名+动作+数值），逐字相同是模板使然，不是自由
                // 原文的复述；且每条记录自带唯一 habitEvent 锚（显式身份）——相似度
                // 启发式不适用于习惯事件之间，否则每天打卡全被并成一个 ambiguous。
                if snapshots[i].kind == .habitEvent && snapshots[j].kind == .habitEvent { continue }
                if isHighlySimilar(normalizedKeys[i], normalizedKeys[j]),
                   isTimeOverlapping(snapshots[i].occurredAt, snapshots[j].occurredAt) {
                    ambiguousFlags[i] = true
                    ambiguousFlags[j] = true
                }
            }
        }

        // 组标签按首个成员顺序分配（L01…；确定性）
        var rootLabels: [Int: String] = [:]
        let labels: [String] = (0..<count).map { index in
            let root = find(index)
            if let label = rootLabels[root] { return label }
            let label = String(format: "L%02d", rootLabels.count + 1)
            rootLabels[root] = label
            return label
        }

        // 计数：无 ambiguous 成员的组 = 独立组；否则 ambiguous 组
        var independentRoots: Set<Int> = []
        var ambiguousRoots: Set<Int> = []
        for index in 0..<count {
            let root = find(index)
            if ambiguousFlags[index] {
                ambiguousRoots.insert(root)
                independentRoots.remove(root)
            } else if !ambiguousRoots.contains(root) {
                independentRoots.insert(root)
            }
        }
        let independentLabels = independentRoots
            .compactMap { rootLabels[$0] }
            .sorted()

        return LineageAssignment(
            labels: labels,
            ambiguousFlags: ambiguousFlags,
            independentGroupCount: independentRoots.count,
            ambiguousGroupCount: ambiguousRoots.count,
            independentGroupLabels: independentLabels
        )
    }

    /// 原文高度相似（确定性，无模糊相似度）：
    /// 同一归一化口径（DiscoveryQuoteAlignment.normalizedKey）下相等，或短端 ≥12 码元被长端完整包含。
    private static func isHighlySimilar(_ keyA: String, _ keyB: String) -> Bool {
        if keyA == keyB { return !keyA.isEmpty }
        let shorter = keyA.count <= keyB.count ? keyA : keyB
        let longer = keyA.count <= keyB.count ? keyB : keyA
        guard shorter.count >= Segmentation.minSimilarLength else { return false }
        return longer.contains(shorter)
    }

    /// 时间重合：双方发生时间均已知且相差 ≤ 36h（缺发生时间不能声称重合，F13）
    private static func isTimeOverlapping(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) <= Segmentation.similarTimeOverlapSeconds
    }
}
