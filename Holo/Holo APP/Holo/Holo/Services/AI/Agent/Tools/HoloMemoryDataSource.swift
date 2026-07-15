//
//  HoloMemoryDataSource.swift
//  Holo
//
//  生产 Memory Tool 数据源：不再直读旧 Store，只调用统一 Query Service。
//

import Foundation

struct HoloDefaultMemoryDataSource: HoloMemoryDataSource {
    private let injectedQueryService: HoloMemoryQueryService?

    init(queryService: HoloMemoryQueryService? = nil) {
        injectedQueryService = queryService
    }

    func queryRecords(
        question: String,
        currentStateOnly: Bool
    ) async -> [HoloMemoryToolRecord] {
        guard let service = await queryService(),
              let context = try? await service.query(
                question: question,
                consumer: .tool
              ) else { return [] }
        return context.records
            .filter { !currentStateOnly || $0.persistenceClass == .currentState }
            .map {
                HoloMemoryToolRecord(
                    id: $0.id,
                    title: $0.scope == .crossDomain
                        ? "跨域观察"
                        : ($0.primaryDomain?.rawValue ?? "记忆"),
                    summary: $0.aiUseSummary,
                    occurredAt: $0.lastSupportedAt ?? $0.updatedAt,
                    persistenceClass: $0.persistenceClass
                )
            }
    }

    func suppressionCount() async -> Int {
        guard let service = await queryService() else { return 0 }
        return await service.suppressionCount(consumer: .tool)
    }

    private func queryService() async -> HoloMemoryQueryService? {
        if let injectedQueryService { return injectedQueryService }
        return try? await HoloMemoryQueryService.live()
    }
}
