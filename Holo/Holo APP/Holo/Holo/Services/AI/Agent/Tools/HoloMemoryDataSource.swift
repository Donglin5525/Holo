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
                // primaryDomain.rawValue 是英文（finance/habit…），这里翻译成中文域名称，
                // 避免英文漏进 LLM 上下文被复述给用户。复用语义目录的 topic 映射。
                let domainTitle: String
                if $0.scope == .crossDomain {
                    domainTitle = "跨域观察"
                } else if let domain = $0.primaryDomain {
                    domainTitle = HoloMetricSemanticCatalog.topic(for: "\(domain.rawValue).memory")
                } else {
                    domainTitle = "记忆"
                }
                return HoloMemoryToolRecord(
                    id: $0.id,
                    title: domainTitle,
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
