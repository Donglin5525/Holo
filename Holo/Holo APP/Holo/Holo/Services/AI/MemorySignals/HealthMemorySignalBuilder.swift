//
//  HealthMemorySignalBuilder.swift
//  Holo
//
//  健康记忆只接受本地聚合快照，不复制 HealthKit 原始样本。
//

import Foundation

nonisolated struct HealthMemoryAggregateInput: Equatable, Sendable {
    var metricKey: String
    var displayName: String
    var average: Double?
    var minimum: Double?
    var maximum: Double?
    var sampleCount: Int
    var windowStart: Date
    var windowEnd: Date
    var revisionDigest: String
}

nonisolated enum HealthMemorySignalBuilder {
    static func build(from inputs: [HealthMemoryAggregateInput]) -> [HoloDomainMemorySignal] {
        inputs.compactMap { input in
            guard input.sampleCount > 0,
                  let average = input.average,
                  average.isFinite,
                  !input.metricKey.isEmpty,
                  !input.revisionDigest.isEmpty,
                  let anchor = try? HoloMemoryAnchorRef(
                    type: .healthMetric,
                    value: input.metricKey,
                    displayLabel: input.displayName
                  ) else { return nil }
            var facts = ["average": average, "sampleCount": Double(input.sampleCount)]
            if let minimum = input.minimum, minimum.isFinite { facts["minimum"] = minimum }
            if let maximum = input.maximum, maximum.isFinite { facts["maximum"] = maximum }
            let evidence = HoloMemoryEvidenceRef(
                id: "health-aggregate-\(input.metricKey)-\(input.revisionDigest)",
                kind: .aggregateSnapshot,
                sourceDomain: .health,
                lineageKey: "health:aggregate:\(input.metricKey)",
                revisionDigest: input.revisionDigest,
                observedAt: input.windowEnd,
                validFrom: input.windowStart,
                validTo: input.windowEnd,
                aggregateDefinition: "仅保存本地计算的区间统计，不保存 HealthKit 原始样本",
                sampleCount: input.sampleCount
            )
            return try? HoloDomainSignalBuilder.make(
                id: "health-trend-\(input.metricKey)",
                domain: .health,
                kind: .aggregate,
                evidence: evidence,
                anchors: [anchor],
                numericFacts: facts,
                prohibitedInferences: [
                    "不得进行医疗诊断、疾病判断或治疗建议",
                    "缺失健康数据不得解释为异常",
                    "健康派生记忆必须保持 sensitiveLocal，不得进入普通同步 Store"
                ]
            )
        }.sorted { $0.id < $1.id }
    }
}
