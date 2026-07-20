//
//  HoloProjectDataSource.swift
//  Holo
//
//  生产 DataSource：从 SpendingProjectRepository 取全量项目并投影为 tool-local struct。
//
//  线程安全：SpendingProjectRepository 是 @MainActor，用 MainActor.run 取回后立刻投影，
//  避免让 actor 之外的代码持有 MO。项目量级一般 < 几十，全量内存过滤可接受。
//

import Foundation

struct HoloDefaultProjectDataSource: HoloProjectDataSource {

    func snapshot() async -> HoloProjectSnapshot {
        let projects = await MainActor.run {
            SpendingProjectRepository.shared.allProjects()
        }
        let records = projects.map(Self.projectRecord)
        return HoloProjectSnapshot(projects: records)
    }

    static func projectRecord(_ project: SpendingProject) -> HoloProjectToolRecord {
        HoloProjectToolRecord(
            id: project.id,
            name: project.name,
            kind: project.kind,
            amount: Self.double(from: project.amountDecimal),
            frequency: project.frequency,
            startDate: project.startDate,
            endDate: project.endDate,
            nextOccurrenceDate: project.nextOccurrenceDate,
            isPaused: project.isPaused,
            occurrencesGenerated: project.occurrencesGenerated,
            maxOccurrences: project.maxOccurrences,
            usageCount: project.usageCount,
            monthlyCommitment: project.monthlyCommitment.map { double(from: $0) },
            dailyCost: project.dailyCost.map { double(from: $0) },
            perUseCost: project.perUseCost.map { double(from: $0) },
            hasRemainingOccurrences: project.hasRemainingOccurrences
        )
    }

    /// Decimal → Double 统一折算（消费项目金额精度足够，不涉及货币运算）。
    static func double(from decimal: Decimal) -> Double {
        NSDecimalNumber(decimal: decimal).doubleValue
    }
}
