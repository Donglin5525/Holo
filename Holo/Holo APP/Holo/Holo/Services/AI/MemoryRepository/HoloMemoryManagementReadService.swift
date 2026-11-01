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
    /// 原始记录（按 ID）：调用方（行元数据、详情跳转）复用同一次全量读取，
    /// 不再各自再查一遍全库（2026-11-01 性能修复批）。
    let recordsByID: [String: HoloMemoryRecord]

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

extension HoloMemorySourceAvailabilityVerifying {
    /// 整页批量核验（按记录 ID 返回）。默认逐条；高效实现按实体分批查库
    /// （管理页全量核验从每证据一次查库降为每实体常数次）。
    func availabilities(
        for records: [HoloMemoryRecord]
    ) async -> [String: HoloMemoryManagementSourceAvailability] {
        var out: [String: HoloMemoryManagementSourceAvailability] = [:]
        out.reserveCapacity(records.count)
        for record in records {
            out[record.id] = await availability(of: record)
        }
        return out
    }
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

        // 展示集合先收敛，再对**展示集合**做批量来源核验（整页一次分批查库，
        // 不再逐记录逐证据单行查——2026-11-01 性能修复批）。
        var visible: [HoloMemoryRecord] = []
        visible.reserveCapacity(records.count)
        for record in records {
            // v2.2 §4/§7.2：自动单次流水退出主记忆展示；未确认的行为推断不再以
            // 「观察中」成堆出现——成熟者经统一准入进「值得确认」区（该区读知识侧
            // 投影，与本列表互不代位）。记录本身不删：原业务事实仍在各模块，全局导出仍包含。
            switch HoloKnowledgeLegacyAdapter.classify(record) {
            case .autoLowValue, .autoInferenceUnconfirmed:
                continue
            default:
                visible.append(record)
            }
        }
        let availabilityByRecordID = await sourceVerifier.availabilities(for: visible)

        var projections: [HoloMemoryManagementSnapshotItem] = []
        projections.reserveCapacity(visible.count)
        for record in visible {
            let input = HoloMemoryManagementProjectionInput(
                record: record,
                hasUserControlTombstone: tombstonedRecordIDs.contains(record.id),
                sourceAvailability: availabilityByRecordID[record.id] ?? .unknown
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
            recordsByID: Dictionary(
                records.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
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
