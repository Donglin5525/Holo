//
//  HoloFinancePatternMiner.swift
//  Holo
//
//  财务规律挖矿引擎（v3.3「规律路径」程序统计补件，2026-11-01）。
//
//  规律路径 = 记录 → 程序统计 → 合格候选 → 用户确认。此前「程序统计」
//  只有发现模块（想法/任务/习惯）建了，财务域没有统计引擎——模型从未
//  见过「某商家出现 N 次」的统计，「爱吃麦当劳」类偏好永远长不出来，
//  「值得确认」区也随之永远为空（摄入路径的覆盖率/反例字段结构性缺省）。
//
//  本引擎在本地做确定性统计（不调模型）：按商家备注聚合计数，达到模板
//  门槛的直写知识层候选（behavioralInference + 带真实覆盖率/反例检索
//  状态的证据快照），经统一准入进「值得确认」。确认前不用于回答。
//
//  判定口径（全部可测）：
//  - 周节奏 → weeklyRhythm 模板：≥6 笔、跨 ≥4 个自然周、跨度 ≥28 天、
//    覆盖率（有记录的周 / 跨度周数，与发现桥同一公式）≥ 0.7；
//  - 月节奏 → periodicRule 模板：≥3 笔、跨 ≥3 个自然月、跨度 ≥60 天；
//  - 反例检索 = 新鲜度检查：最近一笔超出 45 天 → 规律可能已停，不出候选；
//    未超期 → searchedNoneFound（如实：检索过窗口内记录，未见停摆）。
//  - 金额稳定（±10%）的固定支出/分期交由既有固定支出信号，不重复挖。
//

import Foundation

nonisolated enum HoloFinancePatternMiner {

    static let producerName = "financePatternMiner"

    /// 回看窗口（天）：约 6 个自然月。
    static let lookbackDays = 200
    /// 候选新鲜度：最近一笔须在此天数内。
    static let recentLapseDays = 45
    /// 单轮最多产出候选数（值得确认区一次最多 3 条推荐，防淹没）。
    static let maxCandidatesPerRun = 5

    // MARK: - 候选

    struct PatternCandidate: Equatable, Sendable {
        /// 规范化商家键（小写、去空白）。
        let normalizedKey: String
        /// 展示名（原始写法中出现最多的那个）。
        let displayLabel: String
        let transactions: [FinanceMemoryTransactionInput]
        let distinctWeeks: Int
        let distinctMonths: Int
        let spanDays: Int
        /// 周节奏才有（有记录的周 / 跨度周数）；月节奏为 nil。
        let coveragePercent: Double?
        let template: HoloKnowledgeTemplateID
    }

    // MARK: - 挖矿（纯函数，可单测）

    static func mine(
        transactions: [FinanceMemoryTransactionInput],
        now: Date
    ) -> [PatternCandidate] {
        let windowStart = now.addingTimeInterval(-TimeInterval(lookbackDays) * 86_400)
        let expenses = transactions
            .filter { $0.isExpense && $0.occurredAt <= now && $0.occurredAt > windowStart }
            .filter { merchant in !(merchant.merchant ?? "").isEmpty }

        // 按规范化商家键聚合；展示名取组内出现最多的原始写法。
        var groups: [String: MerchantGroup] = [:]
        for item in expenses {
            guard let raw = item.merchant else { continue }
            let key = normalized(raw)
            groups[key, default: MerchantGroup()].items.append(item)
            groups[key]!.labelCounts[raw] = (groups[key]!.labelCounts[raw] ?? 0) + 1
        }

        var candidates: [PatternCandidate] = []
        for (key, group) in groups {
            guard let candidate = assess(key: key, group: group, now: now) else { continue }
            candidates.append(candidate)
        }
        return Array(
            candidates
                .sorted {
                    if $0.transactions.count != $1.transactions.count {
                        return $0.transactions.count > $1.transactions.count
                    }
                    return $0.normalizedKey < $1.normalizedKey
                }
                .prefix(maxCandidatesPerRun)
        )
    }

    private static func assess(key: String, group: MerchantGroup, now: Date) -> PatternCandidate? {
        let items = group.items.sorted { $0.occurredAt < $1.occurredAt }
        let dates = items.map(\.occurredAt)
        guard let first = dates.first, let last = dates.last, last > first else { return nil }

        // 新鲜度（反例检索的如实表达）：最近一笔超期 = 规律可能已停，不出候选。
        guard now.timeIntervalSince(last) <= TimeInterval(recentLapseDays) * 86_400 else { return nil }

        // 固定支出/分期（金额 ±10% 稳定）由既有固定支出信号负责，不重复挖。
        if looksLikeStableFixedExpense(items) { return nil }

        let distinctWeeks = isoWeekKeys(of: dates).count
        let distinctMonths = monthKeys(of: dates).count
        let spanDays = Int((last.timeIntervalSince(first) / 86_400).rounded())

        // 周节奏（weeklyRhythm）：覆盖率 = 全项目统一确定性口径。
        if items.count >= 6,
           distinctWeeks >= 4,
           spanDays >= 28,
           let coverage = HoloKnowledgeIngestion.weeklyCoverage(of: dates),
           coverage >= 0.7 {
            return PatternCandidate(
                normalizedKey: key,
                displayLabel: dominantLabel(group),
                transactions: items,
                distinctWeeks: distinctWeeks,
                distinctMonths: distinctMonths,
                spanDays: spanDays,
                coveragePercent: coverage,
                template: .weeklyRhythm
            )
        }

        // 月节奏（periodicRule）：不要求覆盖率（模板 minCoverage = 0）。
        if items.count >= 3,
           distinctMonths >= 3,
           distinctWeeks >= 3,
           spanDays >= 60 {
            return PatternCandidate(
                normalizedKey: key,
                displayLabel: dominantLabel(group),
                transactions: items,
                distinctWeeks: distinctWeeks,
                distinctMonths: distinctMonths,
                spanDays: spanDays,
                coveragePercent: nil,
                template: .periodicRule
            )
        }
        return nil
    }

    // MARK: - 知识落库（语义 + 证据快照直写，与发现桥同构）

    /// 候选 → 知识修订 + 证据快照操作（幂等：内容决定 ID；重跑不重复）。
    /// 写入后由统一准入判 worthConfirming，进「值得确认」区等用户确认。
    static func knowledgeWrites(
        for candidate: PatternCandidate,
        controlGeneration: Int64,
        now: Date
    ) -> (revision: HoloKnowledgeRevision, operations: [HoloKnowledgeOperation]) {
        let evidence = evidenceSnapshot(for: candidate, now: now)
        let semantic = semantic(for: candidate)
        let revision = HoloKnowledgeRevision.make(
            semantic: semantic,
            topicLabel: candidate.displayLabel,
            domains: [.finance],
            sensitivity: .normal,
            partition: .normal,
            evidenceSnapshot: evidence,
            sourceAliases: [],
            origin: HoloKnowledgeOrigin(kind: .producer, producer: producerName),
            // 窗口末日固定 createdAt：模式不变则修订内容不变，避免每日重跑
            // 产生无意义的行更新与 CloudKit 同步抖动。
            createdAt: candidate.transactions.last?.occurredAt ?? now
        )
        // 证据快照操作：ID 由内容决定；新交易进窗 → 快照 ID 变 → 追加刷新操作。
        let refresh = HoloKnowledgeOperation(
            operationID: "es-\(revision.semanticRevisionID)-\(evidence.id)",
            kind: .evidenceSnapshot,
            propositionID: revision.propositionID,
            targetSemanticRevisionID: revision.semanticRevisionID,
            targetSemanticDigest: revision.semanticDigest,
            controlGeneration: controlGeneration,
            payload: .evidenceSnapshot(evidence),
            partition: .normal,
            issuedAt: now
        )
        return (revision, [refresh])
    }

    static func semantic(for candidate: PatternCandidate) -> HoloKnowledgeSemantic {
        HoloKnowledgeSemantic(
            subjectRef: "self",
            objectRef: HoloKnowledgeIdentity.freeSemanticSlot(candidate.normalizedKey),
            relation: "finance:merchantFrequency",
            polarity: true,
            objectValue: nil,
            dimension: "claim:recurringPattern",
            qualifiers: ["程序统计", "消费频率"],
            applicability: HoloKnowledgeApplicability(windowRule: .ongoing),
            allowedUses: [.backgroundUnderstanding, .sourceLinkForPreciseQuery],
            formation: .behavioralInference,
            evidenceForm: .independentEventSet,
            displayText: displayText(for: candidate),
            aiUseText: displayText(for: candidate),
            prohibitedInferences: [
                "不得据此推断消费金额的稳定性",
                "不得扩大到未观察的时间范围",
                "不得推断人格、财务状况或生活方式优劣"
            ]
        )
    }

    static func evidenceSnapshot(
        for candidate: PatternCandidate,
        now: Date
    ) -> HoloKnowledgeEvidenceSnapshot {
        let support = candidate.transactions.map { item in
            HoloMemoryEvidenceRef(
                id: "fpm-\(item.id)",
                kind: .entityRef,
                sourceDomain: .finance,
                lineageKey: "finance:\(item.id)",
                sourceID: "finance:\(item.id)",
                revisionDigest: item.revisionDigest,
                observedAt: item.occurredAt,
                summary: "¥\(trimmingNumber(item.amount))"
            )
        }
        var revisions: [String: String] = [:]
        for item in candidate.transactions {
            revisions["finance:\(item.id)"] = item.revisionDigest
        }
        return HoloKnowledgeEvidenceSnapshot(
            supportRefs: support,
            counterRefs: [],
            observationWindowFrom: candidate.transactions.first?.occurredAt,
            observationWindowTo: candidate.transactions.last?.occurredAt,
            independentEventCount: support.count,
            coveragePercent: candidate.coveragePercent,
            // 新鲜度检查已在挖矿侧完成（超期不出候选）：如实记「已检索，未见反例」。
            counterexampleSearch: .searchedNoneFound,
            templateID: candidate.template.rawValue,
            // 完整周期 = 有记录的去重自然周数（09-R12 口径；周模板 ≥4、月模板 ≥3 由挖矿规则保证）。
            completePeriods: candidate.distinctWeeks,
            statsSummary: "\(support.count) 笔 / \(candidate.distinctWeeks) 周",
            sourceRevisions: revisions,
            holdoutValidatedPeriods: nil,
            capturedAt: now
        )
    }

    static func displayText(for candidate: PatternCandidate) -> String {
        let count = candidate.transactions.count
        let months = max(1, Int((Double(candidate.spanDays) / 30).rounded()))
        let interval = max(1, Int((Double(candidate.spanDays) / Double(max(1, count - 1))).rounded()))
        return "最近\(months)个月有\(count)笔「\(candidate.displayLabel)」支出，平均每隔约\(interval)天一笔"
    }

    // MARK: - 辅助

    /// 商家聚合组：交易列表 + 原始写法计数（展示名取众数）。
    private struct MerchantGroup {
        var items: [FinanceMemoryTransactionInput] = []
        var labelCounts: [String: Int] = [:]
    }

    private static func dominantLabel(_ group: MerchantGroup) -> String {
        group.labelCounts.max { lhs, rhs in lhs.value < rhs.value }?.key ?? ""
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 金额稳定（均值 ±10%）→ 固定支出/分期特征：交给既有固定支出信号。
    private static func looksLikeStableFixedExpense(_ items: [FinanceMemoryTransactionInput]) -> Bool {
        let amounts = items.map(\.amount)
        guard amounts.count >= 3 else { return false }
        let mean = amounts.reduce(0, +) / Double(amounts.count)
        guard mean > 0 else { return false }
        let maxDeviation = amounts.map { abs($0 - mean) }.max() ?? .infinity
        return maxDeviation / mean <= 0.1
    }

    private static func isoWeekKeys(of dates: [Date]) -> Set<String> {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        return Set(dates.map {
            "\(calendar.component(.yearForWeekOfYear, from: $0))-W\(calendar.component(.weekOfYear, from: $0))"
        })
    }

    private static func monthKeys(of dates: [Date]) -> Set<String> {
        let calendar = Calendar(identifier: .gregorian)
        return Set(dates.map {
            "\(calendar.component(.year, from: $0))-\(calendar.component(.month, from: $0))"
        })
    }

    private static func trimmingNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 运行时调度（启动跑一轮，每日限一次）

nonisolated enum HoloFinancePatternMiningRuntime {

    static let throttleKey = "holo_finance_pattern_miner_last_run"
    static let throttleInterval: TimeInterval = 20 * 3_600

    /// 启动/回前台后跑一轮（每日限一次；自动形成记忆关闭时不跑）。
    /// 仓库与财务仓储都是主线程隔离：整体 MainActor，由启动方 await。
    @MainActor
    static func runIfNeeded(now: Date = Date()) async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: throttleKey) as? Date,
           now.timeIntervalSince(last) < throttleInterval {
            return
        }
        guard HoloMemorySettings.shared.automaticMemoryEnabled else { return }
        defaults.set(now, forKey: throttleKey)

        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let transactions = await allExpenseTransactions(now: now)
            let candidates = HoloFinancePatternMiner.mine(transactions: transactions, now: now)
            let control = try await repository.loadControlState()
            for candidate in candidates {
                let writes = HoloFinancePatternMiner.knowledgeWrites(
                    for: candidate,
                    controlGeneration: control.userDecisionVersion,
                    now: now
                )
                try await repository.saveKnowledgeRevisionAndOperation(
                    revision: writes.revision,
                    operations: writes.operations
                )
            }
            if !candidates.isEmpty {
                NSLog("[HoloFinancePatternMiner] 产出 \(candidates.count) 条规律候选: \(candidates.map(\.displayLabel).joined(separator: "、"))")
            }
        } catch {
            NSLog("[HoloFinancePatternMiner] 运行失败（下轮重试）: \(String(describing: error))")
        }
    }

    /// 全量消费流水（排除退款/对账调整），复用信号适配器同口径。
    @MainActor
    private static func allExpenseTransactions(now: Date) async -> [FinanceMemoryTransactionInput] {
        let windowStart = now.addingTimeInterval(-TimeInterval(HoloFinancePatternMiner.lookbackDays) * 86_400)
        let raw = (try? await FinanceRepository.shared.getAllTransactions())?
            .filter { !$0.isReconciliationAdjustment } ?? []
        return raw.compactMap { transaction -> FinanceMemoryTransactionInput? in
            guard !transaction.isRefund else { return nil }
            guard transaction.transactionType == .expense else { return nil }
            guard transaction.date > windowStart, transaction.date <= now else { return nil }
            let merchant = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let merchant, !merchant.isEmpty else { return nil }
            guard let category = transaction.category else { return nil }
            let names = FinanceRepository.shared.resolveCategoryNames(from: category)
            return FinanceMemoryTransactionInput(
                id: transaction.id.uuidString,
                amount: transaction.amount.doubleValue,
                isExpense: true,
                categoryID: category.id.uuidString,
                categoryName: names.sub ?? names.primary,
                merchant: merchant,
                occurredAt: transaction.date,
                revisionDigest: "\(transaction.updatedAt.timeIntervalSince1970)-\(transaction.amount.stringValue)-\(category.id.uuidString)"
            )
        }
    }
}
