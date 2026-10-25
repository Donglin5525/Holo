//
//  HoloMemoryManagementReadService.swift
//  Holo
//
//  记忆管理页统一读服务（方案《Holo 记忆管理独立与升级》§11.1）
//
//  职责：读取合法记录与控制状态 → 构建统一管理投影。只读不写：
//  不触发萃取、不产生模型调用、不修改设置。所有页面与计数的口径
//  由 HoloMemoryManagementProjection 唯一决定，本服务不另做 state 判断。
//

import Foundation

/// 管理列表查询契约（§4.1-§4.3）。默认作用于单一桶；搜索为本地文本匹配，
/// 只匹配当前陈述与主题词，不搜已删除正文或旧证据快照。
nonisolated struct HoloMemoryManagementListQuery: Equatable, Sendable {
    var bucket: HoloMemoryManagementBucket
    var timeGroup: HoloMemoryManagementTimeGroup?
    var origin: HoloMemoryManagementOrigin?
    var domain: HoloMemoryDomain?
    var searchText: String?

    init(
        bucket: HoloMemoryManagementBucket,
        timeGroup: HoloMemoryManagementTimeGroup? = nil,
        origin: HoloMemoryManagementOrigin? = nil,
        domain: HoloMemoryDomain? = nil,
        searchText: String? = nil
    ) {
        self.bucket = bucket
        self.timeGroup = timeGroup
        self.origin = origin
        self.domain = domain
        self.searchText = searchText
    }
}

/// 一次读取产出的管理快照：全量投影（已排序）+ 桶计数（与列表同一投影）。
nonisolated struct HoloMemoryManagementSnapshot: Equatable, Sendable {
    let projections: [HoloMemoryManagementProjection]
    let summary: HoloMemoryManagementProjectionSummary
    let generatedAt: Date

    /// 应用查询契约（§4.3：计数与列表同一投影，跨域记忆只计一次）。
    func applying(_ query: HoloMemoryManagementListQuery) -> [HoloMemoryManagementProjection] {
        projections.filter { projection in
            guard projection.bucket == query.bucket else { return false }
            if let timeGroup = query.timeGroup, projection.timeGroup != timeGroup { return false }
            if let origin = query.origin, projection.originLabel != origin { return false }
            if let domain = query.domain {
                // 跨域记忆可匹配多个来源域，但一条只出现/只计一次（§4.3）。
                guard let recordDomains = sourceDomainsByRecordID[projection.recordID],
                      recordDomains.contains(domain) else { return false }
            }
            if let searchText = query.searchText, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let needle = searchText.lowercased()
                let haystack = (projection.displayText + " " + (subjectKeysByRecordID[projection.recordID] ?? ""))
                    .lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }

    let sourceDomainsByRecordID: [String: Set<HoloMemoryDomain>]
    let subjectKeysByRecordID: [String: String]
}

/// 来源可用性核验器（§9.1）。M02 阶段用 Unknown 实现——逐证据核验
/// （软删 / AI 排除 / 版本相符）由 M07 的真实核验器注入，届时管理页
/// 才会展示「来源已失效」分组；在此之前不臆断来源状态。
protocol HoloMemorySourceAvailabilityVerifying: Sendable {
    func availability(of record: HoloMemoryRecord) async -> HoloMemoryManagementSourceAvailability
}

/// 默认核验器：恒 .unknown（M02 过渡口径，见协议注释）。
struct HoloMemoryUnknownSourceVerifier: HoloMemorySourceAvailabilityVerifying {
    func availability(of record: HoloMemoryRecord) async -> HoloMemoryManagementSourceAvailability {
        .unknown
    }
}

final class HoloMemoryManagementReadService: Sendable {
    private let repository: any HoloMemoryRepository
    private let sourceVerifier: any HoloMemorySourceAvailabilityVerifying

    init(
        repository: any HoloMemoryRepository,
        sourceVerifier: any HoloMemorySourceAvailabilityVerifying = HoloMemoryUnknownSourceVerifier()
    ) {
        self.repository = repository
        self.sourceVerifier = sourceVerifier
    }

    /// 读取全部合法记录并构建管理快照。回答开关只影响 useLabel/isPausedForAnswering，
    /// 由调用方传入（设置仍由 HoloMemorySettings 唯一持有，本服务不复制配置）。
    func loadSnapshot(answeringEnabled: Bool, now: Date? = nil) async throws -> HoloMemoryManagementSnapshot {
        let records = try await repository.query(.all)
        // noLongerUse 路径的墓碑 identityKey = 记录 id；萃取阻断用的语义墓碑
        // 键形不同，不会被误认作用户停用证据。
        let tombstonedRecordIDs = Set(
            try await repository.queryTombstones().map(\.identityKey)
        )
        let now = now ?? Date()
        let context = HoloMemoryManagementProjectionContext(now: now, answeringEnabled: answeringEnabled)

        var projections: [HoloMemoryManagementSnapshotItem] = []
        projections.reserveCapacity(records.count)
        for record in records {
            let availability = await sourceVerifier.availability(of: record)
            let input = HoloMemoryManagementProjectionInput(
                record: record,
                hasUserControlTombstone: tombstonedRecordIDs.contains(record.id),
                sourceAvailability: availability
            )
            projections.append(
                HoloMemoryManagementSnapshotItem(
                    projection: HoloMemoryManagementProjection.project(input, context: context),
                    sourceDomains: Set(record.sourceDomains),
                    subjectKey: record.subjectKey
                )
            )
        }

        let sorted = projections
            .sorted {
                HoloMemoryManagementProjection.isInOrder($0.projection, before: $1.projection)
            }
        return HoloMemoryManagementSnapshot(
            projections: sorted.map(\.projection),
            summary: HoloMemoryManagementProjection.summarize(sorted.map(\.projection)),
            generatedAt: now,
            sourceDomainsByRecordID: Dictionary(
                sorted.map { ($0.projection.recordID, $0.sourceDomains) },
                uniquingKeysWith: { first, _ in first }
            ),
            subjectKeysByRecordID: Dictionary(
                sorted.map { ($0.projection.recordID, $0.subjectKey) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }
}

/// 内部聚合项：投影 + 列表查询需要的旁路字段（来源域 / 主题词）。
private nonisolated struct HoloMemoryManagementSnapshotItem: Sendable {
    let projection: HoloMemoryManagementProjection
    let sourceDomains: Set<HoloMemoryDomain>
    let subjectKey: String
}
