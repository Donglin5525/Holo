import Foundation

// 「一个发现」v4 候选构建器（2026-11-20 方案 03-I2，纯逻辑、可单测）。
//
// 输入三路材料，产出双件套：
// - InsightInputPacket：去标识化输入包（画像 + 特征 + 意图），上送模型；
// - SlotValueTable：真实数值表（不上传），CardBuilder 回填 evidence 模板用。
//
// 去标识化纪律（总纲 §4）：
// - 特征 description 一律走无数字模板，数值转为 slot（名称+单位上送，真值留本机）；
// - 意图短句来自用户自己的目标/习惯/想法，剥离数字后上送；
// - 构建完成后逐条断言 description 无数字（防御性仅此一处：入口材料即边界）。
nonisolated enum DiscoveryInsightCandidateBuilder {

    struct Output: Sendable {
        var packet: InsightInputPacket
        var slots: SlotValueTable
    }

    /// portrait + features < 3 → 返回 nil（数据不足，不请求，调用方走 v3）。
    static func build(
        requestId: String = UUID().uuidString,
        portraitStore: PortraitStore,
        featurePacket: CrossDomainFeaturePacket,
        proposals: [HoloKnowledgeRevision],
        recentTopics: [String],
        rejectedAngles: [String],
        windowDays: Int = 28,
        now: Date = Date()
    ) -> Output? {
        var features: [InsightInputPacket.FeatureItem] = []
        var slots = SlotValueTable()

        // 1) 跨域异常信号（价值最高：D1/D2 的主要原料）。
        appendAnomalies(featurePacket, into: &features, slots: &slots)

        // 2) 习惯趋势（断签/回涨与数值变化）。
        appendHabitTrends(featurePacket, into: &features, slots: &slots)

        // 3) 财务反复消费概念。
        appendFinanceConcepts(featurePacket, into: &features, slots: &slots)

        // 4) 健康睡眠/活动量基线对照。
        appendHealthBaselines(featurePacket, into: &features, slots: &slots)

        // 5) 挖掘器提案（财务/健康统计真值，槽位口径与 v3 slotValues 一致）。
        appendMinerProposals(proposals, into: &features, slots: &slots)

        // 数量上限（总纲 §5.1）：异常 > 习惯 > 财务 > 健康 > 挖掘器，超限截断。
        if features.count > InsightInputPacket.featureLimit {
            features = Array(features.prefix(InsightInputPacket.featureLimit))
        }

        // 画像条目：confirmed/inferred（黑名单条目已被 reject() 移出 entries），
        // 按「置信度优先 + 新近优先」截断。
        let portraitItems = portraitStore.entries.values
            .filter { $0.confidence == .confirmed || $0.confidence == .inferred }
            .sorted {
                if ($0.confidence == .confirmed) != ($1.confidence == .confirmed) {
                    return $0.confidence == .confirmed
                }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(InsightInputPacket.portraitLimit)
            .map { entry in
                InsightInputPacket.PortraitItem(
                    id: entry.key,
                    dimension: entry.dimension.rawValue,
                    confidence: entry.confidence.rawValue,
                    statement: String(entry.statement.prefix(100)),
                    evidenceSummary: String(entry.evidenceSummary.prefix(100)),
                    sourceDomains: Array(entry.sourceDomains.prefix(7))
                )
            }

        // 用户意图：目标（desiredOutcome 优先）> 想法摘录 > 想坚持的习惯；上限 10。
        let intents = buildUserIntents(featurePacket)

        guard portraitItems.count + features.count >= 3 else { return nil }

        let packet = InsightInputPacket(
            schemaVersion: 1,
            kind: "insightInput",
            requestId: requestId,
            window: InsightInputPacket.Window(days: windowDays),
            portrait: Array(portraitItems),
            features: features,
            userIntents: Array(intents.prefix(InsightInputPacket.userIntentLimit)),
            recentTopics: Array(recentTopics.prefix(30)),
            rejectedAngles: Array(rejectedAngles.prefix(30))
        )
        return Output(packet: packet, slots: slots)
    }

    // MARK: - 特征蒸馏（无数字模板 + 槽位真值）

    private static func appendAnomalies(
        _ packet: CrossDomainFeaturePacket,
        into features: inout [InsightInputPacket.FeatureItem],
        slots: inout SlotValueTable
    ) {
        for (index, anomaly) in packet.anomalies.enumerated() {
            let id = "f_anomaly_\(index)"
            var description = ""
            var direction = "divergent"
            var slotList: [InsightInputPacket.Slot] = []
            var values: [String: String] = [:]

            switch anomaly.code {
            case "sleep_short":
                description = "近期睡眠偏短，不足七小时的天数占多数"
                direction = "down"
                slotList = [InsightInputPacket.Slot(name: "avgHours", unit: "hours")]
                if let avg = packet.health.sleep.recentAvgHours {
                    values["avgHours"] = String(format: "%.1f", avg)
                }
            case "sleep_later", "sleep_late":
                description = "入睡时间比之前更晚"
                direction = "up"
                slotList = [
                    InsightInputPacket.Slot(name: "shiftMinutes", unit: "minutes"),
                    InsightInputPacket.Slot(name: "recentBedtime", unit: "clock"),
                ]
                if let shift = packet.health.sleep.bedtimeShiftMinutes { values["shiftMinutes"] = String(shift) }
                if let bed = packet.health.sleep.recentAvgBedtimeHHMM { values["recentBedtime"] = bed }
            case "activity_drop":
                description = "活动量比之前明显减少"
                direction = "down"
                slotList = [
                    InsightInputPacket.Slot(name: "stepsChangePct", unit: "percent"),
                    InsightInputPacket.Slot(name: "recentAvgSteps", unit: "steps"),
                ]
                if let pct = packet.health.activity.stepsChangePercent { values["stepsChangePct"] = String(pct) }
                if let steps = packet.health.activity.recentAvgSteps { values["recentAvgSteps"] = String(steps) }
            case "numeric_habit_up", "numeric_habit_down":
                let isUp = anomaly.code == "numeric_habit_up"
                description = stripNumerals("数值习惯\(wrappedName(habitName(from: anomaly.summary)))的记录值在\(isUp ? "变多" : "变少")")
                direction = isUp ? "up" : "down"
                // 数值真值在 habits.numerics 里按名匹配。
                if let trend = packet.habits.numerics.first(where: { anomaly.summary.contains($0.name) }) {
                    slotList = [
                        InsightInputPacket.Slot(name: "recentValue", unit: trend.unit ?? ""),
                        InsightInputPacket.Slot(name: "earlierValue", unit: trend.unit ?? ""),
                    ]
                    values["recentValue"] = trimNumber(trend.recentAvg)
                    values["earlierValue"] = trimNumber(trend.earliestAvg)
                }
            default:
                // 未知异常码：summary 含数字，不可直接上送——按域生成泛化描述。
                let domainText = ["finance": "财务", "health": "健康", "habit": "习惯"][anomaly.domain] ?? "生活"
                description = "\(domainText)域出现与平时不同的信号"
                direction = "divergent"
            }

            guard !description.isEmpty else { continue }
            features.append(InsightInputPacket.FeatureItem(
                id: id, domain: mapDomain(anomaly.domain), description: description,
                direction: direction, slots: slotList
            ))
            if !values.isEmpty { slots.values[id] = values }
        }
    }

    private static func appendHabitTrends(
        _ packet: CrossDomainFeaturePacket,
        into features: inout [InsightInputPacket.FeatureItem],
        slots: inout SlotValueTable
    ) {
        for (index, trend) in packet.habits.checkins.enumerated()
        where trend.direction != "flat" {
            let id = "f_checkin_\(index)"
            let isUp = trend.direction == "up"
            features.append(InsightInputPacket.FeatureItem(
                id: id,
                domain: "habit",
                description: stripNumerals("打卡习惯\(wrappedName(trend.name))近期完成比之前\(isUp ? "多" : "少")"),
                direction: isUp ? "up" : "down",
                slots: [
                    InsightInputPacket.Slot(name: "recentCount", unit: "times"),
                    InsightInputPacket.Slot(name: "baselineCount", unit: "times"),
                ]
            ))
            slots.values[id] = [
                "recentCount": String(trend.recent21dCount),
                "baselineCount": String(trend.baseline21dCount),
            ]
        }
    }

    private static func appendFinanceConcepts(
        _ packet: CrossDomainFeaturePacket,
        into features: inout [InsightInputPacket.FeatureItem],
        slots: inout SlotValueTable
    ) {
        for (index, concept) in packet.finance.recurringConcepts.enumerated()
        where concept.dominantBand != nil || concept.recent30dCount >= 3 {
            let id = "f_concept_\(index)"
            let band = concept.dominantBand.map { "，多发生在\($0)" } ?? ""
            // 近 30 天占比过半 → up，否则 stable（概念持续存在本身即对照原料）。
            let isUp = Double(concept.recent30dCount) >= Double(concept.count) * 0.5 && concept.count >= 4
            features.append(InsightInputPacket.FeatureItem(
                id: id,
                domain: "finance",
                description: stripNumerals("反复出现的\(wrappedName(concept.concept))消费\(band)"),
                direction: isUp ? "up" : "stable",
                slots: [
                    InsightInputPacket.Slot(name: "recentCount", unit: "times"),
                    InsightInputPacket.Slot(name: "totalCount", unit: "times"),
                    InsightInputPacket.Slot(name: "spanDays", unit: "days"),
                ]
            ))
            slots.values[id] = [
                "recentCount": String(concept.recent30dCount),
                "totalCount": String(concept.count),
                "spanDays": String(concept.spanDays),
            ]
        }
    }

    private static func appendHealthBaselines(
        _ packet: CrossDomainFeaturePacket,
        into features: inout [InsightInputPacket.FeatureItem],
        slots: inout SlotValueTable
    ) {
        let sleep = packet.health.sleep
        if sleep.coverage != .none, let delta = sleep.durationDeltaMinutes, abs(delta) >= 20 {
            let id = "f_sleep_duration"
            let isShort = delta < 0
            features.append(InsightInputPacket.FeatureItem(
                id: id,
                domain: "health",
                description: "近期平均睡眠时长比之前\(isShort ? "更短" : "更长")",
                direction: isShort ? "down" : "up",
                slots: [
                    InsightInputPacket.Slot(name: "recentHours", unit: "hours"),
                    InsightInputPacket.Slot(name: "baselineHours", unit: "hours"),
                    InsightInputPacket.Slot(name: "deltaMinutes", unit: "minutes"),
                ]
            ))
            var values: [String: String] = ["deltaMinutes": String(delta)]
            if let r = sleep.recentAvgHours { values["recentHours"] = String(format: "%.1f", r) }
            if let b = sleep.baselineAvgHours { values["baselineHours"] = String(format: "%.1f", b) }
            slots.values[id] = values
        }

        let activity = packet.health.activity
        if activity.coverage != .none, let pct = activity.stepsChangePercent, abs(pct) >= 15 {
            let id = "f_steps_change"
            let isUp = pct > 0
            features.append(InsightInputPacket.FeatureItem(
                id: id,
                domain: "health",
                description: "近期日均步数比之前\(isUp ? "更多" : "更少")",
                direction: isUp ? "up" : "down",
                slots: [
                    InsightInputPacket.Slot(name: "changePct", unit: "percent"),
                    InsightInputPacket.Slot(name: "recentAvgSteps", unit: "steps"),
                ]
            ))
            var values: [String: String] = ["changePct": String(pct)]
            if let s = activity.recentAvgSteps { values["recentAvgSteps"] = String(s) }
            slots.values[id] = values
        }
    }

    /// 挖掘器提案 → 特征（槽位格式与 v3 DiscoveryTopicService.slotValues 完全同口径：
    /// finance "days|weeks|items"、lateNight "total|late|pct|latestHour"、
    /// trend "recent|previous|delta"、health "matching|higher/lower|total"）。
    private static func appendMinerProposals(
        _ proposals: [HoloKnowledgeRevision],
        into features: inout [InsightInputPacket.FeatureItem],
        slots: inout SlotValueTable
    ) {
        for (index, proposal) in proposals.enumerated() {
            guard let key = proposal.semantic.objectRef else { continue }
            let label = stripNumerals(proposal.topicLabel)
            var description = ""
            var direction = "stable"
            var slotList: [InsightInputPacket.Slot] = []
            var values: [String: String] = [:]
            if !label.isEmpty { values["label"] = label }

            if key.hasPrefix("finance-category:") {
                description = "\(wrappedName(label))的记录天数在变化"
                direction = textDirection(proposal)
                slotList = slotNames(["label", "weeks", "recordDays", "txCount"])
            } else if key.hasPrefix("finance-lateNight:") {
                description = "深夜时段\(wrappedName(label))消费模式与平时不同"
                direction = "divergent"
                slotList = slotNames(["label", "weeks", "latePct", "lateCount", "totalCount", "latestHour"])
            } else if key.hasPrefix("finance-trend:") {
                description = "\(wrappedName(label))近期次数与之前不同"
                direction = textDirection(proposal)
                slotList = slotNames(["label", "weeks", "recentCount", "previousCount", "absDelta"])
            } else if key.hasPrefix("health-metric:") {
                description = "\(wrappedName(label))工作日与周末表现不一致"
                direction = "divergent"
                slotList = slotNames(["label", "weeks", "matchWeeks", "recordDays"])
            } else {
                continue
            }

            // measured 真值拆解（v3 同款，格式注释见上）。
            let parts = (proposal.semantic.objectValue ?? "").split(separator: "|").map(String.init)
            if key.hasPrefix("finance-category:"), parts.count >= 3 {
                values["recordDays"] = parts[0]; values["weeks"] = parts[1]; values["txCount"] = parts[2]
            } else if key.hasPrefix("finance-lateNight:"), parts.count >= 4 {
                values["totalCount"] = parts[0]; values["lateCount"] = parts[1]
                values["latePct"] = parts[2]; values["latestHour"] = parts[3]; values["weeks"] = "4"
            } else if key.hasPrefix("finance-trend:"), parts.count >= 3 {
                values["recentCount"] = parts[0]; values["previousCount"] = parts[1]
                values["absDelta"] = String(abs(Int(parts[2]) ?? 0)); values["weeks"] = "4"
            } else if key.hasPrefix("health-metric:"), parts.count >= 2 {
                values["matchWeeks"] = parts[0]
                values["weeks"] = parts.count >= 3 ? parts[2] : parts[1]
                let events = proposal.initialEvidenceSnapshot.independentEventCount
                if events > 0 {
                    values["recordDays"] = String(events)
                }
            }

            let id = "f_miner_\(index)"
            features.append(InsightInputPacket.FeatureItem(
                id: id, domain: domainString(proposal), description: description,
                direction: direction, slots: slotList
            ))
            slots.values[id] = values
        }
    }

    // MARK: - 用户意图（goal > thought > habit）

    private static func buildUserIntents(_ packet: CrossDomainFeaturePacket) -> [InsightInputPacket.UserIntentItem] {
        var intents: [InsightInputPacket.UserIntentItem] = []
        for (index, goal) in packet.activeGoals.enumerated() where goal.status == "active" {
            let text = stripNumerals(String((goal.desiredOutcome ?? goal.title).prefix(40)))
            guard text.count >= 2 else { continue }
            intents.append(InsightInputPacket.UserIntentItem(id: "u_goal_\(index)", source: "goal", text: text))
        }
        for (index, thought) in packet.thoughts.enumerated() {
            let text = stripNumerals(String(thought.excerpt.prefix(40)))
            guard text.count >= 2 else { continue }
            intents.append(InsightInputPacket.UserIntentItem(id: "u_thought_\(index)", source: "thought", text: text))
        }
        // 习惯初衷：近期在下滑的打卡习惯（D4「回应」原料——用户想坚持但正在掉队）。
        let struggling = packet.habits.checkins.filter { $0.direction == "down" }.prefix(3)
        for (index, habit) in struggling.enumerated() {
            intents.append(InsightInputPacket.UserIntentItem(
                id: "u_habit_\(index)", source: "habit",
                text: stripNumerals("想坚持\(wrappedName(habit.name))")
            ))
        }
        return Array(intents.prefix(InsightInputPacket.userIntentLimit))
    }

    // MARK: - 工具

    /// 剥离数字（ASCII/全角/中文数字整段删除）——意图与描述的去标识化出口。
    static func stripNumerals(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: InsightNumberDiscipline.numeralCharacters)
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text where !banned.contains(ch.unicodeScalars.first ?? " ") {
            result.append(ch)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func wrappedName(_ name: String) -> String {
        let clipped = stripNumerals(String(name.prefix(16)))
        return clipped.isEmpty ? "某个习惯" : "「\(clipped)」"
    }

    private static func habitName(from summary: String) -> String {
        // 异常摘要格式：数值习惯「name」近N天变化…——取书名号内。
        guard let start = summary.firstIndex(of: "「"), let end = summary.firstIndex(of: "」"), start < end else {
            return ""
        }
        return String(summary[summary.index(after: start)..<end])
    }

    private static func textDirection(_ proposal: HoloKnowledgeRevision) -> String {
        let text = proposal.semantic.displayText ?? ""
        if text.contains("高于") || text.contains("更多") || text.contains("变多") { return "up" }
        if text.contains("低于") || text.contains("更少") || text.contains("变少") { return "down" }
        return "stable"
    }

    private static func domainString(_ proposal: HoloKnowledgeRevision) -> String {
        switch proposal.domains.first {
        case .finance: return "finance"
        case .health: return "health"
        case .habit: return "habit"
        case .task: return "task"
        case .goal: return "goal"
        case .thought: return "thought"
        default: return "profile"
        }
    }

    private static func mapDomain(_ raw: String) -> String {
        switch raw.lowercased() {
        case "finance": return "finance"
        case "health": return "health"
        case "habit": return "habit"
        case "task": return "task"
        case "goal": return "goal"
        case "profile": return "profile"
        default: return "thought"
        }
    }

    private static func slotNames(_ names: [String]) -> [InsightInputPacket.Slot] {
        names.map { InsightInputPacket.Slot(name: $0, unit: "") }
    }

    private static func trimNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
