//
//  ThoughtAttachment+CoreDataProperties.swift
//  Holo
//
//  想法附件实体属性扩展
//

import Foundation
import CoreData

extension ThoughtAttachment {

    // MARK: - 创建方法

    @nonobjc public class func create(
        in context: NSManagedObjectContext,
        fileName: String,
        thumbnailFileName: String,
        thought: Thought,
        order: Int16 = 0,
        sourceType: String = "photoLibrary",
        imageData: Data? = nil,
        thumbnailData: Data? = nil
    ) -> ThoughtAttachment {
        let attachment = ThoughtAttachment(context: context)
        attachment.id = UUID()
        attachment.fileName = fileName
        attachment.thumbnailFileName = thumbnailFileName
        attachment.imageData = imageData
        attachment.thumbnailData = thumbnailData
        attachment.thought = thought
        attachment.sortOrder = order
        attachment.sourceType = sourceType
        attachment.createdAt = Date()
        return attachment
    }
}
