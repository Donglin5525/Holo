//
//  TaskMemorySignalBuilder.swift
//  Holo
//
//  任务只提炼完成节奏、积压和延期类型，不从少量事件推断心理或能力。
//

import Foundation

nonisolated struct TaskMemoryInput: Equatable, Sendable {
    var id: String
    var title: String
    var typeKey: String
    var completed: Bool
    var createdAt: Date
    var dueAt: Date?
    var completedAt: Date?
    var revisionDigest: String
}

nonisolated enum TaskMemorySignalBuilder {
    static func build(from inputs: [TaskMemoryInput], now: Date) -> [HoloDomainMemorySignal] {
        let valid = inputs.filter { !$0.id.isEmpty && !$0.revisionDigest.isEmpty }
        var signals: [HoloDomainMemorySignal] = []
        let completed = valid.filter { $0.completed && $0.completedAt != nil }
        if completed.count >= 5,
           let signal = aggregateSignal(
            id: "task-completion-rhythm",
            items: completed,
            now: now,
            facts: ["completedCount": Double(completed.count)]
           ) {
            signals.append(signal)
        }

        let overdue = valid.filter { !$0.completed && ($0.dueAt ?? .distantFuture) < now }
        if overdue.count >= 5,
           let signal = aggregateSignal(
            id: "task-backlog",
            items: overdue,
            now: now,
            facts: ["overdueCount": Double(overdue.count)]
           ) {
            signals.append(signal)
        }
        for (type, items) in Dictionary(grouping: overdue, by: \.typeKey) where items.count >= 3 {
            if let signal = aggregateSignal(
                id: "task-delay-type-\(type)",
                items: items,
                now: now,
                facts: ["overdueCount": Double(items.count)],
                anchorValue: type
            ) {
                signals.append(signal)
            }
        }
        return signals.sorted { $0.id < $1.id }
    }

    private static func aggregateSignal(
        id: String,
        items: [TaskMemoryInput],
        now: Date,
        facts: [String: Double],
        anchorValue: String = "task-rhythm"
    ) -> HoloDomainMemorySignal? {
        guard let anchor = try? HoloMemoryAnchorRef(type: .task, value: anchorValue) else {
            return nil
        }
        let revision = digest(items.map { "\($0.id):\($0.revisionDigest)" })
        let evidence = HoloMemoryEvidenceRef(
            id: "\(id)-\(revision)",
            kind: .aggregateSnapshot,
            sourceDomain: .task,
            lineageKey: id,
            revisionDigest: revision,
            observedAt: now,
            aggregateDefinition: "本地按任务稳定 ID、完成状态、截止时间和类型聚合",
            sampleCount: items.count
        )
        return try? HoloDomainSignalBuilder.make(
            id: id,
            domain: .task,
            kind: .aggregate,
            evidence: evidence,
            anchors: [anchor],
            numericFacts: facts,
            prohibitedInferences: [
                "少量逾期不得形成记忆",
                "不得从任务积压推断拖延人格、能力、心理或疾病"
            ]
        )
    }

    private static func digest(_ values: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in values.sorted().joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
