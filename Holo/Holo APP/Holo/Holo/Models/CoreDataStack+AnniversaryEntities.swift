//
//  CoreDataStack+AnniversaryEntities.swift
//  Holo
//
//  纪念日相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Anniversary Entity

    /// 创建纪念日实体
    nonisolated func createAnniversaryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Anniversary"
        entity.managedObjectClassName = "Anniversary"

        var attributes: [NSAttributeDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        attributes.append(id)

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        title.isOptional = false
        title.defaultValue = ""
        attributes.append(title)

        let date = NSAttributeDescription()
        date.name = "date"
        date.attributeType = .dateAttributeType
        date.isOptional = false
        date.defaultValue = Date()
        attributes.append(date)

        let type = NSAttributeDescription()
        type.name = "type"
        type.attributeType = .stringAttributeType
        type.isOptional = false
        type.defaultValue = AnniversaryType.countdown.rawValue
        attributes.append(type)

        let icon = NSAttributeDescription()
        icon.name = "icon"
        icon.attributeType = .stringAttributeType
        icon.isOptional = false
        icon.defaultValue = AnniversaryType.countdown.defaultIcon
        attributes.append(icon)

        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = false
        color.defaultValue = AnniversaryType.countdown.defaultColor
        attributes.append(color)

        let note = NSAttributeDescription()
        note.name = "note"
        note.attributeType = .stringAttributeType
        note.isOptional = true
        attributes.append(note)

        let isPinned = NSAttributeDescription()
        isPinned.name = "isPinned"
        isPinned.attributeType = .booleanAttributeType
        isPinned.isOptional = false
        isPinned.defaultValue = false
        attributes.append(isPinned)

        let isArchived = NSAttributeDescription()
        isArchived.name = "isArchived"
        isArchived.attributeType = .booleanAttributeType
        isArchived.isOptional = false
        isArchived.defaultValue = false
        attributes.append(isArchived)

        let isSoftDeleted = NSAttributeDescription()
        isSoftDeleted.name = "isSoftDeleted"
        isSoftDeleted.attributeType = .booleanAttributeType
        isSoftDeleted.isOptional = false
        isSoftDeleted.defaultValue = false
        attributes.append(isSoftDeleted)

        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.defaultValue = 0
        attributes.append(sortOrder)

        // 重复与提醒
        let repeatYearly = NSAttributeDescription()
        repeatYearly.name = "repeatYearly"
        repeatYearly.attributeType = .booleanAttributeType
        repeatYearly.isOptional = false
        repeatYearly.defaultValue = false
        attributes.append(repeatYearly)

        let reminderEnabled = NSAttributeDescription()
        reminderEnabled.name = "reminderEnabled"
        reminderEnabled.attributeType = .booleanAttributeType
        reminderEnabled.isOptional = false
        reminderEnabled.defaultValue = false
        attributes.append(reminderEnabled)

        let reminderDaysBefore = NSAttributeDescription()
        reminderDaysBefore.name = "reminderDaysBefore"
        reminderDaysBefore.attributeType = .integer16AttributeType
        reminderDaysBefore.isOptional = false
        reminderDaysBefore.defaultValue = 0
        attributes.append(reminderDaysBefore)

        let generateTask = NSAttributeDescription()
        generateTask.name = "generateTask"
        generateTask.attributeType = .booleanAttributeType
        generateTask.isOptional = false
        generateTask.defaultValue = false
        attributes.append(generateTask)

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        createdAt.defaultValue = Date()
        attributes.append(createdAt)

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        updatedAt.defaultValue = Date()
        attributes.append(updatedAt)

        entity.properties = attributes
        CoreDataStack.applyIndexes(to: entity, on: ["id": id, "isSoftDeleted": isSoftDeleted, "isPinned": isPinned])
        return entity
    }
}
