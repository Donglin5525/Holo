//
//  ThoughtRepository+Attachments.swift
//  Holo
//
//  想法附件相关方法扩展
//

import CoreData
import UIKit
import os.log

extension ThoughtRepository {

    private static let thoughtAttachmentLogger = Logger(subsystem: "com.holo.app", category: "ThoughtRepository+Attachments")

    // MARK: - 添加附件

    /// 为想法添加图片附件。视图层只传原始 Data，解码/压缩全部后台执行，数据存入 CoreData。
    @discardableResult
    func addAttachment(imageData: Data, to thought: Thought, sourceType: String = "photoLibrary") async throws -> ThoughtAttachment {
        let attachmentId = UUID()

        guard let result = await AttachmentFileManager.processRawImageData(imageData, attachmentId: attachmentId) else {
            Self.thoughtAttachmentLogger.error("处理附件图片失败, thoughtId: \(thought.id.uuidString)")
            throw AttachmentError.saveFailed
        }

        let order = Int16(thought.sortedAttachments.count)
        let attachment = ThoughtAttachment.create(
            in: context,
            fileName: result.fileName,
            thumbnailFileName: result.thumbnailFileName,
            thought: thought,
            order: order,
            sourceType: sourceType,
            imageData: result.imageData,
            thumbnailData: result.thumbnailData
        )

        thought.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        return attachment
    }

    // MARK: - 删除附件

    /// 通过稳定 objectID 删除附件，避免视图层持有已删除的 Core Data 对象。
    func deleteAttachment(with attachmentID: NSManagedObjectID) throws {
        guard let attachment = try context.existingObject(with: attachmentID) as? ThoughtAttachment,
              let thought = attachment.thought else { return }
        let thoughtId = thought.id
        let fileName = attachment.fileName
        let thumbnailFileName = attachment.thumbnailFileName

        context.delete(attachment)
        reorderRemainingAttachments(in: thought)
        thought.updatedAt = Date()
        try context.save()

        AttachmentFileManager.deleteAttachmentFiles(
            fileName: fileName,
            thumbnailFileName: thumbnailFileName,
            taskId: thoughtId
        )
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
    }

    /// 删除想法的所有附件文件（Core Data 级联删除前的文件清理）
    func deleteAllAttachmentFiles(for thought: Thought) {
        AttachmentFileManager.deleteAllAttachments(for: thought.id)
    }

    // MARK: - 排序

    /// 重新排列附件
    func reorderAttachments(_ attachments: [ThoughtAttachment]) throws {
        for (index, attachment) in attachments.enumerated() {
            attachment.sortOrder = Int16(index)
        }
        if let thought = attachments.first?.thought {
            thought.updatedAt = Date()
        }
        try context.save()
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
    }

    // MARK: - Private

    /// 删除附件后重新排序剩余附件
    private func reorderRemainingAttachments(in thought: Thought) {
        let remaining = (thought.attachments?.allObjects as? [ThoughtAttachment] ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.sortOrder < $1.sortOrder }
        for (index, attachment) in remaining.enumerated() {
            attachment.sortOrder = Int16(index)
        }
    }
}
