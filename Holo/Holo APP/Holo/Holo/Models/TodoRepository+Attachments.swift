//
//  TodoRepository+Attachments.swift
//  Holo
//
//  任务附件相关方法扩展
//

import CoreData
import UIKit
import os.log

extension TodoRepository {

    private static let attachmentLogger = Logger(subsystem: "com.holo.app", category: "TodoRepository+Attachments")

    // MARK: - 添加附件

    /// 为任务添加图片附件
    @discardableResult
    func addAttachment(image: UIImage, to task: TodoTask, sourceType: String = "photoLibrary") async throws -> TaskAttachment {
        let attachmentId = UUID()
        let taskId = task.id

        guard let result = await AttachmentFileManager.saveImageInBackground(image, taskId: taskId, attachmentId: attachmentId) else {
            Self.attachmentLogger.error("保存附件图片失败, taskId: \(taskId.uuidString)")
            throw AttachmentError.saveFailed
        }

        let order = Int16(task.sortedAttachments.count)
        let attachment = TaskAttachment.create(
            in: context,
            fileName: result.fileName,
            thumbnailFileName: result.thumbnailFileName,
            task: task,
            order: order,
            sourceType: sourceType
        )

        task.updatedAt = Date()
        try context.save()
        loadActiveTasks()
        notifyDataChange(taskId: task.id)
        return attachment
    }

    /// 为任务添加相册图片附件。视图层只传原始 Data，解码/压缩/写文件全部后台执行。
    @discardableResult
    func addAttachment(imageData: Data, to task: TodoTask, sourceType: String = "photoLibrary") async throws -> TaskAttachment {
        let attachmentId = UUID()
        let taskId = task.id

        guard let result = await AttachmentFileManager.saveImageDataInBackground(imageData, taskId: taskId, attachmentId: attachmentId) else {
            Self.attachmentLogger.error("保存附件图片失败, taskId: \(taskId.uuidString)")
            throw AttachmentError.saveFailed
        }

        let order = Int16(task.sortedAttachments.count)
        let attachment = TaskAttachment.create(
            in: context,
            fileName: result.fileName,
            thumbnailFileName: result.thumbnailFileName,
            task: task,
            order: order,
            sourceType: sourceType
        )

        task.updatedAt = Date()
        try context.save()
        loadActiveTasks()
        notifyDataChange(taskId: task.id)
        return attachment
    }

    // MARK: - 删除附件

    /// 删除单个附件
    func deleteAttachment(_ attachment: TaskAttachment) throws {
        try deleteAttachment(with: attachment.objectID)
    }

    /// 通过稳定 objectID 删除附件，避免视图层持有已删除的 Core Data 对象。
    func deleteAttachment(with attachmentID: NSManagedObjectID) throws {
        guard let attachment = try context.existingObject(with: attachmentID) as? TaskAttachment,
              let task = attachment.task else { return }
        let taskId = task.id
        let fileName = attachment.fileName
        let thumbnailFileName = attachment.thumbnailFileName

        context.delete(attachment)
        reorderRemainingAttachments(in: task)
        task.updatedAt = Date()
        try context.save()
        AttachmentFileManager.deleteAttachmentFiles(
            fileName: fileName,
            thumbnailFileName: thumbnailFileName,
            taskId: taskId
        )
        loadActiveTasks()
        notifyDataChange(taskId: task.id)
    }

    /// 删除任务的所有附件（Core Data 级联删除前的文件清理）
    func deleteAllAttachmentFiles(for task: TodoTask) {
        AttachmentFileManager.deleteAllAttachments(for: task.id)
    }

    // MARK: - 排序

    /// 重新排列附件
    func reorderAttachments(_ attachments: [TaskAttachment]) throws {
        for (index, attachment) in attachments.enumerated() {
            attachment.sortOrder = Int16(index)
        }
        if let task = attachments.first?.task {
            task.updatedAt = Date()
        }
        try context.save()
        loadActiveTasks()
        notifyDataChange()
    }

    // MARK: - Private

    /// 删除附件后重新排序剩余附件
    private func reorderRemainingAttachments(in task: TodoTask) {
        let remaining = (task.attachments?.allObjects as? [TaskAttachment] ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.sortOrder < $1.sortOrder }
        for (index, attachment) in remaining.enumerated() {
            attachment.sortOrder = Int16(index)
        }
    }
}

// MARK: - Attachment Error

enum AttachmentError: LocalizedError {
    case saveFailed
    case tooManyAttachments

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "保存附件失败"
        case .tooManyAttachments:
            return "附件数量已达上限（最多 9 张）"
        }
    }
}
