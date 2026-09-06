//
//  PhotoLibraryImageLoader.swift
//  Holo
//
//  相册选中项统一图片加载器
//  PhotosPickerItem 的 loadTransferable(Data.self) 在 iCloud 原图未下载、
//  个别 HEIC 编码等场景会直接失败。三层策略逐级兜底：
//  1. 裸 Data：最快且保留原格式，本地照片走这里；
//  2. 系统转码：DataRepresentation 导入时转码，兜住编码异常；
//  3. 系统相册接口按资产标识取原图并允许网络访问——原图在 iCloud 时
//     由系统自动下载，用户无需手动「联网重试」。
//  第 3 层依赖相册读取权限（选择器本身不需要权限，权限只用于取资产标识），
//  权限缺失时返回 .permissionRequired，由调用方给出开启指引。
//

import SwiftUI
import UIKit
import PhotosUI
import Photos
import CoreTransferable
import UniformTypeIdentifiers
import os.log

nonisolated enum PhotoLibraryImageLoader {

    private static let logger = Logger(subsystem: "com.holo.app", category: "PhotoLibraryImageLoader")

    // MARK: - 加载

    /// 加载相册选中项的图片数据（保留原始格式，可直接进压缩管线）
    static func loadImageData(from item: PhotosPickerItem) async -> PhotoLoadOutcome {
        if let data = try? await item.loadTransferable(type: Data.self),
           UIImage(data: data) != nil {
            return .data(data)
        }

        if let decoded = try? await item.loadTransferable(type: DecodedImage.self),
           let jpeg = decoded.image.jpegData(compressionQuality: 0.95) {
            return .data(jpeg)
        }

        logger.error("Data/转码两层加载失败，尝试 iCloud 原图下载: \(item.itemIdentifier ?? "nil")")
        return await downloadOriginalFromICloud(item)
    }

    /// 第三层：iCloud 原图自动下载。
    /// 前两层失败基本只剩「原图未下载到本机」的场景，此时用资产标识取回
    /// PHAsset，requestImageDataAndOrientation 允许网络访问后系统会自动
    /// 从 iCloud 拉取原图（可能耗时数秒，用 Toast 告知用户正在下载）。
    private static func downloadOriginalFromICloud(_ item: PhotosPickerItem) async -> PhotoLoadOutcome {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            break
        case .notDetermined:
            // 兜底授权时机：入口处（从相册选择）已做前置授权，此处覆盖
            // FeedbackSheet 等声明式选择器入口
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else { return .permissionRequired }
        default:
            return .permissionRequired
        }

        guard let identifier = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return .unavailable
        }

        await MainActor.run {
            HoloToastCenter.shared.show(
                String(localized: "原图在 iCloud 中，正在自动下载…"),
                type: .info,
                duration: 10
            )
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data, UIImage(data: data) != nil {
                    continuation.resume(returning: .data(data))
                } else {
                    let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    logger.error("iCloud 原图下载失败 isInCloud=\(isInCloud): \(item.itemIdentifier ?? "nil")")
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    // MARK: - 相册读取权限

    /// 从相册选择前的读取权限预申请：权限是「iCloud 原图自动下载」的前提，
    /// 在入口一次性申请完，用户第一次选 iCloud 原图就能直接下载成功。
    /// 授权结果不阻断选图——本地照片不依赖权限，被拒时 iCloud 原图场景
    /// 会在加载失败时给出开启指引。
    @MainActor
    static func requestLibraryAccessIfNeeded() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else { return }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - 失败提示

    /// 加载失败后的统一用户提示（部分失败 / 全部失败两种口径），想法、任务、反馈三处共用。
    /// 全部失败时优先区分权限原因——它有明确的自救动作（去设置开启）。
    @MainActor
    static func announceLoadFailure(failedCount: Int, totalCount: Int, permissionRequired: Bool = false) {
        guard failedCount > 0 else { return }
        logger.error("图片读取失败 \(failedCount)/\(totalCount) permissionRequired=\(permissionRequired)")
        if failedCount >= totalCount && permissionRequired {
            HoloToastCenter.shared.show(
                String(localized: "相册读取权限未开启，无法自动下载 iCloud 中的原图，请在系统设置中允许 Holo 访问照片"),
                type: .error
            )
        } else if failedCount >= totalCount {
            HoloToastCenter.shared.show(
                String(localized: "无法读取所选图片，请检查网络后重试，或换一张图片"),
                type: .error
            )
        } else {
            HoloToastCenter.shared.show(
                String(localized: "\(failedCount) 张图片读取失败，已添加其余图片"),
                type: .error
            )
        }
    }
}

// MARK: - 加载结果

/// 相册图片加载结果：失败时区分原因，供调用方给出可行动的用户指引
enum PhotoLoadOutcome: Sendable {
    case data(Data)
    /// 相册读取权限未开启，无法按资产标识自动下载 iCloud 原图
    case permissionRequired
    /// 下载失败（网络不可用等），重试可能成功
    case unavailable
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
