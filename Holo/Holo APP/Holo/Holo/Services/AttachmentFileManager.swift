//
//  AttachmentFileManager.swift
//  Holo
//
//  任务附件文件管理服务
//  负责图片压缩、缩略图生成、文件读写
//

import UIKit
import os.log

enum AttachmentFileManager {

    struct SavedImageFiles: Sendable {
        let fileName: String
        let thumbnailFileName: String
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "AttachmentFileManager")

    // MARK: - 目录结构

    /// 附件根目录 Documents/Attachments/
    private static var attachmentsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Attachments", isDirectory: true)
    }

    /// 任务附件目录 Documents/Attachments/{taskId}/
    static func taskDirectory(taskId: UUID) -> URL {
        attachmentsRoot.appendingPathComponent(taskId.uuidString, isDirectory: true)
    }

    // MARK: - 保存图片

    /// 保存图片（压缩原图 + 生成缩略图），返回 (原图文件名, 缩略图文件名)
    static func saveImage(_ image: UIImage, taskId: UUID, attachmentId: UUID) -> (fileName: String, thumbnailFileName: String)? {
        let dir = taskDirectory(taskId: taskId)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("创建附件目录失败: \(error.localizedDescription)")
            return nil
        }

        guard let originalData = compressImage(image, maxDimension: 2048, quality: 0.8) else {
            logger.error("压缩原图失败")
            return nil
        }

        let fileName = "\(attachmentId.uuidString).jpeg"
        let originalURL = dir.appendingPathComponent(fileName)

        do {
            try originalData.write(to: originalURL)
        } catch {
            logger.error("写入原图失败: \(error.localizedDescription)")
            return nil
        }

        guard let thumbnailData = generateThumbnail(from: image, maxSize: 300) else {
            logger.error("生成缩略图失败")
            return nil
        }

        let thumbnailFileName = "\(attachmentId.uuidString)_thumb.jpeg"
        let thumbnailURL = dir.appendingPathComponent(thumbnailFileName)

        do {
            try thumbnailData.write(to: thumbnailURL)
        } catch {
            logger.error("写入缩略图失败: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: originalURL)
            return nil
        }

        return (fileName, thumbnailFileName)
    }

    /// 在后台队列保存图片，避免大图压缩和磁盘写入阻塞主线程。
    static func saveImageInBackground(_ image: UIImage, taskId: UUID, attachmentId: UUID) async -> SavedImageFiles? {
        await Task.detached(priority: .userInitiated) {
            guard let result = saveImage(image, taskId: taskId, attachmentId: attachmentId) else {
                return nil
            }
            return SavedImageFiles(fileName: result.fileName, thumbnailFileName: result.thumbnailFileName)
        }.value
    }

    /// 在后台队列解码并保存相册图片，避免 PhotosPicker 确认后主线程解码大图。
    static func saveImageDataInBackground(_ imageData: Data, taskId: UUID, attachmentId: UUID) async -> SavedImageFiles? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: imageData),
                  let result = saveImage(image, taskId: taskId, attachmentId: attachmentId) else {
                return nil
            }
            return SavedImageFiles(fileName: result.fileName, thumbnailFileName: result.thumbnailFileName)
        }.value
    }

    /// 生成用于界面预览的轻量图片，避免相机原图直接进入 SwiftUI 网格导致卡顿。
    static func previewImageInBackground(_ image: UIImage, maxDimension: CGFloat = 1024) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = compressImage(image, maxDimension: maxDimension, quality: 0.75) else {
                return nil
            }
            return UIImage(data: data)
        }.value
    }

    // MARK: - 加载图片

    /// 加载缩略图
    static func loadThumbnail(fileName: String, taskId: UUID) -> UIImage? {
        let url = taskDirectory(taskId: taskId).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 加载原图
    static func loadFullImage(fileName: String, taskId: UUID) -> UIImage? {
        let url = taskDirectory(taskId: taskId).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 删除文件

    /// 删除任务的所有附件文件（删除整个任务目录）
    static func deleteAllAttachments(for taskId: UUID) {
        let dir = taskDirectory(taskId: taskId)
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            logger.error("删除附件目录失败: \(error.localizedDescription)")
        }
    }

    /// 批量删除多个任务的附件
    static func deleteAttachmentDirectories(for taskIds: [UUID]) {
        for taskId in taskIds {
            deleteAllAttachments(for: taskId)
        }
    }

    /// 删除单个附件的文件
    static func deleteAttachmentFiles(fileName: String, thumbnailFileName: String, taskId: UUID) {
        let dir = taskDirectory(taskId: taskId)
        let fm = FileManager.default

        let originalURL = dir.appendingPathComponent(fileName)
        let thumbnailURL = dir.appendingPathComponent(thumbnailFileName)

        try? fm.removeItem(at: originalURL)
        try? fm.removeItem(at: thumbnailURL)

        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - 图片处理

    /// 压缩图片到指定尺寸和质量
    static func compressImage(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale: CGFloat
        if size.width > maxDimension || size.height > maxDimension {
            scale = min(maxDimension / size.width, maxDimension / size.height)
        } else {
            scale = 1.0
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        return rendered.jpegData(compressionQuality: quality)
    }

    /// 生成正方形缩略图（居中裁剪）
    static func generateThumbnail(from image: UIImage, maxSize: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let cropSide = min(size.width, size.height)
        let cropRect = CGRect(
            x: (size.width - cropSide) / 2,
            y: (size.height - cropSide) / 2,
            width: cropSide,
            height: cropSide
        )

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else { return nil }
        let cropped = UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maxSize, height: maxSize))
        let rendered = renderer.image { _ in
            cropped.draw(in: CGRect(x: 0, y: 0, width: maxSize, height: maxSize))
        }

        return rendered.jpegData(compressionQuality: 0.6)
    }
}
