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
        await queryRecordsRead(question: question, currentStateOnly: currentStateOnly).value
    }

    func queryRecordsRead(
        question: String,
        currentStateOnly: Bool
    ) async -> HoloDataSourceRead<[HoloMemoryToolRecord]> {
        guard let service = await queryService() else {
            return HoloDataSourceRead(value: [], status: .unavailable, warning: "记忆查询服务暂不可用")
        }
        let context: HoloMemoryQueryContext
        do {
            context = try await service.query(question: question, consumer: .tool)
        } catch {
            return HoloDataSourceRead(value: [], status: .unavailable, warning: "记忆读取失败：\(error.localizedDescription)")
        }
        let records = context.records
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
        return .loaded(records)
    }

    func suppressionCount() async -> Int {
        await suppressionCountRead().value
    }

    func suppressionCountRead() async -> HoloDataSourceRead<Int> {
        guard let service = await queryService() else {
            return HoloDataSourceRead(value: 0, status: .unavailable, warning: "记忆查询服务暂不可用")
        }
        let count = await service.suppressionCount(consumer: .tool)
        return HoloDataSourceRead(value: count, status: count == 0 ? .empty : .success)
    }

    private func queryService() async -> HoloMemoryQueryService? {
        if let injectedQueryService { return injectedQueryService }
        return try? await HoloMemoryQueryService.live()
    }
}
