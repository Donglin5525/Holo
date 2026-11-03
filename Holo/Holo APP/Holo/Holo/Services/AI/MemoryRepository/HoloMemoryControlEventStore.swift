//
//  HoloMemoryControlEventStore.swift
//  Holo
//
//  用户控制事件存储（方案 §11.4 / M03-b）
//
//  事件只记录控制事实与差异摘要，不存记忆正文；随记录落同域容器
//  （探测记录实际所在库，敏感记录的事件不进普通同步库，§9.3）。
//  本类只管事件行的增查标；「事件→记录状态」的落库事务见
//  HoloMemoryUserControlTransaction，崩溃重放见 reconcile(outstanding:)。
//

import CoreData
import Foundation

enum HoloMemoryControlEventStoreError: Error, Equatable {
    /// 记录在两个库中都不存在，事件无处安放（控制操作对象必须先存在）。
    case recordNotFound
}

final class HoloMemoryControlEventStore: @unchecked Sendable {
    private let controller: HoloMemoryPersistenceController

    init(controller: HoloMemoryPersistenceController) {
        self.controller = controller
    }

    // MARK: - 写入

    /// 追加控制事件。幂等：同 operationID 的事件已存在时不再写入，返回 false。
    /// 落库位置 = 记录实际所在容器（同域原则）。
    @discardableResult
    func append(_ event: HoloMemoryUserControlEvent) async throws -> Bool {
        let container = try await resolveContainer(forRecordID: event.targetRecordID)
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
            request.predicate = NSPredicate(format: "operationID == %@ AND targetRecordID == %@",
                                            event.operationID, event.targetRecordID)
            request.fetchLimit = 1
            if try context.count(for: request) > 0 {
                return false
            }

            let mo = HoloMemoryControlEventMO(context: context)
            Self.write(event, into: mo)
            try context.save()
            return true
        }
    }

    /// 标记事件的记录效果已落库（事务第③步/重放完成）。
    func markApplied(eventID: String, at date: Date) async throws {
        for container in [controller.mainContainer, controller.sensitiveContainer] {
            let context = container.newBackgroundContext()
            let found = try await context.perform {
                let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
                request.predicate = NSPredicate(format: "id == %@ AND appliedAt == nil", eventID)
                request.fetchLimit = 1
                guard let mo = try context.fetch(request).first else { return false }
                mo.appliedAt = date
                try context.save()
                return true
            }
            if found { return }
        }
    }

    /// 删除清理配套（M05）：记录被删除后其事件一并物理清除（两库）。
    func removeEvents(forRecordIDs recordIDs: [String]) async throws {
        guard !recordIDs.isEmpty else { return }
        for container in [controller.mainContainer, controller.sensitiveContainer] {
            let context = container.newBackgroundContext()
            try await context.perform {
                let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
                request.predicate = NSPredicate(format: "targetRecordID IN %@", recordIDs)
                for mo in try context.fetch(request) {
                    context.delete(mo)
                }
                if context.hasChanges {
                    try context.save()
                }
            }
        }
    }

    // MARK: - 查询

    /// 某记录的全部控制事件（按发生时间升序；未软删）。
    func events(forRecordID recordID: String) async throws -> [HoloMemoryUserControlEvent] {
        let container = try await resolveContainer(forRecordID: recordID)
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
            request.predicate = NSPredicate(
                format: "targetRecordID == %@ AND deletedAt == nil", recordID
            )
            request.sortDescriptors = [NSSortDescriptor(key: "occurredAt", ascending: true)]
            return try context.fetch(request).map(Self.read(from:))
        }
    }

    /// 该记录最新的控制事件 ID（请求的 knownControlEventIDs 输入）。
    func latestEventID(forRecordID recordID: String) async throws -> String? {
        try await events(forRecordID: recordID).last?.id
    }

    /// 按幂等操作号查事件（撤销入口：定位要撤销的那笔）。
    func event(byOperationID operationID: String, recordID: String) async throws -> HoloMemoryUserControlEvent? {
        let container = try await resolveContainer(forRecordID: recordID)
        let context = container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
            request.predicate = NSPredicate(
                format: "operationID == %@ AND targetRecordID == %@ AND deletedAt == nil",
                operationID, recordID
            )
            request.fetchLimit = 1
            return try context.fetch(request).first.map(Self.read(from:))
        }
    }

    /// 两库中所有「已落事件但记录未体现」的待重放事件（崩溃恢复输入）。
    func outstandingEvents() async throws -> [HoloMemoryUserControlEvent] {
        var result: [HoloMemoryUserControlEvent] = []
        for container in [controller.mainContainer, controller.sensitiveContainer] {
            let context = container.newBackgroundContext()
            let events = try await context.perform {
                let request = NSFetchRequest<HoloMemoryControlEventMO>(entityName: "HoloMemoryControlEventMO")
                request.predicate = NSPredicate(format: "appliedAt == nil AND deletedAt == nil")
                request.sortDescriptors = [NSSortDescriptor(key: "occurredAt", ascending: true)]
                return try context.fetch(request).map(Self.read(from:))
            }
            result.append(contentsOf: events)
        }
        return result
    }

    // MARK: - MO ↔ 领域映射

    private static func write(_ event: HoloMemoryUserControlEvent, into mo: HoloMemoryControlEventMO) {
        mo.id = event.id
        mo.targetRecordID = event.targetRecordID
        mo.kind = event.kind.rawValue
        let ids = Array(event.priorEventIDs).sorted()
        mo.priorEventIDsJSON = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
        mo.basedOnContentVersion = Int64(event.basedOnContentVersion)
        mo.resultingContentVersion = Int64(event.resultingContentVersion)
        mo.occurredAt = event.occurredAt
        mo.operationID = event.operationID
        mo.payloadDigest = event.payloadDigest
        mo.appliedAt = nil
        mo.schemaVersion = 1
    }

    private static func read(from mo: HoloMemoryControlEventMO) -> HoloMemoryUserControlEvent {
        let priorIDs: Set<String> = {
            guard let data = mo.priorEventIDsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(ids)
        }()
        return HoloMemoryUserControlEvent(
            id: mo.id,
            targetRecordID: mo.targetRecordID,
            kind: HoloMemoryControlEventKind(rawValue: mo.kind) ?? .confirmed,
            priorEventIDs: priorIDs,
            basedOnContentVersion: Int(mo.basedOnContentVersion),
            resultingContentVersion: Int(mo.resultingContentVersion),
            occurredAt: mo.occurredAt,
            operationID: mo.operationID,
            payloadDigest: mo.payloadDigest
        )
    }

    // MARK: - 同域路由（跟着记录走）

    /// 事件与记录同库：按记录实际所在容器路由；两库皆无 → recordNotFound。
    private func resolveContainer(
        forRecordID recordID: String
    ) async throws -> NSPersistentContainer {
        for container in [controller.mainContainer, controller.sensitiveContainer] {
            let context = container.newBackgroundContext()
            let exists = try await context.perform {
                let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
                request.predicate = NSPredicate(format: "stableID == %@", recordID)
                request.fetchLimit = 1
                return try context.count(for: request) > 0
            }
            if exists {
                return container
            }
        }
        throw HoloMemoryControlEventStoreError.recordNotFound
    }
}
