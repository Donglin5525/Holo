import Foundation

/// 确定性归纳已结束的观察窗。正文、计数、依据和知识准入来自同一次统计。
nonisolated enum HoloRecordedPatternMiner {
    static let producer = "recordedPattern"

    struct HealthDay: Sendable {
        let day: Date
        let value: Double
    }

    enum HealthMetric: String, CaseIterable, Sendable {
        case steps, sleep

        var title: String { self == .steps ? String(localized: "步数") : String(localized: "睡眠时长") }
        var minimumDifference: Double { self == .steps ? 1_000 : 0.5 }

        func format(_ value: Double) -> String {
            switch self {
            case .steps: return String(localized: "\(value.formatted(.number.precision(.fractionLength(0)))) 步")
            case .sleep: return String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) 小时")
            }
        }
    }

    static func window(at now: Date, calendar: Calendar) -> DateInterval? {
        guard let end = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -4, to: end) else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func finance(
        _ input: [FinanceMemoryTransactionInput],
        window: DateInterval,
        calendar: Calendar
    ) -> [HoloKnowledgeRevision] {
        let inWindow = input.filter { $0.isExpense && $0.occurredAt >= window.start && $0.occurredAt < window.end }
        let unique = Dictionary(inWindow.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: unique.values, by: \.categoryID).values.compactMap { group in
            let items = group.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
            let days = Set(items.map { calendar.startOfDay(for: $0.occurredAt) })
            let weeks = Set(days.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start })
            let gate = HoloKnowledgeTemplateRegistry.parameters(for: .boundedRecurrence)
            guard let first = items.first, let firstDay = days.min(), let lastDay = days.max(),
                  days.count >= gate.minIndependentEvents, weeks.count >= gate.minCompletePeriods,
                  (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) >= gate.minSpanDays else { return nil }
            let title = first.categoryName
            // 依据明细行要「用户能看懂的具体明细」（东林 2026-11-08 拍板）：
            // summary 带金额与笔内容摘要（仅存本机，选题上送只有形状摘要不含 refs）。
            let amountFormatter = NumberFormatter()
            amountFormatter.numberStyle = .decimal
            amountFormatter.maximumFractionDigits = 0
            let refs = items.map { item in
                let key = "finance:\(item.id)"
                let amount = amountFormatter.string(from: NSNumber(value: item.amount)) ?? String(item.amount)
                return HoloMemoryEvidenceRef(
                    id: "pattern-\(key)", kind: .entityRef, sourceDomain: .finance,
                    lineageKey: key, sourceID: item.id, revisionDigest: item.revisionDigest,
                    observedAt: item.occurredAt, summary: "\(item.merchant ?? title) · ¥\(amount)"
                )
            }
            return revision(
                domain: .finance, key: "finance-category:\(first.categoryID)", label: title,
                text: String(localized: "这四周里，你在 \(days.count) 个不同的日子记了「\(title)」支出，分布在 \(weeks.count) 周。"),
                measured: "\(days.count)|\(weeks.count)|\(items.count)",
                stats: String(localized: "\(items.count) 笔支出 · \(days.count) 个记账日 · \(weeks.count) 周"),
                refs: refs, eventCount: days.count, periods: weeks.count, window: window
            )
        }.sorted {
            if $0.initialEvidenceSnapshot.independentEventCount != $1.initialEvidenceSnapshot.independentEventCount {
                return $0.initialEvidenceSnapshot.independentEventCount > $1.initialEvidenceSnapshot.independentEventCount
            }
            return $0.propositionID < $1.propositionID
        }.prefix(2).map { $0 }
    }

    static func health(
        _ input: [HealthDay],
        metric: HealthMetric,
        window: DateInterval,
        calendar: Calendar
    ) -> HoloKnowledgeRevision? {
        let samples = input.filter {
            $0.value.isFinite && $0.value >= 0 && $0.day >= window.start && $0.day < window.end
        }
        let byDay = Dictionary(
            samples.map { (calendar.startOfDay(for: $0.day), $0.value) },
            uniquingKeysWith: max
        )
        let days = byDay.map { HealthDay(day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
        let weeks = Dictionary(grouping: days) { calendar.dateInterval(of: .weekOfYear, for: $0.day)?.start }
        let comparisons = weeks.values.compactMap { week -> (days: [HealthDay], difference: Double)? in
            let weekend = week.filter { calendar.isDateInWeekend($0.day) }
            let weekdays = week.filter { !calendar.isDateInWeekend($0.day) }
            // 仅比较有两个周末观测、且至少三个平日观测的周。无读数的日期不参与均值。
            guard weekend.count >= 2, weekdays.count >= 3 else { return nil }
            let weekendAverage = weekend.map(\.value).reduce(0, +) / Double(weekend.count)
            let weekdayAverage = weekdays.map(\.value).reduce(0, +) / Double(weekdays.count)
            return (week, weekendAverage - weekdayAverage)
        }
        guard comparisons.count >= 3 else { return nil }
        let higher = comparisons.filter { $0.difference >= metric.minimumDifference }.count
        let lower = comparisons.filter { $0.difference <= -metric.minimumDifference }.count
        let matching = max(higher, lower)
        guard matching * 3 >= comparisons.count * 2 else { return nil }

        let comparedDays = comparisons.flatMap(\.days).sorted { $0.day < $1.day }
        let refs = comparedDays.map { sample in
            let key = "health:daily:\(metric.rawValue):\(Int(sample.day.timeIntervalSince1970))"
            return HoloMemoryEvidenceRef(
                id: key, kind: .aggregateSnapshot, sourceDomain: .health, lineageKey: key,
                revisionDigest: HoloKnowledgeIdentity.fnv1a64(String(sample.value)),
                observedAt: sample.day, aggregateDefinition: metric.rawValue, sampleCount: 1,
                summary: metric.format(sample.value)
            )
        }
        let difference = metric.format(metric.minimumDifference)
        let comparison = higher > lower
            ? String(localized: "比平日至少多 \(difference)")
            : String(localized: "比平日至少少 \(difference)")
        let total = comparisons.count
        return revision(
            domain: .health, key: "health-metric:\(metric.rawValue)", label: metric.title,
            text: String(localized: "这四周里，\(total) 周的健康记录可以对照。其中 \(matching) 周，你周末的日均\(metric.title)\(comparison)。"),
            measured: "\(higher)|\(lower)|\(total)",
            stats: String(localized: "\(matching) / \(total) 周呈现这个差异 · \(comparedDays.count) 天有记录"),
            refs: refs, eventCount: comparedDays.count, periods: total, window: window
        )
    }

    private static func revision(
        domain: HoloMemoryDomain, key: String, label: String, text: String,
        measured: String, stats: String, refs: [HoloMemoryEvidenceRef],
        eventCount: Int, periods: Int, window: DateInterval
    ) -> HoloKnowledgeRevision {
        let evidence = HoloKnowledgeEvidenceSnapshot(
            supportRefs: refs, observationWindowFrom: window.start, observationWindowTo: window.end,
            independentEventCount: eventCount, templateID: HoloKnowledgeTemplateID.boundedRecurrence.rawValue,
            completePeriods: periods, statsSummary: stats,
            sourceRevisions: Dictionary(refs.map { ($0.lineageKey, $0.revisionDigest) }, uniquingKeysWith: { first, _ in first }),
            capturedAt: window.end
        )
        let semantic = HoloKnowledgeSemantic(
            subjectRef: "self", objectRef: key, relation: "\(domain.rawValue):recordedRecurrence",
            objectValue: measured, dimension: "claim:recordedRecurrence",
            applicability: .init(windowRule: .absolute(from: window.start, to: window.end)),
            allowedUses: [.sourceLinkForPreciseQuery], formation: .behavioralInference,
            evidenceForm: domain == .health ? .sampledNumericSeries : .independentEventSet,
            displayText: text, aiUseText: text
        )
        return HoloKnowledgeRevision.make(
            semantic: semantic, topicLabel: label, domains: [domain],
            sensitivity: .sensitive, partition: .sensitiveLocal, evidenceSnapshot: evidence,
            origin: .init(kind: .producer, producer: producer), createdAt: window.end
        )
    }
}
