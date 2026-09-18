//
//  GoalWorkshopStore.swift
//  Holo
//
//  目标共创会话存储（方案任务 2 / §2.4）
//
//  - load / saveIfRevisionMatches（单调 revision 守卫）/ listResumable / discard
//  - iCloud 副本同 id 去重（fetch 按 updatedAt 取最新）
//  - 未知 payload 版本隔离：解码失败不覆盖、不影响其他会话
//

import Foundation
import CoreData

@MainActor
final class GoalWorkshopStore {

    static let shared = GoalWorkshopStore()

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    private init() {
        self.context = CoreDataStack.shared.viewContext
    }

    // MARK: - 读取

    /// 按 id 读取会话；不存在返回 nil。payload 版本未知/损坏时抛错（数据保留不覆盖）
    func load(id: UUID) throws -> GoalWorkshopSessionV1? {
        guard let mo = fetchLatest(id: id) else { return nil }
        return try mo.decodeSession()
    }

    /// 可恢复会话：非终态、未删除，按更新时间倒序（「继续/放弃/另建」入口用）
    func listResumable() throws -> [GoalWorkshopSessionV1] {
        let request = NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND phaseRaw != %@ AND phaseRaw != %@",
            GoalWorkshopPhase.saved.rawValue,
            GoalWorkshopPhase.abandoned.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        let rows = (try? context.fetch(request)) ?? []
        var seen = Set<UUID>()
        var sessions: [GoalWorkshopSessionV1] = []
        for row in rows where !seen.contains(row.id) {
            seen.insert(row.id)
            // 单条损坏不拖垮整个列表：跳过并保留数据
            if let session = try? row.decodeSession() {
                sessions.append(session)
            }
        }
        return sessions
    }

    // MARK: - 写入

    /// 单调 revision 写入：新 revision 必须大于已存值；expectedRevision ≥ 0 时
    /// 额外校验调用方视角未过期（他方已推进则抛冲突，绝不覆盖较新数据）
    func saveIfRevisionMatches(_ snapshot: GoalWorkshopSessionV1, expectedRevision: Int64 = -1) throws {
        if let existing = fetchLatest(id: snapshot.id) {
            let stored = existing.revision
            if expectedRevision >= 0 && stored != expectedRevision {
                throw GoalWorkshopStoreError.revisionConflict(stored: stored, incoming: Int64(snapshot.revision))
            }
            guard Int64(snapshot.revision) > stored else {
                throw GoalWorkshopStoreError.revisionConflict(stored: stored, incoming: Int64(snapshot.revision))
            }
            existing.apply(payload: GoalWorkshopSessionPayload(session: snapshot))
        } else {
            let mo = GoalWorkshopSessionMO.make(in: context, payload: GoalWorkshopSessionPayload(session: snapshot))
            mo.revision = Int64(snapshot.revision)
        }
        try context.save()
    }

    /// 放弃并删除会话（用户在「继续/放弃」里选择放弃时）
    func discard(id: UUID) throws {
        let request = NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        for row in (try? context.fetch(request)) ?? [] {
            context.delete(row)
        }
        try context.save()
    }

    // MARK: - 取数

    /// iCloud 天然存在同 id 副本：按 updatedAt 取最新一条
    private func fetchLatest(id: UUID) -> GoalWorkshopSessionMO? {
        let request = NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
