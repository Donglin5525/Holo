//
//  ThoughtFollowupSampling.swift
//  Holo
//
//  想法脉络核对的采样/分层/窗口/taskKey 纯函数（W2，2026-11-16 方案 §5 B1/B2）
//
//  输入全部是值快照（actor 外传值，§6 C3「对象跨 actor 仅传值快照」），不触碰
//  Core Data、网络与存储——独立成文件便于 standalone 单测。正文一律传**已脱敏**
//  全文（调用方先过 ThoughtIndexV2Policy.redactedText），窗口 offset 按脱敏全文
//  的 UTF-16 坐标计算，且不截断 surrogate pair。
//

import Foundation
import CryptoKit

nonisolated enum ThoughtFollowupSampling {

    // MARK: - 常量（与后端 FOLLOWUP_LIMITS 对齐，§6 C2）

    /// 入池上限（三段合计，§5 B1）
    static let poolLimit = 120
    /// 每段上限（较早/中段/较新，§5 B1）
    static let segmentLimit = 40
    /// 每锚点召回候选上限（§5 B1）
    static let candidatesPerAnchor = 4
    /// 单窗口上限（UTF-16，§5 B1）
    static let windowMaxUTF16 = 600
    /// 每条笔记窗口数上限（§6 C2 windowsPerNoteMax）
    static let windowsPerNote = 2

    // MARK: - 输入快照

    /// 合规成员的值快照：过滤（未删未归档、AI 可见、非空正文）在调用方完成，
    /// 这里只负责排位、召回与窗口（避免先取前几条再丢弃导致漏召回，§5 B1）。
    struct NoteSnapshot: Equatable {
        var thoughtID: UUID
        var createdAt: Date
        var contentHash: String
        /// 已脱敏全文；窗口与摘要都从它派生
        var redactedText: String
        /// 现有向量快照；缺失的成员不参与相似度召回（复用已有入队补向量，§5 B1）
        var vector: [Float]?
    }

    /// 选出的连续窗口：offset 是脱敏全文的 UTF-16 起点，文本按字符边界截取。
    struct Window: Equatable, Codable {
        var ref: String
        var offsetUTF16: Int
        var text: String
        var lengthUTF16: Int { text.utf16.count }
    }

    // MARK: - 时间分层入池（§5 B1）

    /// 轻量分层采样（只依赖 ID/日期）：协调器先对全量合规成员做这一步，
    /// 只对采样出的 ≤120 条加载正文与向量（§5 B1「取到样本后再加载有限正文」）。
    /// 分段与等距规则与 segmentedPool 完全一致。
    static func sampleMemberSlice(_ members: [(id: UUID, createdAt: Date)])
        -> (early: [(id: UUID, createdAt: Date)], middle: [(id: UUID, createdAt: Date)], recent: [(id: UUID, createdAt: Date)]) {
        let ordered = members.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let count = ordered.count
        let earlyEnd = count / 3
        let middleEnd = count * 2 / 3
        return (equidistant(Array(ordered[..<earlyEnd])),
                equidistant(Array(ordered[earlyEnd..<middleEnd])),
                equidistant(Array(ordered[middleEnd...])))
    }

    /// 按创建时间升序、稳定 ID 平局排序后分为数量近似的较早/中段/较新三段，
    /// 各段至多 40 条：段内索引等距取样并保留首尾，不足按实际数量。
    static func segmentedPool(_ notes: [NoteSnapshot])
        -> (early: [NoteSnapshot], middle: [NoteSnapshot], recent: [NoteSnapshot]) {
        let ordered = notes.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.thoughtID.uuidString < $1.thoughtID.uuidString
        }
        let count = ordered.count
        let earlyEnd = count / 3
        let middleEnd = count * 2 / 3
        return (equidistant(Array(ordered[..<earlyEnd])),
                equidistant(Array(ordered[earlyEnd..<middleEnd])),
                equidistant(Array(ordered[middleEnd...])))
    }

    /// 段内等距取样至 segmentLimit 条，保留首尾（§5 B1；分母 limit-1 保证首尾都选中）。
    private static func equidistant<T>(_ segment: [T]) -> [T] {
        guard segment.count > segmentLimit else { return segment }
        var picked: [T] = []
        var lastOffset = -1
        for index in 0..<segmentLimit {
            let offset = Int((Double(index) * Double(segment.count - 1) / Double(segmentLimit - 1)).rounded())
            guard offset != lastOffset else { continue }
            lastOffset = offset
            picked.append(segment[offset])
        }
        return picked
    }

    // MARK: - 锚点候选召回（§5 B1）

    /// 每个待核对锚点从同主题笔记召回最多 4 条相似度过门槛的候选：
    /// 优先较早、中段各一名，剩余按相似度和时间稳定选择。
    /// 过滤：锚点自身、相同全文 hash、规范化后相同文本（不同时作为独立成员）、
    /// 拒绝 pair、相似度低于下限、向量缺失。
    static func recallCandidates(anchor: NoteSnapshot,
                                 early: [NoteSnapshot],
                                 middle: [NoteSnapshot],
                                 recent: [NoteSnapshot],
                                 rejectedPairIDs: Set<UUID>,
                                 minCosine: Float,
                                 maxCount: Int = candidatesPerAnchor) -> [NoteSnapshot] {
        guard let anchorVector = anchor.vector else { return [] }
        let anchorNormalized = normalizedDigest(anchor.redactedText)
        var seenHashes: Set<String> = [anchor.contentHash]
        var seenDigests: Set<String> = [anchorNormalized]
        // (候选, 相似度, 段序)：段序 0=较早 1=中段 2=较新，只用于前两名的保底选择
        var eligible: [(note: NoteSnapshot, cosine: Float, segment: Int)] = []
        for (segment, group) in [(0, early), (1, middle), (2, recent)] {
            for note in group {
                guard note.thoughtID != anchor.thoughtID,
                      !rejectedPairIDs.contains(note.thoughtID),
                      let vector = note.vector,
                      !seenHashes.contains(note.contentHash) else { continue }
                let digest = normalizedDigest(note.redactedText)
                guard !seenDigests.contains(digest) else { continue }
                seenHashes.insert(note.contentHash)
                seenDigests.insert(digest)
                let cosine = cosine(vector, anchorVector)
                guard cosine >= minCosine else { continue }
                eligible.append((note, cosine, segment))
            }
        }
        guard !eligible.isEmpty else { return [] }
        // 段内稳定排序：相似度降序 → 创建时间升序 → 稳定 ID
        func rank(_ a: (note: NoteSnapshot, cosine: Float, segment: Int),
                  _ b: (note: NoteSnapshot, cosine: Float, segment: Int)) -> Bool {
            if a.cosine != b.cosine { return a.cosine > b.cosine }
            if a.note.createdAt != b.note.createdAt { return a.note.createdAt < b.note.createdAt }
            return a.note.thoughtID.uuidString < b.note.thoughtID.uuidString
        }
        var picked: [NoteSnapshot] = []
        var pickedIDs = Set<UUID>()
        // 较早与中段各保底一名（§5 B1「优先留较早和中段各一名」）
        for segment in [0, 1] {
            if let best = eligible.filter({ $0.segment == segment && !pickedIDs.contains($0.note.thoughtID) })
                .sorted(by: rank).first {
                picked.append(best.note)
                pickedIDs.insert(best.note.thoughtID)
            }
        }
        // 剩余名额按相似度与时间稳定补足
        for entry in eligible.sorted(by: rank) where picked.count < maxCount {
            guard !pickedIDs.contains(entry.note.thoughtID) else { continue }
            picked.append(entry.note)
            pickedIDs.insert(entry.note.thoughtID)
        }
        return Array(picked.prefix(maxCount))
    }

    /// 规范化文本摘要（trim 外缘空白后 hash）：「标准化后相同的摘录不同时作为独立成员」（§5 B1）。
    static func normalizedDigest(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    // MARK: - 窗口选择（§5 B1）

    /// 锚点头尾文本（长文锚点的两个窗口）：供非锚点笔记的第二窗口做重叠选段。
    static func anchorReferences(anchor: NoteSnapshot) -> (head: String, tail: String) {
        let text = anchor.redactedText
        guard text.utf16.count > windowMaxUTF16 else { return (text, text) }
        return (headWindow(of: text).text, tailWindow(of: text).text)
    }

    /// 一条笔记的送审窗口（已脱敏全文上计算）：
    /// · 短正文（≤600 UTF-16）取连续全文单窗口；
    /// · 长文至多两个不重叠 ≤600 窗口——头部固定 + 从剩余段按与锚点头尾的
    ///   去标点相邻双字符集合 Jaccard 选一段（稳定同分选较晚，无命中用末段）；
    /// · 锚点本身（isAnchor）用头尾两窗。
    static func windows(for note: NoteSnapshot, isAnchor: Bool, anchorHead: String = "", anchorTail: String = "") -> [Window] {
        let text = note.redactedText
        guard text.utf16.count > windowMaxUTF16 else {
            return [Window(ref: "W0", offsetUTF16: 0, text: text)]
        }
        let head = headWindow(of: text)
        if isAnchor {
            let tail = tailWindow(of: text)
            return [Window(ref: "W0", offsetUTF16: 0, text: head.text),
                    Window(ref: "W1", offsetUTF16: tail.offsetUTF16, text: tail.text)]
        }
        // 头窗边界与剩余段起点用同一索引切分，保证两窗不重叠（含 surrogate 回退场景）
        let split = index(utf16Offset: windowMaxUTF16, in: text)
        let remainder = String(text[split...])
        let chunks = ThoughtSemanticText.chunks(remainder, maxUTF16: windowMaxUTF16)
        guard !chunks.isEmpty else {
            return [Window(ref: "W0", offsetUTF16: 0, text: head.text)]
        }
        let headSet = bigramSet(anchorHead)
        let tailSet = bigramSet(anchorTail)
        // 与锚点头尾的最大重叠即该段分数；>= 保证稳定同分取较晚（§5 B1）
        var bestIndex = 0
        var bestScore = -1.0
        for (index, chunk) in chunks.enumerated() {
            let set = bigramSet(chunk.text)
            let score = max(jaccard(set, headSet), jaccard(set, tailSet))
            if score >= bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        // 没有命中（全 0）用末段；全 0 时 bestIndex 已被 >= 推到最后一个 0 分块，两者一致
        let chosen = chunks[bestIndex]
        let offset = split.utf16Offset(in: text) + chosen.offsetUTF16
        return [Window(ref: "W0", offsetUTF16: 0, text: head.text),
                Window(ref: "W1", offsetUTF16: offset, text: chosen.text)]
    }

    private struct SlicedWindow: Equatable {
        var offsetUTF16: Int
        var text: String
    }

    private static func headWindow(of text: String) -> SlicedWindow {
        let end = index(utf16Offset: windowMaxUTF16, in: text)
        return SlicedWindow(offsetUTF16: 0, text: String(text[..<end]))
    }

    /// 尾窗口：从末尾取 ≤600 UTF-16，起点不早于头窗结束（≤1200 的长文头尾收窄，
    /// 保证两窗不重叠，§5 B1），且落在字符边界（不拆 surrogate pair）。
    private static func tailWindow(of text: String) -> SlicedWindow {
        let startOffset = max(windowMaxUTF16, text.utf16.count - windowMaxUTF16)
        let start = index(utf16Offset: startOffset, in: text)
        return SlicedWindow(offsetUTF16: start.utf16Offset(in: text), text: String(text[start...]))
    }

    /// UTF-16 偏移 → 字符边界索引：落在 surrogate 中间时回退一个单位（不截断代理对，§5 B1）。
    private static func index(utf16Offset: Int, in text: String) -> String.Index {
        var offset = utf16Offset
        var idx = String.Index(utf16Offset: offset, in: text)
        while idx.samePosition(in: text) == nil, offset > 0 {
            offset -= 1
            idx = String.Index(utf16Offset: offset, in: text)
        }
        return idx
    }

    /// 去标点后相邻双字符集合（§5 B1「归一化字词重叠」的仓库内实现：
    /// 无可复用分词入口时按相邻双字符集合计 Jaccard）。
    static func bigramSet(_ text: String) -> Set<String> {
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(scalars)).lowercased()
        let units = Array(normalized.unicodeScalars)
        guard units.count >= 2 else { return units.isEmpty ? [] : [String(String.UnicodeScalarView([units[0]]))] }
        var result: Set<String> = []
        for i in 0..<(units.count - 1) {
            result.insert(String(String.UnicodeScalarView([units[i], units[i + 1]])))
        }
        return result
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    // MARK: - taskKey（§5 B2）

    /// 固定 taskKey = SHA256(canonical(scopeID, anchorID, sorted(noteID, hash,
    /// windowsDigest), policyVersion, redactionVersion, embeddingModelVersion))。
    /// 相同键的 verified/no_result 都是终态；输入局部变化（hash/窗口变化）自然另起新键。
    static func taskKey(scopeID: UUID,
                        anchorID: UUID,
                        notes: [(thoughtID: UUID, contentHash: String, windows: [Window])],
                        policyVersion: String,
                        redactionVersion: String,
                        embeddingModelVersion: String) -> String {
        let noteTokens = notes.map { note -> String in
            let windowsDigest = SHA256.hash(data: Data(
                note.windows
                    .map { "\($0.offsetUTF16):\($0.lengthUTF16)" }
                    .sorted()
                    .joined(separator: ",")
                .utf8))
                .prefix(8).map { String(format: "%02x", $0) }.joined()
            return "\(note.thoughtID.uuidString)|\(note.contentHash)|\(windowsDigest)"
        }
        .sorted()
        .joined(separator: "\u{1e}")
        let canonical = [
            scopeID.uuidString,
            anchorID.uuidString,
            noteTokens,
            policyVersion,
            redactionVersion,
            embeddingModelVersion,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 脉络卡形成（§5 B2，纯函数供 UI/协调器共用）

    /// 一条已核对脉络的展示输入：displayID 是独立 thread local UUID（不拿标题当身份）。
    struct ThreadCandidate: Equatable {
        var displayID: String
        var memberIDs: Set<UUID>
        /// 有效支持成员数（锚点 + 逐条有成立关系的成员）
        var supportCount: Int
        var latestEvidenceAt: Date
    }

    /// 已隐藏卡的回执快照（Dismissal 表行）：按展示 ID 或重叠条件压制新卡。
    struct ThreadDismissal: Equatable {
        var displayID: String
        var memberIDs: Set<UUID>
    }

    struct FormedThreadCard: Equatable {
        var displayID: String
        var memberIDs: Set<UUID>
        var supportCount: Int
        var latestEvidenceAt: Date
    }

    /// 脉络卡形成规则（§5 B2）：
    /// 1. 同一父主题下完全相同成员集合共用一个展示 ID，保留最近有效版本；
    /// 2. 交集 ≥2 且 Jaccard ≥0.6 按疑似重复压制展示（保留各自身份与证据，不删数据）；
    /// 3. 排序 = 有效支持数 → 最近证据时间 → 稳定 ID；每主题至多 2 张；
    /// 4. 每卡 ≥3 个独立支持成员；
    /// 5. 已隐藏的卡按展示 ID 或上述重叠条件先压制。
    static func formThreadCards(candidates: [ThreadCandidate],
                                dismissals: [ThreadDismissal],
                                limitPerTopic: Int = 2,
                                minSupport: Int = 3,
                                overlapJaccard: Double = 0.6) -> [FormedThreadCard] {
        // 1) 相同成员集合合并：共用展示 ID（取最近版本）
        var byMembers: [Set<UUID>: ThreadCandidate] = [:]
        for candidate in candidates {
            if let existing = byMembers[candidate.memberIDs] {
                if candidate.latestEvidenceAt > existing.latestEvidenceAt {
                    byMembers[candidate.memberIDs] = candidate
                }
            } else {
                byMembers[candidate.memberIDs] = candidate
            }
        }
        // 4) 每卡 ≥3 独立支持成员
        var pool = byMembers.values.filter { $0.supportCount >= minSupport }
        // 5) 已隐藏卡先压制：展示 ID 相同，或成员集交集 ≥2 且 Jaccard ≥0.6
        pool.removeAll { candidate in
            dismissals.contains { dismissal in
                dismissal.displayID == candidate.displayID || isSuspectedDuplicate(candidate.memberIDs, dismissal.memberIDs, threshold: overlapJaccard)
            }
        }
        // 3) 排序：支持数 → 最近证据时间 → 稳定 ID（displayID）
        pool.sort {
            if $0.supportCount != $1.supportCount { return $0.supportCount > $1.supportCount }
            if $0.latestEvidenceAt != $1.latestEvidenceAt { return $0.latestEvidenceAt > $1.latestEvidenceAt }
            return $0.displayID < $1.displayID
        }
        // 2) 候选间疑似重复压制 + 每主题至多 2 张
        var cards: [FormedThreadCard] = []
        for candidate in pool where cards.count < limitPerTopic {
            let duplicate = cards.contains { isSuspectedDuplicate(candidate.memberIDs, $0.memberIDs, threshold: overlapJaccard) }
            guard !duplicate else { continue }
            cards.append(FormedThreadCard(displayID: candidate.displayID,
                                          memberIDs: candidate.memberIDs,
                                          supportCount: candidate.supportCount,
                                          latestEvidenceAt: candidate.latestEvidenceAt))
        }
        return cards
    }

    /// 疑似重复判定：成员交集 ≥2 且 Jaccard ≥ 阈值（标题不参与判断，§5 B2）。
    static func isSuspectedDuplicate(_ a: Set<UUID>, _ b: Set<UUID>, threshold: Double = 0.6) -> Bool {
        let intersection = a.intersection(b).count
        guard intersection >= 2 else { return false }
        let union = a.union(b).count
        guard union > 0 else { return false }
        return Double(intersection) / Double(union) >= threshold
    }
}
