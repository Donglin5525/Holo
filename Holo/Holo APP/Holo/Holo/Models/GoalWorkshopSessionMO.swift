//
//  GoalWorkshopSessionMO.swift
//  Holo
//
//  目标共创会话的持久化对象（方案任务 2）
//
//  会话只存恢复所需的结构化摘要（payloadJSON 版本化信封），
//  不复制完整聊天记录。originalText 等常用字段提级存储，供列表免解析展示。
//

import Foundation
import CoreData

/// 存储层错误（定义在 MO 文件：widget 共享编译闭包不含 Store 本体）
enum GoalWorkshopStoreError: Error, Equatable {
    /// 旧 revision（或同 revision 重复）写入被拒；调用方应重读再试
    case revisionConflict(stored: Int64, incoming: Int64)
    /// payload 来自更新版本的 App：保留原数据，本次会话不可恢复
    case incompatiblePayload(version: Int)
    case corruptedPayload(sessionID: UUID)
}

/// 会话 payload 信封：schemaVersion 参与 Codable，未知版本由 Store 隔离
struct GoalWorkshopSessionPayload: Codable, Equatable {
    var schemaVersion: Int
    var session: GoalWorkshopSessionV1

    init(schemaVersion: Int = Int(GoalWorkshopSchemaDefaults.payloadSchemaVersion), session: GoalWorkshopSessionV1) {
        self.schemaVersion = schemaVersion
        self.session = session
    }
}

@objc(GoalWorkshopSessionMO)
final class GoalWorkshopSessionMO: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var schemaVersion: Int16
    /// P0：已有目标入口只给建议不写回；nil = 新建会话
    @NSManaged var goalID: UUID?
    @NSManaged var phaseRaw: String
    /// 已持久化的会话 revision（单调递增；旧值写入会被 Store 拒绝）
    @NSManaged var revision: Int64
    @NSManaged var originalText: String
    @NSManaged var payloadJSON: String
    /// 保存成功后由提交服务写入的目标 ID
    @NSManaged var appliedGoalID: UUID?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var phase: GoalWorkshopPhase {
        get { GoalWorkshopPhase(rawValue: phaseRaw) ?? .abandoned }
        set { phaseRaw = newValue.rawValue }
    }

    // MARK: - 构造

    static func make(in context: NSManagedObjectContext, payload: GoalWorkshopSessionPayload) -> GoalWorkshopSessionMO {
        let mo = GoalWorkshopSessionMO(context: context)
        mo.id = payload.session.id
        mo.schemaVersion = GoalWorkshopSchemaDefaults.payloadSchemaVersion
        mo.goalID = payload.session.goalID
        mo.phase = payload.session.phase
        mo.revision = Int64(payload.session.revision)
        mo.originalText = payload.session.originalText
        mo.payloadJSON = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        mo.appliedGoalID = payload.session.appliedGoalID
        mo.createdAt = payload.session.createdAt
        mo.updatedAt = payload.session.updatedAt
        return mo
    }

    /// 从 MO 重建会话值；payload 版本未知或损坏时抛错，由调用方隔离展示
    func decodeSession() throws -> GoalWorkshopSessionV1 {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw GoalWorkshopStoreError.corruptedPayload(sessionID: id)
        }
        // 先轻量查信封版本：未来版本的结构可能已无法解析，须在解码前隔离
        if let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let version = (envelope["schemaVersion"] as? NSNumber)?.intValue,
           version > Int(GoalWorkshopSchemaDefaults.payloadSchemaVersion) {
            throw GoalWorkshopStoreError.incompatiblePayload(version: version)
        }
        let payload = try JSONDecoder().decode(GoalWorkshopSessionPayload.self, from: data)
        return payload.session
    }

    func apply(payload: GoalWorkshopSessionPayload) {
        goalID = payload.session.goalID
        phase = payload.session.phase
        revision = Int64(payload.session.revision)
        originalText = payload.session.originalText
        payloadJSON = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        appliedGoalID = payload.session.appliedGoalID
        updatedAt = payload.session.updatedAt
    }
}
