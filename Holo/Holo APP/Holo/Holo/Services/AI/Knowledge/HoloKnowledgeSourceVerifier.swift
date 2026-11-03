//
//  HoloKnowledgeSourceVerifier.swift
//  Holo
//
//  八域来源核验适配（方案 v2.2 §4 / §6 W1）
//
//  每个接入来源必须能返回：存在/版本匹配、已删除、已排除、权限撤回或当前未知。
//  未知不等于仍可用（替换 HoloMemoryUnknownSourceVerifier 的默认 unknown 放行）。
//  档案、任务、目标的当前状态直接读所属 Repository；事件来源核对软删/AI 排除/修订；
//  健康来源沿用本机访问与撤权机制（撤权经同意变更通知进入失效扇出）。
//

import CoreData
import Foundation

nonisolated protocol HoloKnowledgeSourceVerifying: Sendable {
    func verify(_ ref: HoloMemoryEvidenceRef) async -> HoloKnowledgeSourceStatus
}

extension HoloKnowledgeSourceVerifying {
    /// 批量核验（按证据引用 ID 返回）。默认逐条；重载者按实体分批查库。
    func verifyBatch(_ refs: [HoloMemoryEvidenceRef]) async -> [String: HoloKnowledgeSourceStatus] {
        var results: [String: HoloKnowledgeSourceStatus] = [:]
        results.reserveCapacity(refs.count)
        for ref in refs {
            results[ref.id] = await verify(ref)
        }
        return results
    }
}

/// 一组证据的综合状态：取最严重者。
extension HoloKnowledgeSourceVerifying {
    func verify(all refs: [HoloMemoryEvidenceRef]) async -> HoloKnowledgeSourceStatus {
        guard !refs.isEmpty else { return .verified }
        var worst: HoloKnowledgeSourceStatus = .verified
        for ref in refs {
            let status = await verify(ref)
            worst = HoloKnowledgeSourceSeverity.worse(worst, status)
        }
        return worst
    }
}

nonisolated enum HoloKnowledgeSourceSeverity {
    static let order: [HoloKnowledgeSourceStatus] = [
        .verified, .revised, .unknown, .permissionRevoked, .excluded, .deleted
    ]

    static func worse(_ lhs: HoloKnowledgeSourceStatus, _ rhs: HoloKnowledgeSourceStatus) -> HoloKnowledgeSourceStatus {
        let l = order.firstIndex(of: lhs) ?? 0
        let r = order.firstIndex(of: rhs) ?? 0
        return order[max(l, r)]
    }
}

// MARK: - 业务库核验

/// 直接查业务 Core Data：按 sourceDomain 路由，不解析实体词。
final class HoloKnowledgeCoreDataSourceVerifier: HoloKnowledgeSourceVerifying, @unchecked Sendable {
    private let businessContainer: NSPersistentContainer
    /// 健康授权判定（HealthKit 访问状态由健康模块拥有；注入避免跨模块硬依赖）。
    private let healthAccessProvider: @Sendable () -> HoloKnowledgeSourceStatus

    init(
        businessContainer: NSPersistentContainer,
        healthAccessProvider: @escaping @Sendable () -> HoloKnowledgeSourceStatus = { .unknown }
    ) {
        self.businessContainer = businessContainer
        self.healthAccessProvider = healthAccessProvider
    }

    func verify(_ ref: HoloMemoryEvidenceRef) async -> HoloKnowledgeSourceStatus {
        // 用户原话的证据是独立来源，不依赖业务行存活。
        if ref.kind == .explicitUserStatement { return .verified }
        switch ref.sourceDomain {
        case .profile:
            // 档案由原模块拥有当前状态；记忆只持有引用，查询实时解析 → 视为可核验。
            return .verified
        case .health:
            return healthAccessProvider()
        case .thought:
            return await verifyThought(ref)
        case .task:
            return await verifyRow(entity: "TodoTask", ref: ref, softDeleteKey: "deletedAt")
        case .habit:
            return await verifyRow(entity: "HabitRecord", ref: ref, softDeleteKey: nil)
        case .finance:
            if ref.lineageKey.hasPrefix("finance:budget:") { return .verified }
            return await verifyRow(entity: "Transaction", ref: ref, softDeleteKey: "deletedAt")
        case .goal:
            return await verifyRow(entity: "Goal", ref: ref, softDeleteKey: "deletedAt")
        case .conversation:
            return await verifyRow(entity: "ChatMessage", ref: ref, softDeleteKey: "deletedAt")
        }
    }

    /// 批量核验：与逐条 verify 同一判定口径，但按实体分批（IN 查询、单上下文）
    /// ——管理页整页核验从 O(记录×证据) 次单行查库降为每实体常数次。
    func verifyBatch(_ refs: [HoloMemoryEvidenceRef]) async -> [String: HoloKnowledgeSourceStatus] {
        let refByID = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var results: [String: HoloKnowledgeSourceStatus] = [:]
        results.reserveCapacity(refs.count)
        var rowsByEntity: [String: [(refID: String, uuid: UUID)]] = [:]
        var thoughtRefIDs: Set<String> = []

        // 1. 分流：免查库的先出结果；要查行的按实体分组。
        for ref in refs {
            if ref.kind == .explicitUserStatement { results[ref.id] = .verified; continue }
            switch ref.sourceDomain {
            case .profile:
                results[ref.id] = .verified
            case .health:
                results[ref.id] = healthAccessProvider()
            case .finance where ref.lineageKey.hasPrefix("finance:budget:"):
                results[ref.id] = .verified
            case .thought:
                guard let id = Self.uuid(from: ref) else { results[ref.id] = .unknown; continue }
                rowsByEntity["Thought", default: []].append((ref.id, id))
                thoughtRefIDs.insert(ref.id)
            case .task:
                guard let id = Self.uuid(from: ref) else { results[ref.id] = .unknown; continue }
                rowsByEntity["TodoTask", default: []].append((ref.id, id))
            case .habit:
                guard let id = Self.uuid(from: ref) else { results[ref.id] = .unknown; continue }
                rowsByEntity["HabitRecord", default: []].append((ref.id, id))
            case .finance:
                guard let id = Self.uuid(from: ref) else { results[ref.id] = .unknown; continue }
                rowsByEntity["Transaction", default: []].append((ref.id, id))
            case .goal:
                guard let id = Self.uuid(from: ref) else { results[ref.id] = .unknown; continue }
                rowsByEntity["Goal", default: []].append((ref.id, id))
            case .conversation:
                guard let id = Self.uuid(from: ref) else { results[ref.id] = .unknown; continue }
                rowsByEntity["ChatMessage", default: []].append((ref.id, id))
            }
        }
        guard !rowsByEntity.isEmpty else { return results }

        // 2. 每实体分块 IN 查询，一个后台上下文跑完全部（不再每证据新建上下文）。
        let softDeleteKeys: [String: String?] = [
            "Thought": "deletedAt",
            "TodoTask": "deletedAt",
            "HabitRecord": nil,
            "Transaction": "deletedAt",
            "Goal": "deletedAt",
            "ChatMessage": "deletedAt",
        ]
        let context = businessContainer.newBackgroundContext()
        let chunkLimit = 400
        for (entity, rows) in rowsByEntity {
            var index = 0
            while index < rows.count {
                let chunk = rows[index..<min(index + chunkLimit, rows.count)]
                index += chunkLimit
                let chunkArray = Array(chunk)
                let uuidArguments = chunkArray.map { $0.uuid as NSUUID } as NSArray
                let foundByUUID: [UUID: NSManagedObject] = await context.perform {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                    request.predicate = NSPredicate(format: "id IN %@", uuidArguments)
                    var map: [UUID: NSManagedObject] = [:]
                    for object in (try? context.fetch(request)) ?? [] {
                        if let id = object.value(forKey: "id") as? UUID { map[id] = object }
                    }
                    return map
                }
                let softDeleteKey = softDeleteKeys[entity] ?? nil
                for (refID, uuid) in chunkArray {
                    guard let object = foundByUUID[uuid] else {
                        results[refID] = .deleted
                        continue
                    }
                    if let softDeleteKey,
                       object.entity.attributesByName[softDeleteKey] != nil,
                       (object.value(forKey: softDeleteKey) as? Date) != nil {
                        results[refID] = .deleted
                        continue
                    }
                    if thoughtRefIDs.contains(refID), let thought = object as? Thought,
                       ThoughtAIAudience.isExcluded(thought) {
                        results[refID] = .excluded
                        continue
                    }
                    let observedAt = refByID[refID]?.observedAt ?? .distantPast
                    results[refID] = Self.revisionStatus(object: object, observedAt: observedAt)
                }
            }
        }
        return results
    }

    private func verifyThought(_ ref: HoloMemoryEvidenceRef) async -> HoloKnowledgeSourceStatus {
        guard let id = Self.uuid(from: ref) else { return .unknown }
        let context = businessContainer.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<Thought>(entityName: "Thought")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let thought = try? context.fetch(request).first else { return .deleted }
            if (thought.value(forKey: "deletedAt") as? Date) != nil { return .deleted }
            if ThoughtAIAudience.isExcluded(thought) { return .excluded }
            return Self.revisionStatus(object: thought, observedAt: ref.observedAt)
        }
    }

    private func verifyRow(
        entity: String,
        ref: HoloMemoryEvidenceRef,
        softDeleteKey: String?
    ) async -> HoloKnowledgeSourceStatus {
        guard let id = Self.uuid(from: ref) else { return .unknown }
        let context = businessContainer.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let object = try? context.fetch(request).first else { return .deleted }
            if let softDeleteKey,
               object.entity.attributesByName[softDeleteKey] != nil,
               (object.value(forKey: softDeleteKey) as? Date) != nil {
                return .deleted
            }
            return Self.revisionStatus(object: object, observedAt: ref.observedAt)
        }
    }

    /// 修订判定：实体有 updatedAt 且晚于证据观察时刻 → revised（需重核，不等于失效）。
    private static func revisionStatus(object: NSManagedObject, observedAt: Date) -> HoloKnowledgeSourceStatus {
        guard object.entity.attributesByName["updatedAt"] != nil,
              let updatedAt = object.value(forKey: "updatedAt") as? Date else {
            return .verified
        }
        return updatedAt.timeIntervalSince(observedAt) > 1 ? .revised : .verified
    }

    /// sourceID 优先；否则从 lineageKey 末段取 UUID（"thought:<uuid>" / "habit:<uuid>"）。
    static func uuid(from ref: HoloMemoryEvidenceRef) -> UUID? {
        if let sourceID = ref.sourceID, let uuid = UUID(uuidString: sourceID) { return uuid }
        let tail = ref.lineageKey.split(separator: ":").last.map(String.init) ?? ref.lineageKey
        return UUID(uuidString: tail)
    }
}

// MARK: - 管理页/保存门用的实时核验桥（替换默认 unknown 放行）

/// 把知识层核验器接到既有 HoloMemorySourceAvailabilityVerifying（管理投影输入）。
/// 管理页换上本桥后，「来源已失效」分组才反映真实来源状态（M07 真实核验器）。
struct HoloKnowledgeSourceAvailabilityBridge: HoloMemorySourceAvailabilityVerifying {
    let verifier: any HoloKnowledgeSourceVerifying

    init(verifier: any HoloKnowledgeSourceVerifying) {
        self.verifier = verifier
    }

    func availability(of record: HoloMemoryRecord) async -> HoloMemoryManagementSourceAvailability {
        let status = await verifier.verify(all: record.evidenceRefs)
        switch status {
        case .verified, .revised: return .available
        case .deleted, .excluded, .permissionRevoked: return .invalid
        case .unknown: return .unknown
        }
    }

    /// 整页批量：一次收齐全部证据引用 → 批量核验 → 按记录取最严重者。
    /// 与逐条 availability 同一判定（worst-of-refs）。
    func availabilities(
        for records: [HoloMemoryRecord]
    ) async -> [String: HoloMemoryManagementSourceAvailability] {
        let allRefs = records.flatMap(\.evidenceRefs)
        let statusByRefID = await verifier.verifyBatch(allRefs)
        var out: [String: HoloMemoryManagementSourceAvailability] = [:]
        out.reserveCapacity(records.count)
        for record in records {
            var worst = HoloKnowledgeSourceStatus.verified
            for ref in record.evidenceRefs {
                let status = statusByRefID[ref.id] ?? .unknown
                worst = HoloKnowledgeSourceSeverity.worse(worst, status)
            }
            switch worst {
            case .verified, .revised: out[record.id] = .available
            case .deleted, .excluded, .permissionRevoked: out[record.id] = .invalid
            case .unknown: out[record.id] = .unknown
            }
        }
        return out
    }
}
