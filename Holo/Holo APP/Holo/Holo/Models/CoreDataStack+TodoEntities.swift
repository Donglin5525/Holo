//
//  CoreDataStack+TodoEntities.swift
//  Holo
//
//  待办相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Todo Entities

    /// 创建待办相关实体（TodoFolder, TodoList, TodoTask, TodoTag, CheckItem, RepeatRule, TaskAttachment）
    nonisolated func createTodoEntities() -> [NSEntityDescription] {
        // MARK: - TodoFolder Entity
        // 待办文件夹实体，顶层容器
        let todoFolderEntity = NSEntityDescription()
        todoFolderEntity.name = "TodoFolder"
        todoFolderEntity.managedObjectClassName = "TodoFolder"

        var todoFolderAttributes: [NSAttributeDescription] = []

        let folderId = NSAttributeDescription()
        folderId.name = "id"
        folderId.attributeType = .UUIDAttributeType
        folderId.isOptional = false
        folderId.isIndexed = true
        todoFolderAttributes.append(folderId)

        let folderName = NSAttributeDescription()
        folderName.name = "name"
        folderName.attributeType = .stringAttributeType
        folderName.isOptional = false
        todoFolderAttributes.append(folderName)

        let folderOrder = NSAttributeDescription()
        folderOrder.name = "sortOrder"
        folderOrder.attributeType = .integer16AttributeType
        folderOrder.isOptional = false
        folderOrder.defaultValue = 0
        todoFolderAttributes.append(folderOrder)

        let folderIsExpanded = NSAttributeDescription()
        folderIsExpanded.name = "isExpanded"
        folderIsExpanded.attributeType = .booleanAttributeType
        folderIsExpanded.isOptional = false
        folderIsExpanded.defaultValue = true
        todoFolderAttributes.append(folderIsExpanded)

        let folderCreatedAt = NSAttributeDescription()
        folderCreatedAt.name = "createdAt"
        folderCreatedAt.attributeType = .dateAttributeType
        folderCreatedAt.isOptional = false
        todoFolderAttributes.append(folderCreatedAt)

        let folderUpdatedAt = NSAttributeDescription()
        folderUpdatedAt.name = "updatedAt"
        folderUpdatedAt.attributeType = .dateAttributeType
        folderUpdatedAt.isOptional = false
        todoFolderAttributes.append(folderUpdatedAt)

        // MARK: - TodoList Entity
        // 待办清单实体，文件夹下的具体列表
        let todoListEntity = NSEntityDescription()
        todoListEntity.name = "TodoList"
        todoListEntity.managedObjectClassName = "TodoList"

        var todoListAttributes: [NSAttributeDescription] = []

        let listId = NSAttributeDescription()
        listId.name = "id"
        listId.attributeType = .UUIDAttributeType
        listId.isOptional = false
        listId.isIndexed = true
        todoListAttributes.append(listId)

        let listName = NSAttributeDescription()
        listName.name = "name"
        listName.attributeType = .stringAttributeType
        listName.isOptional = false
        todoListAttributes.append(listName)

        let listOrder = NSAttributeDescription()
        listOrder.name = "sortOrder"
        listOrder.attributeType = .integer16AttributeType
        listOrder.isOptional = false
        listOrder.defaultValue = 0
        todoListAttributes.append(listOrder)

        let listColor = NSAttributeDescription()
        listColor.name = "color"
        listColor.attributeType = .stringAttributeType
        listColor.isOptional = true
        todoListAttributes.append(listColor)

        let listIsArchived = NSAttributeDescription()
        listIsArchived.name = "archived"
        listIsArchived.attributeType = .booleanAttributeType
        listIsArchived.isOptional = false
        listIsArchived.defaultValue = false
        todoListAttributes.append(listIsArchived)

        let listCreatedAt = NSAttributeDescription()
        listCreatedAt.name = "createdAt"
        listCreatedAt.attributeType = .dateAttributeType
        listCreatedAt.isOptional = false
        todoListAttributes.append(listCreatedAt)

        let listUpdatedAt = NSAttributeDescription()
        listUpdatedAt.name = "updatedAt"
        listUpdatedAt.attributeType = .dateAttributeType
        listUpdatedAt.isOptional = false
        todoListAttributes.append(listUpdatedAt)

        // MARK: - TodoTask Entity
        // 待办任务实体
        let todoTaskEntity = NSEntityDescription()
        todoTaskEntity.name = "TodoTask"
        todoTaskEntity.managedObjectClassName = "TodoTask"

        var todoTaskAttributes: [NSAttributeDescription] = []

        let taskId = NSAttributeDescription()
        taskId.name = "id"
        taskId.attributeType = .UUIDAttributeType
        taskId.isOptional = false
        taskId.isIndexed = true
        todoTaskAttributes.append(taskId)

        let taskTitle = NSAttributeDescription()
        taskTitle.name = "title"
        taskTitle.attributeType = .stringAttributeType
        taskTitle.isOptional = false
        todoTaskAttributes.append(taskTitle)

        let taskDescription = NSAttributeDescription()
        taskDescription.name = "desc"
        taskDescription.attributeType = .stringAttributeType
        taskDescription.isOptional = true
        todoTaskAttributes.append(taskDescription)

        let taskStatus = NSAttributeDescription()
        taskStatus.name = "status"
        taskStatus.attributeType = .stringAttributeType
        taskStatus.isOptional = false
        taskStatus.defaultValue = "todo"
        taskStatus.isIndexed = true
        todoTaskAttributes.append(taskStatus)

        let taskPriority = NSAttributeDescription()
        taskPriority.name = "priority"
        taskPriority.attributeType = .integer16AttributeType
        taskPriority.isOptional = false
        taskPriority.defaultValue = 1
        taskPriority.isIndexed = true
        todoTaskAttributes.append(taskPriority)

        let taskDueDate = NSAttributeDescription()
        taskDueDate.name = "dueDate"
        taskDueDate.attributeType = .dateAttributeType
        taskDueDate.isOptional = true
        taskDueDate.isIndexed = true
        todoTaskAttributes.append(taskDueDate)

        let taskIsAllDay = NSAttributeDescription()
        taskIsAllDay.name = "isAllDay"
        taskIsAllDay.attributeType = .booleanAttributeType
        taskIsAllDay.isOptional = false
        taskIsAllDay.defaultValue = false
        todoTaskAttributes.append(taskIsAllDay)

        let taskIsCompleted = NSAttributeDescription()
        taskIsCompleted.name = "completed"
        taskIsCompleted.attributeType = .booleanAttributeType
        taskIsCompleted.isOptional = false
        taskIsCompleted.defaultValue = false
        taskIsCompleted.isIndexed = true
        todoTaskAttributes.append(taskIsCompleted)

        let taskCompletedAt = NSAttributeDescription()
        taskCompletedAt.name = "completedAt"
        taskCompletedAt.attributeType = .dateAttributeType
        taskCompletedAt.isOptional = true
        todoTaskAttributes.append(taskCompletedAt)

        let taskIsArchived = NSAttributeDescription()
        taskIsArchived.name = "archived"
        taskIsArchived.attributeType = .booleanAttributeType
        taskIsArchived.isOptional = false
        taskIsArchived.defaultValue = false
        taskIsArchived.isIndexed = true
        todoTaskAttributes.append(taskIsArchived)

        let taskDeletedFlag = NSAttributeDescription()
        taskDeletedFlag.name = "deletedFlag"
        taskDeletedFlag.attributeType = .booleanAttributeType
        taskDeletedFlag.isOptional = false
        taskDeletedFlag.defaultValue = false
        taskDeletedFlag.isIndexed = true
        todoTaskAttributes.append(taskDeletedFlag)

        let taskDeletedAt = NSAttributeDescription()
        taskDeletedAt.name = "deletedAt"
        taskDeletedAt.attributeType = .dateAttributeType
        taskDeletedAt.isOptional = true
        todoTaskAttributes.append(taskDeletedAt)

        let taskCreatedAt = NSAttributeDescription()
        taskCreatedAt.name = "createdAt"
        taskCreatedAt.attributeType = .dateAttributeType
        taskCreatedAt.isOptional = false
        todoTaskAttributes.append(taskCreatedAt)

        let taskUpdatedAt = NSAttributeDescription()
        taskUpdatedAt.name = "updatedAt"
        taskUpdatedAt.attributeType = .dateAttributeType
        taskUpdatedAt.isOptional = false
        todoTaskAttributes.append(taskUpdatedAt)

        // 提醒相关属性
        let taskReminders = NSAttributeDescription()
        taskReminders.name = "reminders"
        taskReminders.attributeType = .transformableAttributeType
        taskReminders.isOptional = true
        taskReminders.valueTransformerName = "NSSecureUnarchiveFromData"
        todoTaskAttributes.append(taskReminders)

        let taskHasDailyReminder = NSAttributeDescription()
        taskHasDailyReminder.name = "hasDailyReminder"
        taskHasDailyReminder.attributeType = .booleanAttributeType
        taskHasDailyReminder.isOptional = false
        taskHasDailyReminder.defaultValue = false
        todoTaskAttributes.append(taskHasDailyReminder)

        let taskSmartReminderEnabled = NSAttributeDescription()
        taskSmartReminderEnabled.name = "smartReminderEnabled"
        taskSmartReminderEnabled.attributeType = .booleanAttributeType
        taskSmartReminderEnabled.isOptional = false
        taskSmartReminderEnabled.defaultValue = false
        todoTaskAttributes.append(taskSmartReminderEnabled)

        let taskSmartReminderSchedule = NSAttributeDescription()
        taskSmartReminderSchedule.name = "smartReminderSchedule"
        taskSmartReminderSchedule.attributeType = .transformableAttributeType
        taskSmartReminderSchedule.isOptional = true
        taskSmartReminderSchedule.valueTransformerName = "NSSecureUnarchiveFromData"
        todoTaskAttributes.append(taskSmartReminderSchedule)

        // 看板相关属性
        let taskPlannedDate = NSAttributeDescription()
        taskPlannedDate.name = "plannedDate"
        taskPlannedDate.attributeType = .dateAttributeType
        taskPlannedDate.isOptional = true
        taskPlannedDate.isIndexed = true
        todoTaskAttributes.append(taskPlannedDate)

        let taskIsDailyRitual = NSAttributeDescription()
        taskIsDailyRitual.name = "isDailyRitual"
        taskIsDailyRitual.attributeType = .booleanAttributeType
        taskIsDailyRitual.isOptional = false
        taskIsDailyRitual.defaultValue = false
        todoTaskAttributes.append(taskIsDailyRitual)

        // MARK: - TodoTag Entity
        // 待办标签实体
        let todoTagEntity = NSEntityDescription()
        todoTagEntity.name = "TodoTag"
        todoTagEntity.managedObjectClassName = "TodoTag"

        var todoTagAttributes: [NSAttributeDescription] = []

        let tagId = NSAttributeDescription()
        tagId.name = "id"
        tagId.attributeType = .UUIDAttributeType
        tagId.isOptional = false
        tagId.isIndexed = true
        todoTagAttributes.append(tagId)

        let tagName = NSAttributeDescription()
        tagName.name = "name"
        tagName.attributeType = .stringAttributeType
        tagName.isOptional = false
        todoTagAttributes.append(tagName)

        let tagColor = NSAttributeDescription()
        tagColor.name = "color"
        tagColor.attributeType = .stringAttributeType
        tagColor.isOptional = false
        todoTagAttributes.append(tagColor)

        let tagDeletedFlag = NSAttributeDescription()
        tagDeletedFlag.name = "deletedFlag"
        tagDeletedFlag.attributeType = .booleanAttributeType
        tagDeletedFlag.isOptional = false
        tagDeletedFlag.defaultValue = false
        todoTagAttributes.append(tagDeletedFlag)

        let tagCreatedAt = NSAttributeDescription()
        tagCreatedAt.name = "createdAt"
        tagCreatedAt.attributeType = .dateAttributeType
        tagCreatedAt.isOptional = false
        todoTagAttributes.append(tagCreatedAt)

        // MARK: - CheckItem Entity
        // 检查项实体（任务子步骤）
        let checkItemEntity = NSEntityDescription()
        checkItemEntity.name = "CheckItem"
        checkItemEntity.managedObjectClassName = "CheckItem"

        var checkItemAttributes: [NSAttributeDescription] = []

        let checkItemId = NSAttributeDescription()
        checkItemId.name = "id"
        checkItemId.attributeType = .UUIDAttributeType
        checkItemId.isOptional = false
        checkItemId.isIndexed = true
        checkItemAttributes.append(checkItemId)

        let checkItemTitle = NSAttributeDescription()
        checkItemTitle.name = "title"
        checkItemTitle.attributeType = .stringAttributeType
        checkItemTitle.isOptional = false
        checkItemAttributes.append(checkItemTitle)

        let checkItemIsChecked = NSAttributeDescription()
        checkItemIsChecked.name = "isChecked"
        checkItemIsChecked.attributeType = .booleanAttributeType
        checkItemIsChecked.isOptional = false
        checkItemIsChecked.defaultValue = false
        checkItemAttributes.append(checkItemIsChecked)

        let checkItemOrder = NSAttributeDescription()
        checkItemOrder.name = "order"
        checkItemOrder.attributeType = .integer16AttributeType
        checkItemOrder.isOptional = false
        checkItemOrder.defaultValue = 0
        checkItemAttributes.append(checkItemOrder)

        let checkItemCreatedAt = NSAttributeDescription()
        checkItemCreatedAt.name = "createdAt"
        checkItemCreatedAt.attributeType = .dateAttributeType
        checkItemCreatedAt.isOptional = false
        checkItemAttributes.append(checkItemCreatedAt)

        // MARK: - RepeatRule Entity
        // 重复规则实体
        let repeatRuleEntity = NSEntityDescription()
        repeatRuleEntity.name = "RepeatRule"
        repeatRuleEntity.managedObjectClassName = "RepeatRule"

        var repeatRuleAttributes: [NSAttributeDescription] = []

        let ruleId = NSAttributeDescription()
        ruleId.name = "id"
        ruleId.attributeType = .UUIDAttributeType
        ruleId.isOptional = false
        ruleId.isIndexed = true
        repeatRuleAttributes.append(ruleId)

        let ruleType = NSAttributeDescription()
        ruleType.name = "type"
        ruleType.attributeType = .stringAttributeType
        ruleType.isOptional = false
        repeatRuleAttributes.append(ruleType)

        let ruleWeekdays = NSAttributeDescription()
        ruleWeekdays.name = "weekdays"
        ruleWeekdays.attributeType = .stringAttributeType
        ruleWeekdays.isOptional = true
        repeatRuleAttributes.append(ruleWeekdays)

        let ruleMonthDay = NSAttributeDescription()
        ruleMonthDay.name = "monthDay"
        ruleMonthDay.attributeType = .integer16AttributeType
        ruleMonthDay.isOptional = true
        repeatRuleAttributes.append(ruleMonthDay)

        let ruleMonthWeekOrdinal = NSAttributeDescription()
        ruleMonthWeekOrdinal.name = "monthWeekOrdinal"
        ruleMonthWeekOrdinal.attributeType = .integer16AttributeType
        ruleMonthWeekOrdinal.isOptional = true
        repeatRuleAttributes.append(ruleMonthWeekOrdinal)

        let ruleMonthWeekday = NSAttributeDescription()
        ruleMonthWeekday.name = "monthWeekday"
        ruleMonthWeekday.attributeType = .stringAttributeType
        ruleMonthWeekday.isOptional = true
        repeatRuleAttributes.append(ruleMonthWeekday)

        let ruleUntilCount = NSAttributeDescription()
        ruleUntilCount.name = "untilCount"
        ruleUntilCount.attributeType = .integer16AttributeType
        ruleUntilCount.isOptional = true
        repeatRuleAttributes.append(ruleUntilCount)

        let ruleUntilDate = NSAttributeDescription()
        ruleUntilDate.name = "untilDate"
        ruleUntilDate.attributeType = .dateAttributeType
        ruleUntilDate.isOptional = true
        repeatRuleAttributes.append(ruleUntilDate)

        let ruleSkipHolidays = NSAttributeDescription()
        ruleSkipHolidays.name = "skipHolidays"
        ruleSkipHolidays.attributeType = .booleanAttributeType
        ruleSkipHolidays.isOptional = false
        ruleSkipHolidays.defaultValue = false
        repeatRuleAttributes.append(ruleSkipHolidays)

        let ruleSkipWeekends = NSAttributeDescription()
        ruleSkipWeekends.name = "skipWeekends"
        ruleSkipWeekends.attributeType = .booleanAttributeType
        ruleSkipWeekends.isOptional = false
        ruleSkipWeekends.defaultValue = false
        repeatRuleAttributes.append(ruleSkipWeekends)

        let ruleCreatedAt = NSAttributeDescription()
        ruleCreatedAt.name = "createdAt"
        ruleCreatedAt.attributeType = .dateAttributeType
        ruleCreatedAt.isOptional = false
        repeatRuleAttributes.append(ruleCreatedAt)

        // MARK: - TaskAttachment Entity
        // 任务附件实体（图片文件引用）
        let taskAttachmentEntity = NSEntityDescription()
        taskAttachmentEntity.name = "TaskAttachment"
        taskAttachmentEntity.managedObjectClassName = "TaskAttachment"

        var taskAttachmentAttributes: [NSAttributeDescription] = []

        let attachmentId = NSAttributeDescription()
        attachmentId.name = "id"
        attachmentId.attributeType = .UUIDAttributeType
        attachmentId.isOptional = false
        attachmentId.isIndexed = true
        taskAttachmentAttributes.append(attachmentId)

        let attachmentFileName = NSAttributeDescription()
        attachmentFileName.name = "fileName"
        attachmentFileName.attributeType = .stringAttributeType
        attachmentFileName.isOptional = false
        taskAttachmentAttributes.append(attachmentFileName)

        let attachmentThumbnailFileName = NSAttributeDescription()
        attachmentThumbnailFileName.name = "thumbnailFileName"
        attachmentThumbnailFileName.attributeType = .stringAttributeType
        attachmentThumbnailFileName.isOptional = false
        taskAttachmentAttributes.append(attachmentThumbnailFileName)

        let attachmentSortOrder = NSAttributeDescription()
        attachmentSortOrder.name = "sortOrder"
        attachmentSortOrder.attributeType = .integer16AttributeType
        attachmentSortOrder.isOptional = false
        attachmentSortOrder.defaultValue = 0
        taskAttachmentAttributes.append(attachmentSortOrder)

        let attachmentSourceType = NSAttributeDescription()
        attachmentSourceType.name = "sourceType"
        attachmentSourceType.attributeType = .stringAttributeType
        attachmentSourceType.isOptional = false
        attachmentSourceType.defaultValue = "photoLibrary"
        taskAttachmentAttributes.append(attachmentSourceType)

        let attachmentCreatedAt = NSAttributeDescription()
        attachmentCreatedAt.name = "createdAt"
        attachmentCreatedAt.attributeType = .dateAttributeType
        attachmentCreatedAt.isOptional = false
        taskAttachmentAttributes.append(attachmentCreatedAt)

        // MARK: - Todo Entity Relationships

        // TodoFolder ↔ TodoList 关系
        let folderListsRelation = NSRelationshipDescription()
        folderListsRelation.name = "lists"
        folderListsRelation.destinationEntity = todoListEntity
        folderListsRelation.minCount = 0
        folderListsRelation.maxCount = 0
        folderListsRelation.deleteRule = .cascadeDeleteRule
        folderListsRelation.isOptional = true

        let listFolderRelation = NSRelationshipDescription()
        listFolderRelation.name = "folder"
        listFolderRelation.destinationEntity = todoFolderEntity
        listFolderRelation.minCount = 0
        listFolderRelation.maxCount = 1
        listFolderRelation.deleteRule = .nullifyDeleteRule
        listFolderRelation.isOptional = true

        folderListsRelation.inverseRelationship = listFolderRelation
        listFolderRelation.inverseRelationship = folderListsRelation

        // TodoList ↔ TodoTask 关系
        let listTasksRelation = NSRelationshipDescription()
        listTasksRelation.name = "tasks"
        listTasksRelation.destinationEntity = todoTaskEntity
        listTasksRelation.minCount = 0
        listTasksRelation.maxCount = 0
        listTasksRelation.deleteRule = .cascadeDeleteRule
        listTasksRelation.isOptional = true

        let taskListRelation = NSRelationshipDescription()
        taskListRelation.name = "list"
        taskListRelation.destinationEntity = todoListEntity
        taskListRelation.minCount = 0
        taskListRelation.maxCount = 1
        taskListRelation.deleteRule = .nullifyDeleteRule
        taskListRelation.isOptional = true

        listTasksRelation.inverseRelationship = taskListRelation
        taskListRelation.inverseRelationship = listTasksRelation

        // TodoTask ↔ TodoTag 关系（多对多）
        let taskTagsRelation = NSRelationshipDescription()
        taskTagsRelation.name = "tags"
        taskTagsRelation.destinationEntity = todoTagEntity
        taskTagsRelation.minCount = 0
        taskTagsRelation.maxCount = 0
        taskTagsRelation.deleteRule = .nullifyDeleteRule
        taskTagsRelation.isOptional = true

        let tagTasksRelation = NSRelationshipDescription()
        tagTasksRelation.name = "tasks"
        tagTasksRelation.destinationEntity = todoTaskEntity
        tagTasksRelation.minCount = 0
        tagTasksRelation.maxCount = 0
        tagTasksRelation.deleteRule = .nullifyDeleteRule
        tagTasksRelation.isOptional = true

        taskTagsRelation.inverseRelationship = tagTasksRelation
        tagTasksRelation.inverseRelationship = taskTagsRelation

        // TodoTask ↔ CheckItem 关系（一对多）
        let taskCheckItemsRelation = NSRelationshipDescription()
        taskCheckItemsRelation.name = "checkItems"
        taskCheckItemsRelation.destinationEntity = checkItemEntity
        taskCheckItemsRelation.minCount = 0
        taskCheckItemsRelation.maxCount = 0
        taskCheckItemsRelation.deleteRule = .cascadeDeleteRule
        taskCheckItemsRelation.isOptional = true

        let checkItemTaskRelation = NSRelationshipDescription()
        checkItemTaskRelation.name = "task"
        checkItemTaskRelation.destinationEntity = todoTaskEntity
        checkItemTaskRelation.minCount = 1
        checkItemTaskRelation.maxCount = 1
        checkItemTaskRelation.deleteRule = .cascadeDeleteRule
        checkItemTaskRelation.isOptional = false

        taskCheckItemsRelation.inverseRelationship = checkItemTaskRelation
        checkItemTaskRelation.inverseRelationship = taskCheckItemsRelation

        // TodoTask ↔ RepeatRule 关系（一对一）
        let taskRepeatRuleRelation = NSRelationshipDescription()
        taskRepeatRuleRelation.name = "repeatRule"
        taskRepeatRuleRelation.destinationEntity = repeatRuleEntity
        taskRepeatRuleRelation.minCount = 0
        taskRepeatRuleRelation.maxCount = 1
        taskRepeatRuleRelation.deleteRule = .cascadeDeleteRule
        taskRepeatRuleRelation.isOptional = true

        let ruleTaskRelation = NSRelationshipDescription()
        ruleTaskRelation.name = "task"
        ruleTaskRelation.destinationEntity = todoTaskEntity
        ruleTaskRelation.minCount = 0
        ruleTaskRelation.maxCount = 1
        ruleTaskRelation.deleteRule = .nullifyDeleteRule
        ruleTaskRelation.isOptional = true

        taskRepeatRuleRelation.inverseRelationship = ruleTaskRelation
        ruleTaskRelation.inverseRelationship = taskRepeatRuleRelation

        // TodoTask ↔ TaskAttachment 关系（一对多）
        let taskAttachmentsRelation = NSRelationshipDescription()
        taskAttachmentsRelation.name = "attachments"
        taskAttachmentsRelation.destinationEntity = taskAttachmentEntity
        taskAttachmentsRelation.minCount = 0
        taskAttachmentsRelation.maxCount = 0
        taskAttachmentsRelation.deleteRule = .cascadeDeleteRule
        taskAttachmentsRelation.isOptional = true

        let attachmentTaskRelation = NSRelationshipDescription()
        attachmentTaskRelation.name = "task"
        attachmentTaskRelation.destinationEntity = todoTaskEntity
        attachmentTaskRelation.minCount = 1
        attachmentTaskRelation.maxCount = 1
        attachmentTaskRelation.deleteRule = .nullifyDeleteRule
        attachmentTaskRelation.isOptional = false

        taskAttachmentsRelation.inverseRelationship = attachmentTaskRelation
        attachmentTaskRelation.inverseRelationship = taskAttachmentsRelation

        // 将关系添加到实体
        todoFolderEntity.properties = todoFolderAttributes + [folderListsRelation]
        todoListEntity.properties = todoListAttributes + [listFolderRelation, listTasksRelation]
        todoTaskEntity.properties = todoTaskAttributes + [taskListRelation, taskTagsRelation, taskCheckItemsRelation, taskAttachmentsRelation, taskRepeatRuleRelation]
        todoTagEntity.properties = todoTagAttributes + [tagTasksRelation]
        checkItemEntity.properties = checkItemAttributes + [checkItemTaskRelation]
        repeatRuleEntity.properties = repeatRuleAttributes + [ruleTaskRelation]
        taskAttachmentEntity.properties = taskAttachmentAttributes + [attachmentTaskRelation]

        return [todoFolderEntity, todoListEntity, todoTaskEntity, todoTagEntity, checkItemEntity, repeatRuleEntity, taskAttachmentEntity]
    }

}
