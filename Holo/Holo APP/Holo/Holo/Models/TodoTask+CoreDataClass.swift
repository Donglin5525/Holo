//
//  TodoTask+CoreDataClass.swift
//  Holo
//
//  待办任务实体类
//

import Foundation
import CoreData

@objc(TodoTask)
class TodoTask: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TodoTask> {
        NSFetchRequest<TodoTask>(entityName: "TodoTask")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var desc: String?
    @NSManaged var status: String
    @NSManaged var priority: Int16
    @NSManaged var dueDate: Date?
    @NSManaged var isAllDay: Bool
    /// 计划时间段开始（时间块）：与 plannedEnd 成对出现，两者同时有值或同时为空；不允许跨天
    @NSManaged var plannedStart: Date?
    /// 计划时间段结束
    @NSManaged var plannedEnd: Date?
    @NSManaged var completed: Bool
    @NSManaged var completedAt: Date?
    @NSManaged var archived: Bool
    @NSManaged var deletedFlag: Bool
    /// AI 确认流程的来源消息 ID（对账用，与 Transaction.aiSourceMessageId 同构）
    @NSManaged var aiSourceMessageId: String?
    /// AI 确认流程的来源 execution item ID
    @NSManaged var aiSourceItemId: String?
    @NSManaged var deletedAt: Date?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    // MARK: - Reminder Properties

    @NSManaged var reminders: Data?
    @NSManaged var hasDailyReminder: Bool
    @NSManaged var smartReminderEnabled: Bool
    @NSManaged var smartReminderSchedule: Data?

    // MARK: - Kanban Properties

    @NSManaged var isDailyRitual: Bool

    /// 累计延期次数（每次延期 +1，撤回时回滚；卡片以此显示「已延期 N 次」）
    @NSManaged var postponedCount: Int16

    // MARK: - Relationships

    @NSManaged var list: TodoList?
    @NSManaged var tags: NSSet?
    @NSManaged var checkItems: NSSet?
    @NSManaged var attachments: NSSet?
    @NSManaged var repeatRule: RepeatRule?

    // MARK: - Goal Relationship

    @NSManaged var goal: Goal?

    // MARK: - Source Thought Relationship（想法转任务后的来源关联）

    @NSManaged var sourceThought: Thought?

    // MARK: - Source Anniversary（纪念日自动生成任务的来源关联）

    /// 标记本任务由某个纪念日自动生成。用 UUID 而非 CoreData 关系，
    /// 解耦纪念日与任务的生命周期（删除纪念日时不强删任务）。
    @NSManaged var sourceAnniversaryId: UUID?

    // MARK: - Source Text Snippet（想法转任务的来源文字快照）

    /// 选中文字转任务时，被选中的文字原文快照。用于正文 ✅ 标记反向定位。
    /// nil = 非选中转化（整篇转化或纪念日生成等）。
    @NSManaged var sourceTextSnippet: String?
}

// MARK: - Core Data Generated Accessors

extension TodoTask {
    @objc(addTagsObject:)
    @NSManaged func addToTags(_ value: TodoTag)

    @objc(removeTagsObject:)
    @NSManaged func removeFromTags(_ value: TodoTag)

    @objc(addTags:)
    @NSManaged func addToTags(_ values: Set<TodoTag>)

    @objc(removeTags:)
    @NSManaged func removeFromTags(_ values: Set<TodoTag>)

    @objc(addCheckItemsObject:)
    @NSManaged func addCheckItems(_ value: CheckItem)

    @objc(removeCheckItemsObject:)
    @NSManaged func removeCheckItems(_ value: CheckItem)

    @objc(addCheckItems:)
    @NSManaged func addCheckItems(_ values: Set<CheckItem>)

    @objc(removeCheckItems:)
    @NSManaged func removeCheckItems(_ values: Set<CheckItem>)

    @objc(addAttachmentsObject:)
    @NSManaged func addAttachments(_ value: TaskAttachment)

    @objc(removeAttachmentsObject:)
    @NSManaged func removeFromAttachments(_ value: TaskAttachment)

    @objc(addAttachments:)
    @NSManaged func addAttachments(_ values: Set<TaskAttachment>)

    @objc(removeAttachments:)
    @NSManaged func removeFromAttachments(_ values: Set<TaskAttachment>)
}
