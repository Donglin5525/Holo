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

    /// 取数窗 8 周：后 4 周为展示窗，前 4 周只做变化对照基线（2026-11-08 东林
    /// 「观察要有意义」拍板——频次陈述无价值，时段模式与前后窗变化才是可读观察）。
    static func window(at now: Date, calendar: Calendar) -> DateInterval? {
        guard let end = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -8, to: end) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// 展示窗（近 4 周）：观察句里的「这四周」锚定这里。
    static func displayWindow(of window: DateInterval, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(byAdding: .weekOfYear, value: 4, to: window.start) else { return nil }
        return DateInterval(start: start, end: window.end)
    }

    static func finance(
        _ input: [FinanceMemoryTransactionInput],
        window: DateInterval,
        calendar: Calendar
    ) -> [HoloKnowledgeRevision] {
        let inWindow = input.filter { $0.isExpense && $0.occurredAt >= window.start && $0.occurredAt < window.end }
        let unique = Dictionary(inWindow.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recentStart = calendar.date(byAdding: .weekOfYear, value: 4, to: window.start)!
        var proposals: [HoloKnowledgeRevision] = []
        for group in Dictionary(grouping: unique.values, by: \.categoryID).values {
            // 优先级：时段模式（最有洞察）> 前后窗变化 > 频次（兜底，且门槛提高）。
            if let p = lateNightProposal(group, window: window, recentStart: recentStart, calendar: calendar) {
                proposals.append(p); continue
            }
            if let p = trendProposal(group, window: window, recentStart: recentStart, calendar: calendar) {
                proposals.append(p); continue
            }
            if let p = frequencyProposal(group, window: window, recentStart: recentStart, calendar: calendar) {
                proposals.append(p)
            }
        }
        return proposals.sorted {
            if $0.initialEvidenceSnapshot.independentEventCount != $1.initialEvidenceSnapshot.independentEventCount {
                return $0.initialEvidenceSnapshot.independentEventCount > $1.initialEvidenceSnapshot.independentEventCount
            }
            return $0.propositionID < $1.propositionID
        }
    }

    /// 频次观察（降级为兜底）：仅展示窗内样本，门槛提到「至少 3 个不同日 + 跨 3 周」。
    private static func frequencyProposal(
        _ group: [FinanceMemoryTransactionInput],
        window: DateInterval,
        recentStart: Date,
        calendar: Calendar
    ) -> HoloKnowledgeRevision? {
        let items = group.filter { $0.occurredAt >= recentStart }
            .sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
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
                refs: refs, eventCount: days.count, periods: weeks.count,
                window: DateInterval(start: recentStart, end: window.end)
            )
    }

    /// 深夜时段模式（最有洞察的一类）：同类支出里 ≥30% 发生在 21 点后到凌晨 4 点。
    /// 停车费这类「结算时间戳≠行为时间」的类目天然难命中（跨零点结算会摊薄占比），
    /// 餐饮/夜宵类天然命中——观察直指作息与生活习惯（东林真实数据：21 顿晚饭 8 顿在 22 点后）。
    private static func lateNightProposal(
        _ group: [FinanceMemoryTransactionInput],
        window: DateInterval,
        recentStart: Date,
        calendar: Calendar
    ) -> HoloKnowledgeRevision? {
        let items = group.filter { $0.occurredAt >= recentStart }
            .sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
        guard items.count >= 8, let first = items.first else { return nil }
        // 只对餐饮类目开放：停车/电费等凌晨时间戳是出账时间不是行为时间
        //（东林真实数据：停车 33 笔 24 笔落在深夜时段，全是跨零点结算噪音）。
        let categoryName = first.categoryName
        let diningKeywords = [
            "饭", "餐", "食", "外卖", "宵", "烤", "锅", "面", "粉", "粥", "茶", "咖",
            "饮", "酒", "汉堡", "披萨", "寿司", "串", "麦当劳", "肯德基", "星巴克",
            "瑞幸", "蜜雪", "美团", "饿了么", "甜", "冰", "奶茶",
        ]
        guard diningKeywords.contains(where: categoryName.contains) else { return nil }
        func isLate(_ date: Date) -> Bool {
            let hour = calendar.component(.hour, from: date)
            return hour >= 21 || hour < 4
        }
        let late = items.filter { isLate($0.occurredAt) }
        let latePct = late.count * 100 / items.count
        guard latePct >= 30 else { return nil }
        // 「最晚」取凌晨段最大值（真·最晚）；无凌晨记录时取晚间最大（措辞由模板区分）。
        let lateHours = late.map { calendar.component(.hour, from: $0.occurredAt) }
        let afterMidnight = lateHours.filter { $0 < 4 }
        let latestHour = afterMidnight.max() ?? lateHours.max() ?? 0
        let latestText = afterMidnight.isEmpty
            ? String(localized: "最晚到晚上 \(latestHour) 点")
            : String(localized: "最晚的一顿在凌晨 \(latestHour) 点")
        let title = first.categoryName
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
            domain: .finance, key: "finance-lateNight:\(first.categoryID)", label: title,
            text: String(localized: "这四周里，你的「\(title)」有 \(latePct)% 发生在晚上九点以后，\(latestText)。"),
            measured: "\(items.count)|\(late.count)|\(latePct)|\(latestHour)",
            stats: String(localized: "\(items.count) 笔中 \(late.count) 笔在 21 点后 · \(latestText)"),
            refs: refs, eventCount: items.count, periods: 4,
            window: DateInterval(start: recentStart, end: window.end)
        )
    }

    /// 前后窗变化：同类支出近 4 周笔数 vs 前 4 周，变化 ≥40% 才报（防噪音）。
    private static func trendProposal(
        _ group: [FinanceMemoryTransactionInput],
        window: DateInterval,
        recentStart: Date,
        calendar: Calendar
    ) -> HoloKnowledgeRevision? {
        let all = group.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
        let previous = all.filter { $0.occurredAt < recentStart }
        let recent = all.filter { $0.occurredAt >= recentStart }
        guard let first = all.first, previous.count >= 2, recent.count >= 3 else { return nil }
        let delta = recent.count - previous.count
        let changePct = abs(delta) * 100 / max(previous.count, 1)
        guard changePct >= 40 else { return nil }
        let title = first.categoryName
        let amountFormatter = NumberFormatter()
        amountFormatter.numberStyle = .decimal
        amountFormatter.maximumFractionDigits = 0
        let refs = recent.map { item in
            let key = "finance:\(item.id)"
            let amount = amountFormatter.string(from: NSNumber(value: item.amount)) ?? String(item.amount)
            return HoloMemoryEvidenceRef(
                id: "pattern-\(key)", kind: .entityRef, sourceDomain: .finance,
                lineageKey: key, sourceID: item.id, revisionDigest: item.revisionDigest,
                observedAt: item.occurredAt, summary: "\(item.merchant ?? title) · ¥\(amount)"
            )
        }
        let directionText = delta > 0
            ? String(localized: "多了 \(delta) 笔")
            : String(localized: "少了 \(-delta) 笔")
        return revision(
        domain: .finance, key: "finance-trend:\(first.categoryID)", label: title,
        text: String(localized: "最近四周，你的「\(title)」记了 \(recent.count) 笔，比上一个四周\(directionText)。"),
        measured: "\(recent.count)|\(previous.count)|\(delta)",
        stats: String(localized: "近 4 周 \(recent.count) 笔 · 前 4 周 \(previous.count) 笔"),
        refs: refs, eventCount: recent.count, periods: 8,
            window: window
        )
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
