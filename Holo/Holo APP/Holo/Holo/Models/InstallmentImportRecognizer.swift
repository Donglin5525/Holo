//
//  InstallmentImportRecognizer.swift
//  Holo
//
//  外部账单/CSV 导入的分期识别与归组。
//
//  两类信号：
//  - 强信号（显式分期列、备注中带「期」字的分期写法）→ 自动归组；
//  - 弱信号（同账户同金额的月度重复行，可能是房租/订阅）→ 仅产出疑似组，
//    预览页用户确认后才归组，绝不自动判定。
//
//  归组只串联文件中已存在的行，不凭空补造未来期次；
//  未来日期的期次落库后由 FinanceTransactionOccurrencePolicy 排除在统计外。
//
//  备注文本识别须带「期」字或「分期」字样——裸「3/12」在中文备注里更可能是日期，不认。
//

import Foundation

enum InstallmentImportRecognizer {

    // MARK: - 信号模型

    /// 一行解析出的分期信号：期次与总期数，至少其一
    struct Signal {
        let index: Int?
        let total: Int?
    }

    /// 扫描期收集的轻量候选行（归组输入；信号为 nil 的行也参与弱信号序列检测）
    struct CandidateRow {
        /// 过滤后数据行号（1-based，与扫描/导入两侧口径一致）
        let row: Int
        let date: Date
        let type: TransactionType
        let amount: Decimal
        let accountName: String
        let signal: Signal?
    }

    /// 归组结论：某行属于哪个分期组的第几期
    struct Assignment: Equatable {
        let groupId: UUID
        let index: Int
        let total: Int
    }

    /// 预览展示用的分期组摘要
    struct GroupSummary: Identifiable, Equatable {
        let id: UUID
        let rowCount: Int
        let total: Int
        let firstIndex: Int
        let lastIndex: Int
        let amount: Decimal
        let firstDate: Date
        let lastDate: Date
        /// 日期晚于导入时刻的行数（落库后不计入统计，到期后自动出现）
        let futureCount: Int
    }

    /// 弱信号检出的疑似分期组（用户确认后按日期序 1...N 归组）
    struct SuspectedGroup: Identifiable, Equatable {
        let id = UUID()
        let rows: [Int]
        let amount: Decimal
        let accountName: String
        let firstDate: Date
        let lastDate: Date
        static func == (lhs: SuspectedGroup, rhs: SuspectedGroup) -> Bool { lhs.id == rhs.id }
    }

    /// 识别总产出
    struct Outcome {
        /// 强信号自动归组的行号 → 赋值
        let assignments: [Int: Assignment]
        let groups: [GroupSummary]
        let suspected: [SuspectedGroup]
        /// 带分期信号但未能成组的行数（冲突降级、单行信号等），信息保留在备注中不丢失
        let ungroupedSignalCount: Int
    }

    // 原生分期期数上限（与 FinanceRepository.addInstallmentTransactions / IntentRouter 口径一致）
    static let maxPeriods = 36
    static let minPeriods = 2

    // MARK: - 信号解析

    /// 备注文本中的分期写法。须带「期」字（或「分期」字样）才认，按优先级首个命中即返回：
    /// 1. 3/12期、第3/12期、3-12期 → (期次, 总数)
    /// 2. 第3期/共12期、第3期共12期 → (期次, 总数)
    /// 3. [分期 3/12]、分期3/12（HOLO 历史前缀，无「期」尾字，靠「分期」消歧）→ (期次, 总数)
    /// 4. 第3期 → (期次, nil)
    /// 5. 共12期 / 12期 → (nil, 总数)
    static func parseSignal(from text: String) -> Signal? {
        guard !text.isEmpty else { return nil }
        for (pattern, hasIndex, hasTotal) in notePatterns {
            let (group1, group2) = firstMatch(text: text, pattern: pattern)
            let index = hasIndex ? group1 : nil
            let total = hasTotal ? group2 : nil
            if index != nil || total != nil {
                return Signal(index: index, total: total)
            }
        }
        return nil
    }

    /// 显式分期列值解析。列名已声明语义，可比备注宽松：
    /// - "3/12"（HOLO 导出）、"3-12" → (期次, 总数)
    /// - 备注正则能命中的文本（"第3期/共12期" 等）照常识别
    /// - 纯数字 "12" → (nil, 总数)
    static func parseColumnValue(_ raw: String) -> Signal? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let signal = parseSignal(from: s) {
            return signal
        }
        let (bareIndex, bareTotal) = firstMatch(text: s, pattern: barePairPattern)
        if let bareIndex, let bareTotal {
            return Signal(index: bareIndex, total: bareTotal)
        }
        if s.count <= 2, let total = Int(s) {
            return Signal(index: nil, total: total)
        }
        return nil
    }

    private static let barePairPattern = #"^\s*(\d{1,2})\s*[/／\-－]\s*(\d{1,2})\s*$"#

    /// (正则, 是否取第一组为期次, 是否取第二组为总数)；单边模式用空捕获组 `()` 占位
    private static let notePatterns: [(pattern: String, hasIndex: Bool, hasTotal: Bool)] = [
        (#"第?\s*(\d{1,2})\s*[/／\-－]\s*(\d{1,2})\s*期"#, true, true),
        (#"第\s*(\d{1,2})\s*期\s*[/／]?\s*共?\s*(\d{1,2})\s*期"#, true, true),
        (#"分期\s*(\d{1,2})\s*[/／]\s*(\d{1,2})"#, true, true),
        (#"第\s*(\d{1,2})\s*期()"#, true, false),
        (#"(?:共\s*)?()(\d{1,2})\s*期"#, false, true),
    ]

    private static func firstMatch(text: String, pattern: String) -> (Int?, Int?) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (nil, nil) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges >= 3 else {
            return (nil, nil)
        }
        return (
            m.range(at: 1).captureGroupInt(in: text),
            m.range(at: 2).captureGroupInt(in: text)
        )
    }

    // MARK: - 归组

    /// 对扫描收集的候选行做归组判定
    ///
    /// 强信号归组算法：
    /// 1. 取「总数已知且在 2...36」的行，按 (类型, 账户, 总数) 分桶；
    /// 2. 桶内按金额精确分组——金额是隐含的组边界（两个不同商品的分期金额不同，
    ///    而同一分期的末期尾差金额与主金额接近）；
    /// 3. 金额组内期次必须唯一且在 1...总数 内；仅有总数无期次的行在整组都无期次时
    ///    按日期顺序补推期次，混合出现时以带期次的行为准；
    /// 4. 相邻金额组差值在尾差容忍带（max(2, 金额×2%)）内时合并回同一分期；
    /// 5. 按期次排序后日期须非严格递增（第3期不能晚于第5期），违反整组降级；
    /// 6. 有效组至少 2 行。
    ///
    /// 弱信号（序列检测）：无信号行按 (类型, 账户, 金额) 分桶，桶内按日期排序，
    /// 相邻间隔 25...38 天链式相连，链长 ≥3 产出疑似组（房租/订阅同样命中，故只提示不归组）。
    static func resolve(candidates: [CandidateRow], now: Date = Date()) -> Outcome {
        var assignments: [Int: Assignment] = [:]
        var groups: [GroupSummary] = []
        var ungrouped = 0

        // --- 强信号分桶 ---
        // key: (类型, 账户, 总数) → 金额组字典（金额字符串精确键）
        var strongBuckets: [String: [Decimal: [CandidateRow]]] = [:]
        for candidate in candidates {
            guard let signal = candidate.signal,
                  let total = signal.total,
                  (minPeriods...maxPeriods).contains(total) else {
                if candidate.signal != nil { ungrouped += 1 }
                continue
            }
            // 有期次但越界的行信号无效
            if let index = signal.index, !(1...total).contains(index) {
                ungrouped += 1
                continue
            }
            let key = "\(candidate.type.rawValue)|\(candidate.accountName)|\(total)"
            strongBuckets[key, default: [:]][candidate.amount, default: []].append(candidate)
        }

        for (_, amountGroups) in strongBuckets {
            let mergedGroups = mergeAdjacentAmounts(amountGroups)
            for members in mergedGroups {
                if let (assignmentMap, summary) = formGroup(from: members, now: now) {
                    assignments.merge(assignmentMap) { current, _ in current }
                    groups.append(summary)
                } else {
                    ungrouped += members.count
                }
            }
        }

        groups.sort { $0.firstDate < $1.firstDate }

        // --- 弱信号序列检测（只出疑似组，不写 assignments） ---
        let suspected = detectSuspectedSequences(
            in: candidates.filter { $0.signal == nil }
        )

        return Outcome(
            assignments: assignments,
            groups: groups,
            suspected: suspected,
            ungroupedSignalCount: ungrouped
        )
    }

    /// 金额组间尾差合并：按组内最早日期排序后，相邻组差值在容忍带内则合并（末期吸收尾差的金额与主金额略不同）
    private static func mergeAdjacentAmounts(_ amountGroups: [Decimal: [CandidateRow]]) -> [[CandidateRow]] {
        let sorted = amountGroups.sorted { ($0.value.map(\.date).min() ?? .distantPast) < ($1.value.map(\.date).min() ?? .distantPast) }
        var result: [[CandidateRow]] = []
        var pending: [(amount: Decimal, members: [CandidateRow])] = []

        for (amount, members) in sorted {
            if let last = pending.last,
               abs(amount - last.amount) <= tailTolerance(around: min(amount, last.amount)) {
                pending[pending.count - 1].members.append(contentsOf: members)
            } else {
                pending.append((amount, members))
            }
        }
        for (_, members) in pending {
            result.append(members.sorted { $0.date < $1.date })
        }
        return result
    }

    private static func tailTolerance(around amount: Decimal) -> Decimal {
        let twoPercent = amount * Decimal(string: "0.02")!
        return max(Decimal(2), twoPercent)
    }

    /// 尝试把同金额（或已合并尾差）的一组成员组成分期组；失败返回 nil（调用方计 ungrouped）
    private static func formGroup(from members: [CandidateRow], now: Date) -> ([Int: Assignment], GroupSummary)? {
        guard members.count >= minPeriods else { return nil }

        let withIndex = members.filter { $0.signal?.index != nil }
        let withoutIndex = members.filter { $0.signal?.index == nil }

        var ordered: [CandidateRow]
        if withIndex.isEmpty {
            // 整组都只有总数：按日期序补推期次；行数超过总数说明该列语义不可靠，放弃
            guard members.count <= (members[0].signal?.total ?? 0) else { return nil }
            ordered = members.sorted { $0.date < $1.date }
        } else {
            // 混合时以带期次的行为准（无期次的行无法定位，丢弃进 ungrouped 由调用方统计）
            guard withoutIndex.isEmpty else { return nil }
            ordered = withIndex.sorted { ($0.signal?.index ?? 0) < ($1.signal?.index ?? 0) }
        }

        let total = ordered[0].signal?.total ?? 0
        guard (minPeriods...maxPeriods).contains(total), ordered.count <= total else { return nil }

        // 期次唯一性 + 日期非严格递增校验
        var seenIndex = Set<Int>()
        var previousDate: Date? = nil
        for (position, row) in ordered.enumerated() {
            let index = row.signal?.index ?? (position + 1)
            guard (1...total).contains(index), seenIndex.insert(index).inserted else { return nil }
            if let prev = previousDate, row.date < prev { return nil }
            previousDate = row.date
        }

        let groupId = UUID()
        var assignmentMap: [Int: Assignment] = [:]
        for (position, row) in ordered.enumerated() {
            let index = row.signal?.index ?? (position + 1)
            assignmentMap[row.row] = Assignment(groupId: groupId, index: index, total: total)
        }

        let sortedByDate = ordered
        let indexes = ordered.map { $0.signal?.index }.enumerated()
            .map { offset, value in value ?? (offset + 1) }
        let summary = GroupSummary(
            id: groupId,
            rowCount: ordered.count,
            total: total,
            firstIndex: indexes.min() ?? 1,
            lastIndex: indexes.max() ?? total,
            amount: ordered[0].amount,
            firstDate: sortedByDate.first!.date,
            lastDate: sortedByDate.last!.date,
            futureCount: ordered.filter { $0.date > now }.count
        )
        return (assignmentMap, summary)
    }

    // MARK: - 弱信号序列检测

    private static let sequenceMinGap: TimeInterval = 25 * 86400
    private static let sequenceMaxGap: TimeInterval = 38 * 86400
    private static let sequenceMinLength = 3

    private static func detectSuspectedSequences(in candidates: [CandidateRow]) -> [SuspectedGroup] {
        var buckets: [String: [CandidateRow]] = [:]
        for candidate in candidates {
            let key = "\(candidate.type.rawValue)|\(candidate.accountName)|\(candidate.amount)"
            buckets[key, default: []].append(candidate)
        }

        var suspected: [SuspectedGroup] = []
        for (_, members) in buckets where members.count >= sequenceMinLength {
            let sorted = members.sorted { $0.date < $1.date }
            var chain: [CandidateRow] = [sorted[0]]
            var chains: [[CandidateRow]] = []
            for row in sorted.dropFirst() {
                let gap = row.date.timeIntervalSince(chain.last!.date)
                if gap >= sequenceMinGap && gap <= sequenceMaxGap {
                    chain.append(row)
                } else {
                    chains.append(chain)
                    chain = [row]
                }
            }
            chains.append(chain)

            for link in chains where link.count >= sequenceMinLength && link.count <= maxPeriods {
                suspected.append(SuspectedGroup(
                    rows: link.map(\.row),
                    amount: link[0].amount,
                    accountName: link[0].accountName,
                    firstDate: link.first!.date,
                    lastDate: link.last!.date
                ))
            }
        }
        suspected.sort { $0.firstDate < $1.firstDate }
        return suspected
    }

    // MARK: - 疑似组确认

    /// 用户确认疑似组后按日期序 1...N 生成赋值（总期数=组内行数；未来期次不凭空补造）
    static func assignments(forConfirmed group: SuspectedGroup) -> [Int: Assignment] {
        let groupId = UUID()
        var result: [Int: Assignment] = [:]
        for (offset, row) in group.rows.enumerated() {
            result[row] = Assignment(groupId: groupId, index: offset + 1, total: group.rows.count)
        }
        return result
    }
}

// MARK: - 正则捕获组辅助

private extension NSRange {
    /// 把捕获组范围转为 Int；非数字或越界返回 nil
    func captureGroupInt(in text: String) -> Int? {
        guard location != NSNotFound, let range = Range(self, in: text) else { return nil }
        return Int(text[range])
    }
}
