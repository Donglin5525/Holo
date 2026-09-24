//
//  HoloTaskExecutionStep+CoreDataClass.swift
//  Holo
//
//  执行步骤：动作内容与执行事实（2026-09-25 实施规格 §7.2-C）
//  - action：pending/waiting/done；取消由新版本移除活动引用表达，不伪装成 done
//  - sourceCheckItemReference：引用原清单项，标题/完成状态读 CheckItem，不维护第二份布尔值
//  - group：纯派生状态，不可写 done
//

import Foundation
import CoreData

/// 步骤种类
nonisolated enum HoloTaskExecutionStepKind: String {
    case action
    case sourceCheckItemReference
    case group
}

/// 步骤执行状态（action 专用；group 状态纯派生）
nonisolated enum HoloTaskExecutionStepState: String {
    case pending
    case waiting
    case done
}

@objc(HoloTaskExecutionStep)
final class HoloTaskExecutionStep: NSManagedObject, Identifiable {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<HoloTaskExecutionStep> {
        NSFetchRequest<HoloTaskExecutionStep>(entityName: "HoloTaskExecutionStep")
    }

    @NSManaged var id: UUID
    @NSManaged var taskID: UUID
    @NSManaged var originRevisionID: UUID
    @NSManaged var kindRaw: String
    @NSManaged var actionText: String?
    @NSManaged var doneWhen: String?
    @NSManaged var sourceCheckItemID: UUID?
    @NSManaged var stateRaw: String
    @NSManaged var stateVersion: Int64
    @NSManaged var stateChangedAt: Date?
    @NSManaged var completedAt: Date?
    @NSManaged var waitReason: String?
    @NSManaged var reviewAfter: Date?
    @NSManaged var userResumeNote: String?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 类型化访问

    var kind: HoloTaskExecutionStepKind {
        get { HoloTaskExecutionStepKind(rawValue: kindRaw) ?? .action }
        set { kindRaw = newValue.rawValue }
    }

    /// 执行状态（group 引用节点返回 pending 占位，真实状态由 Policy 派生）
    var state: HoloTaskExecutionStepState {
        get { HoloTaskExecutionStepState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}
