//
//  HoloMatterEvent+CoreDataClass.swift
//  Holo
//
//  Matter 事件流：最近发生了什么、如何撤销的唯一真相源
//
//  每个状态变化都有来源、actor、时间和幂等键；最近变化列表只读事件流，不从当前状态倒推。
//  撤销通过写入带 revertsEventID 的反向事件完成，不直接抹掉审计记录。
//

import Foundation
import CoreData

@objc(HoloMatterEvent)
final class HoloMatterEvent: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var matterID: UUID
    /// 重试不重复落事件（方案 §10.2）。
    @NSManaged var idempotencyKey: String
    @NSManaged var kindRaw: String
    @NSManaged var actorRaw: String
    /// 最小变更载荷；不保存模型思维链。
    @NSManaged var payloadJSON: String?
    @NSManaged var sourceTypeRaw: String?
    @NSManaged var sourceEntityID: String?
    /// 本事件撤销的是哪个历史事件。
    @NSManaged var revertsEventID: UUID?
    @NSManaged var createdAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var kind: HoloMatterEventKind {
        get { decodeMatterEnum(HoloMatterEventKind.self, from: kindRaw, fallback: .activated) }
        set { kindRaw = newValue.rawValue }
    }

    var actor: HoloMatterActor {
        get { decodeMatterEnum(HoloMatterActor.self, from: actorRaw, fallback: .system) }
        set { actorRaw = newValue.rawValue }
    }

    /// 最小变更载荷（松散 JSON，展示用）。
    var payload: [String: String] {
        get {
            guard let payloadJSON, let data = payloadJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return dict
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                payloadJSON = nil
                return
            }
            payloadJSON = String(data: data, encoding: .utf8)
        }
    }
}
