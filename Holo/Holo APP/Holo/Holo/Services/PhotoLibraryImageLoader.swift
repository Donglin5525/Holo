//
//  PhotoLibraryImageLoader.swift
//  Holo
//
//  相册选中项统一图片加载器
//  PhotosPickerItem 的 loadTransferable(Data.self) 在 iCloud 原图未下载、
//  个别 HEIC 编码等场景会直接失败；此前各调用点用 try? 静默吞掉，
//  用户观感是「选完照片没反应」。这里收口：Data 失败回退系统转码管线，
//  仍失败返回 nil，由调用方统一提示。
//

import SwiftUI
import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import os.log

nonisolated enum PhotoLibraryImageLoader {

    private static let logger = Logger(subsystem: "com.holo.app", category: "PhotoLibraryImageLoader")

    // MARK: - 加载

    /// 加载相册选中项的图片数据（保留原始格式，可直接进压缩管线）。
    /// 两层策略：裸 Data 最快且保留原格式；失败时回退系统转码（DataRepresentation 会把
    /// 不可直接解码的来源转成兼容位图），兜住 iCloud 未下载原图与个别编码异常。
    static func loadImageData(from item: PhotosPickerItem) async -> Data? {
        if let data = try? await item.loadTransferable(type: Data.self),
           UIImage(data: data) != nil {
            return data
        }

        logger.error("Data 路径加载失败，回退系统转码: \(item.itemIdentifier ?? "nil")")
        if let decoded = try? await item.loadTransferable(type: DecodedImage.self) {
            return decoded.image.jpegData(compressionQuality: 0.95)
        }

        logger.error("系统转码回退也失败: \(item.itemIdentifier ?? "nil")")
        return nil
    }

    // MARK: - 失败提示

    /// 加载失败后的统一用户提示（部分失败 / 全部失败两种文案），想法、任务、反馈三处共用。
    @MainActor
    static func announceLoadFailure(failedCount: Int, totalCount: Int) {
        guard failedCount > 0 else { return }
        logger.error("图片读取失败 \(failedCount)/\(totalCount)")
        HoloToastCenter.shared.show(
            failedCount >= totalCount
                ? String(localized: "无法读取所选图片，可能是原图未下载，请联网后重试或换一张")
                : String(localized: "\(failedCount) 张图片读取失败，已添加其余图片"),
            type: .error
        )
    }
}

// MARK: - 转码回退载体

/// 走 DataRepresentation(importedContentType: .image) 的解码载体：
/// 系统会在导入时完成格式转码，覆盖裸 Data 拿得到但 UIImage 解不开的来源。
private struct DecodedImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw CocoaError(.coderInvalidValue)
            }
            return DecodedImage(image: image)
        }
    }
}
