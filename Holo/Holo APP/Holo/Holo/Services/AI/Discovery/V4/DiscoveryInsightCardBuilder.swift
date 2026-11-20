import Foundation

// 「一个发现」v4 卡片组装器（2026-11-20 方案 03-I4，纯逻辑、可单测）。
//
// 职责：用 SlotValueTable 回填 evidence 模板 → 终检 → 产出可入队的 QueuedCard(v4)。
// 终检（回填后的最后防线）：
// 1. 不得残留 "{"（模型用了槽位白名单外的写法或值缺失）；
// 2. evidence 里的数字必须全部来自 slot 值（数字纪律客户端版，与 v3 buildCard 同源）；
// 3. 任一 slot 缺值 → 删该行；删完行数为 0 → 整卡作废（返回 nil）。
nonisolated enum DiscoveryInsightCardBuilder {

    enum BuildError: Error, Equatable {
        case unfilledSlot
        case foreignNumber
        case noEvidenceLeft
        case residualBrace
    }

    static func build(
        selected: InsightDraft.Selected,
        slots: SlotValueTable,
        portraitIds: Set<String> = [],
        domainByRefId: [String: String] = [:],
        now: Date = Date()
    ) throws -> DiscoveryTopicStore.QueuedCard {
        var evidenceLines: [String] = []
        var evidenceDomains: [String] = []
        var allowedNumbers = Set<String>()
        for line in selected.evidence {
            var filled = line.template
            let values = slots.slotValues(for: line.refId)
            var lineAllowed = Set<String>()
            for (name, value) in values {
                filled = filled.replacingOccurrences(of: "{\(name)}", with: value)
                lineAllowed.formUnion(InsightNumberDiscipline.asciiNumberRuns(in: value))
            }
            // 缺值行：模板里还有未回填空位 → 整行删除（宁缺行不硬撑）。
            if filled.contains("{") { continue }
            allowedNumbers.formUnion(lineAllowed)
            evidenceLines.append(filled)
            evidenceDomains.append(domainByRefId[line.refId] ?? "thought")
        }
        guard !evidenceLines.isEmpty else { throw BuildError.noEvidenceLeft }

        // 终检②：回填后的证据行里，数字必须全部来自 slot 真值。
        let digitsInLines = evidenceLines.flatMap { InsightNumberDiscipline.asciiNumberRuns(in: $0) }
        guard digitsInLines.allSatisfy({ allowedNumbers.contains($0) }) else {
            throw BuildError.foreignNumber
        }

        // 时效：观察窗 28 天（洞察是近期判断，不给半年长窗）。
        let windowEnd = now.addingTimeInterval(28 * 86_400)
        // 画像引用：evidence 里指向画像条目的 refId（反馈回流「准/不准」的落点）。
        let portraitRefs = selected.evidence.map(\.refId).filter { portraitIds.contains($0) }
        return DiscoveryTopicStore.QueuedCard(
            observationId: selected.angleKey,
            topicKey: selected.angleKey,
            title: selected.headline,
            body: selected.insight,
            isModelCopy: true,
            selectedAt: now,
            windowEnd: windowEnd,
            version: 4,
            insight: selected.insight,
            evidenceLines: evidenceLines,
            evidenceDomains: evidenceDomains,
            prompt: selected.prompt,
            portraitRefs: portraitRefs,
            angleKey: selected.angleKey,
            sourceDomains: selected.sourceDomains
        )
    }
}
