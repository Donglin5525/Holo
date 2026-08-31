//
//  CalendarEventOriginResolver.swift
//  Holo
//
//  日历事件 → 原模块详情的跳转解析：经 originID 在后台 context 回查实体，
// 换成模块各自的 DeepLinkTarget 交调用方导航。「在 X 模块打开」按钮与想法
// 卡片直跳想法详情共用此处，保证两条入口的落点永远一致。
//

import Foundation
import CoreData

enum CalendarEventOriginResolver {

    /// 后台回查事件原实体并解析出跳转目标；实体不存在 / 已软删除 / 模块不识别时回传 nil。
    /// 结果统一回主线程，导航时机（立即 / dismiss 后下一轮）由调用方决定。
    static func resolve(_ event: CalendarEvent,
                        then completion: @escaping @MainActor (DeepLinkTarget?) -> Void) {
        let originID = event.originID
        let module = event.module
        let backgroundContext = CoreDataStack.shared.newBackgroundContext()

        Task.detached(priority: .userInitiated) {
            let target: DeepLinkTarget? = await backgroundContext.perform {
                guard let entity = try? backgroundContext.existingObject(with: originID) else {
                    return nil as DeepLinkTarget?
                }
                // 软删除的对象仍存在于库中，但原始记录对用户已不可见，视为已删除
                if (entity as? SoftDeletable)?.deletedAt != nil {
                    return nil as DeepLinkTarget?
                }
                switch module {
                case .finance:
                    guard let transaction = entity as? Transaction else { return nil }
                    return .transactionDetail(transactionId: transaction.id)
                case .habit:
                    guard let record = entity as? HabitRecord else { return nil }
                    return .habitDetail(habitId: record.habitId)
                case .todo:
                    guard let task = entity as? TodoTask else { return nil }
                    return .taskDetail(taskId: task.id)
                case .thought:
                    guard let thought = entity as? Thought else { return nil }
                    return .thoughtDetail(thoughtId: thought.id)
                default:
                    return nil
                }
            }

            await MainActor.run {
                completion(target)
            }
        }
    }
}
