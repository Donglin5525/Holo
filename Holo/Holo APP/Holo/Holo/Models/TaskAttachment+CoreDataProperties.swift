//
//  TaskAttachment+CoreDataProperties.swift
//  Holo
//
//  任务附件实体属性扩展
//

import Foundation
import CoreData

extension TaskAttachment {

    // MARK: - 创建方法

    @nonobjc public class func create(
        in context: NSManagedObjectContext,
        fileName: String,
        thumbnailFileName: String,
        task: TodoTask,
        order: Int16 = 0,
        sourceType: String = "photoLibrary"
    ) -> TaskAttachment {
        let attachment = TaskAttachment(context: context)
        attachment.id = UUID()
        attachment.fileName = fileName
        attachment.thumbnailFileName = thumbnailFileName
        attachment.task = task
        attachment.sortOrder = order
        attachment.sourceType = sourceType
        attachment.createdAt = Date()
        return attachment
    }
}
