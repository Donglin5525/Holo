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
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               UIImage(data: data) != nil {
                return .data(data)
            }
        } catch {
            logger.error("裸 Data 加载失败，进入转码层: \(error.localizedDescription, privacy: .public)")
        }

        do {
            if let decoded = try await item.loadTransferable(type: DecodedImage.self),
               let jpeg = decoded.image.jpegData(compressionQuality: 0.95) {
                return .data(jpeg)
            }
        } catch {
            logger.error("系统转码加载失败，进入 iCloud 原图下载: \(error.localizedDescription, privacy: .public)")
        }

        logger.error("Data/转码两层加载失败，尝试 iCloud 原图下载: \(item.itemIdentifier?.description ?? "nil")")
        return await downloadOriginalFromICloud(item)
    }

    /// 第三层：iCloud 原图自动下载。
    /// 前两层的 loadTransferable 遇到 iCloud 原图也会尝试系统下载，一旦失败
    /// （无网 / 蜂窝受限）说明系统下载通道不可用，此时先禁止网络快速探测：
    /// 本机已有原图直接取回；确认原图在云端再弹提示、放行网络正式下载。
    /// 无网时秒级失败不干等，有网时用户能看到「正在下载」的过程。
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
            // 「仅限选中的照片」权限下，不在授权子集内的照片按标识取不到资产。
            // 用户视角是「选择器里看得到、加载却失败」，与网络失败的自救动作不同，须细分。
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                return .limitedAccess
            }
            return .unavailable
        }

        // 禁止网络探测：立即回调，区分「本机有原图」与「原图在云端」
        let probe = await requestOriginalData(asset, allowNetwork: false)
        if let data = probe.data {
            return .data(data)
        }
        guard probe.isInCloud else {
            logger.error("本机探测失败且原图不在云端: \(probe.errorDescription, privacy: .public)")
            return .unavailable
        }

        await MainActor.run {
            HoloToastCenter.shared.show(
                String(localized: "原图在 iCloud 中，正在自动下载…"),
                type: .info,
                duration: 30
            )
        }

        var downloaded = await requestOriginalData(asset, allowNetwork: true).data
        if downloaded == nil {
            logger.error("系统相册接口下载原图失败，改用资产资源通道直取")
            downloaded = await downloadViaAssetResource(asset)
        }

        if let data = downloaded {
            // 图片已进入编辑器，收掉下载提示；失败路径不 dismiss，
            // 让紧随其后的失败提示直接顶替下载提示
            await MainActor.run { HoloToastCenter.shared.dismiss() }
            return .data(data)
        }
        return .cloudDownloadFailed
    }

    /// 按资产请求原图。allowNetwork=false 时立即回调，用于探测原图位置；
    /// true 时系统自动从 iCloud 拉取（可能耗时数十秒）。
    private static func requestOriginalData(_ asset: PHAsset, allowNetwork: Bool) async -> OriginalRequestOutcome {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = allowNetwork
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                let decodable = data.flatMap { UIImage(data: $0) } != nil
                continuation.resume(returning: OriginalRequestOutcome(
                    data: decodable ? data : nil,
                    isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) ?? false,
                    errorDescription: (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "无系统错误信息"
                ))
            }
        }
    }

    /// 第四层兜底：绕开 PHImageManager，直接按资产资源请求原图字节流。
    /// 个别资源形态（共享相簿、编辑后变体等）走相册接口会下载失败，
    /// 资源通道是 PhotoKit 更底层的取图方式，可补上这部分场景。
    private static func downloadViaAssetResource(_ asset: PHAsset) async -> Data? {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            logger.error("资产无 photo 资源，资源通道兜底不可用")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            var accumulated = Data()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { accumulated.append($0) },
                completionHandler: { error in
                    if let error {
                        logger.error("资产资源通道下载原图失败: \(error.localizedDescription, privacy: .public)")
                        continuation.resume(returning: nil)
                    } else if !accumulated.isEmpty, UIImage(data: accumulated) != nil {
                        continuation.resume(returning: accumulated)
                    } else {
                        logger.error("资产资源通道返回空数据或不可解码数据")
                        continuation.resume(returning: nil)
                    }
                }
            )
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
    /// 全部失败时优先区分权限与 iCloud 下载原因——它们有明确的自救动作（去设置开启 / 改授权范围 / 换网络）。
    @MainActor
    static func announceLoadFailure(failedCount: Int, totalCount: Int, permissionRequired: Bool = false, limitedAccess: Bool = false, cloudFailed: Bool = false) {
        guard failedCount > 0 else { return }
        logger.error("图片读取失败 \(failedCount)/\(totalCount) permissionRequired=\(permissionRequired) limitedAccess=\(limitedAccess) cloudFailed=\(cloudFailed)")
        if failedCount >= totalCount && permissionRequired {
            HoloToastCenter.shared.show(
                String(localized: "相册读取权限未开启，无法自动下载 iCloud 中的原图，请在系统设置中允许 Holo 访问照片"),
                type: .error
            )
        } else if failedCount >= totalCount && limitedAccess {
            HoloToastCenter.shared.show(
                String(localized: "相册权限是「仅限选中的照片」，所选图片不在允许范围内。可在系统设置 > Holo > 照片中改为「所有照片」后重试"),
                type: .error
            )
        } else if failedCount >= totalCount && cloudFailed {
            HoloToastCenter.shared.show(
                String(localized: "图片原图存放在 iCloud，但下载失败。请检查网络后重试，或连上 Wi-Fi 再试"),
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
    /// 相册读取权限未开启，无法按资产标识自动下载 iCloud 中的原图
    case permissionRequired
    /// 相册权限是「仅限选中的照片」，所选照片不在授权子集内（选择器看得到，按标识取不到）
    case limitedAccess
    /// 已确认原图在 iCloud，但下载失败（网络不可用 / 蜂窝受限等），换网络或稍后重试可能成功
    case cloudDownloadFailed
    /// 下载失败（网络不可用等），重试可能成功
    case unavailable
}

/// 按资产请求原图的单次结果：data 可解码即视为成功，
/// isInCloud 与底层错误描述用于探测与失败归因
private struct OriginalRequestOutcome {
    let data: Data?
    let isInCloud: Bool
    let errorDescription: String
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
