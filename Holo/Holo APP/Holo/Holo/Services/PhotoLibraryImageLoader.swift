//
//  PhotoLibraryImageLoader.swift
//  Holo
//
//  相册选中项统一图片加载器
//  核心策略（微信式渐进加载）：
//  附件存储管线只需要最长边 2048 的版本，因此取图也按目标尺寸取，
//  不再以「下载 iCloud 原图」为主路径——原图可能几十 MB 且必须走网络，
//  而 2048 版本系统多数情况能用本机缓存直接生成，秒回。
//  链路分层：
//  1. 禁网探测原图：本机已有原图直接无损取回（最快，不渐进）；
//  2. 原图在 iCloud：系统按目标尺寸渐进出图（deliveryMode = .opportunistic），
//     本机缓存低清占位帧秒回，成品帧由系统补齐，个别情况才触发网络下载；
//  3. 系统出图失败：资产资源通道直取原图字节兜底；
//  4. 无相册权限 / 拿不到资产（仅添加照片、受限授权等）：回退选择器
//     loadTransferable 传输通道（裸 Data → 系统转码），该通道不依赖读取权限。
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

    /// 渐进取图目标尺寸（像素）：与附件存储管线 compressImage(maxDimension: 2048) 同口径，
    /// 避免为展示图下载几十 MB 原图再压回 2048。
    private static let targetPixelSize = CGSize(width: 2048, height: 2048)

    // MARK: - 渐进加载

    /// 微信式渐进加载事件流：占位帧（本机缓存低清，秒回）先到，成品帧后到；
    /// 本机已有原图时直接成品（携带原始字节，无损），失败时给出可行动的原因。
    enum ProgressiveEvent: Sendable {
        case placeholder(UIImage)
        /// originalData 是探测层拿到的原始字节（无损路径）；系统出图路径为 nil
        case loaded(UIImage, originalData: Data?)
        case failed(PhotoLoadOutcome)
    }

    static func progressiveLoad(from item: PhotosPickerItem) -> AsyncStream<ProgressiveEvent> {
        AsyncStream { continuation in
            let task = Task {
                await runProgressiveLoad(item, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func runProgressiveLoad(_ item: PhotosPickerItem, continuation: AsyncStream<ProgressiveEvent>.Continuation) async {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            break
        case .notDetermined:
            // 兜底授权时机：入口处（从相册选择）已做前置授权，此处覆盖
            // FeedbackSheet 等声明式选择器入口
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                continuation.yield(.failed(.permissionRequired))
                return
            }
        default:
            // 「仅添加照片」等无读取权限形态：按资产取图的通道全部不可用，
            // 回退选择器传输通道（选择器内容本身经系统授权传输，不需要读取权限）
            logger.error("无相册读取权限，回退选择器传输通道")
            continuation.yield(await loadViaTransferable(item))
            return
        }

        guard let identifier = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            // 「仅限选中的照片」权限下，不在授权子集内的照片按标识取不到资产。
            // 用户视角是「选择器里看得到、加载却失败」，与网络失败的自救动作不同，须细分。
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                continuation.yield(.failed(.limitedAccess))
                return
            }
            continuation.yield(await loadViaTransferable(item))
            return
        }

        // 禁止网络探测：立即回调，区分「本机有原图」与「原图在云端」；
        // 本机有原图直接无损成品，无需渐进。
        let probe = await requestOriginalData(asset, allowNetwork: false)
        if let data = probe.data, let image = UIImage(data: data) {
            continuation.yield(.loaded(image, originalData: data))
            return
        }
        guard probe.isInCloud else {
            logger.error("本机探测失败且原图不在云端: \(probe.errorDescription, privacy: .public)")
            continuation.yield(.failed(.unavailable))
            return
        }

        // 原图在 iCloud：系统按目标尺寸渐进出图，占位帧先回，成品帧可能等下载
        let outcome = await requestImageProgressively(asset) { image in
            continuation.yield(.placeholder(image))
        }
        switch outcome {
        case .loaded(let image):
            continuation.yield(.loaded(image, originalData: nil))
        case .failed:
            logger.error("系统渐进出图失败，改用资产资源通道直取")
            if let data = await downloadViaAssetResource(asset), let image = UIImage(data: data) {
                continuation.yield(.loaded(image, originalData: data))
            } else {
                continuation.yield(.failed(.cloudDownloadFailed))
            }
        case .cancelled:
            break
        }
    }

    /// 选择器传输通道兜底（无读取权限 / 资产取不到时）：
    /// 裸 Data 最快且保留原格式；失败走系统转码覆盖编码异常。
    private static func loadViaTransferable(_ item: PhotosPickerItem) async -> ProgressiveEvent {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                return .loaded(image, originalData: data)
            }
        } catch {
            logger.error("裸 Data 加载失败，进入转码层: \(error.localizedDescription, privacy: .public)")
        }

        do {
            if let decoded = try await item.loadTransferable(type: DecodedImage.self) {
                return .loaded(decoded.image, originalData: nil)
            }
        } catch {
            logger.error("系统转码加载失败: \(error.localizedDescription, privacy: .public)")
        }
        return .failed(.unavailable)
    }

    /// 系统渐进出图：opportunistic 模式先回调低清占位帧（degraded），
    /// 成品帧（非 degraded）到达即结束；下载失败/取消按结果区分。
    private static func requestImageProgressively(
        _ asset: PHAsset,
        onPlaceholder: @escaping @Sendable (UIImage) -> Void
    ) async -> ProgressiveImageOutcome {
        let handle = ImageRequestHandle()
        let outcome = await withTaskCancellationHandler {
            // continuation 类型必须显式标注：泛型 T 若靠嵌套的 requestImage 回调里的
            // resume(returning:) 反推，类型推断会断裂（contextual base 连锁报错）
            await withCheckedContinuation { (continuation: CheckedContinuation<ProgressiveImageOutcome, Never>) in
                let resumeOnce = ResumeOnce()
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                let requestId = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetPixelSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if isDegraded {
                        if let image {
                            onPlaceholder(image)
                        }
                        return
                    }
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    if isCancelled {
                        resumeOnce.run { continuation.resume(returning: .cancelled) }
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        logger.error("系统渐进出图失败: \(error.localizedDescription, privacy: .public)")
                        resumeOnce.run { continuation.resume(returning: .failed) }
                        return
                    }
                    guard let image else {
                        resumeOnce.run { continuation.resume(returning: .failed) }
                        return
                    }
                    resumeOnce.run { continuation.resume(returning: .loaded(image)) }
                }
                handle.activate(requestId)
            }
        } onCancel: {
            handle.cancel()
        }
        return outcome
    }

    // MARK: - 整图加载（旧接口，聚合渐进流）

    /// 加载相册选中项的图片数据。内部走渐进主路径并聚合为单次结果；
    /// 占位帧出现说明原图在 iCloud 且系统正在下载，弹提示保持过程可见。
    static func loadImageData(from item: PhotosPickerItem) async -> PhotoLoadOutcome {
        var sawPlaceholder = false
        for await event in progressiveLoad(from: item) {
            if case .placeholder = event {
                sawPlaceholder = true
                await MainActor.run {
                    HoloToastCenter.shared.show(
                        String(localized: "原图在 iCloud 中，正在自动下载…"),
                        type: .info,
                        duration: 30
                    )
                }
            }
            if let outcome = resolve(event) {
                if sawPlaceholder, case .data = outcome {
                    // 图片已就绪，收掉下载提示；失败路径不 dismiss，
                    // 让紧随其后的失败提示直接顶替下载提示
                    await MainActor.run { HoloToastCenter.shared.dismiss() }
                }
                return outcome
            }
        }
        return .unavailable
    }

    /// 渐进事件 → 终态结果（placeholder 返回 nil 继续等成品）：
    /// 探测层原始字节无损透传；系统出图路径按存储管线口径编码 JPEG。
    static func resolve(_ event: ProgressiveEvent) -> PhotoLoadOutcome? {
        switch event {
        case .placeholder:
            return nil
        case .loaded(let image, let originalData):
            if let originalData {
                return .data(originalData)
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.95) else {
                return .unavailable
            }
            return .data(jpeg)
        case .failed(let outcome):
            return outcome
        }
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

    /// 底层兜底：绕开 PHImageManager，直接按资产资源请求原图字节流。
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

    /// 从相册选择前的读取权限预申请：权限是「按资产取图（含 iCloud 渐进出图）」的前提，
    /// 在入口一次性申请完，用户第一次选 iCloud 原图就能直接下载成功。
    /// 授权结果不阻断选图——本地照片不依赖权限，被拒时走选择器传输通道兜底。
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

// MARK: - 渐进出图结果

private enum ProgressiveImageOutcome {
    case loaded(UIImage)
    case failed
    case cancelled
}

/// resume-once 守卫：PHImageManager 的回调可能多次触发（占位/成品/取消/错误），
/// continuation 只允许 resume 一次。
/// nonisolated 必须显式声明：工程默认 MainActor 隔离，隐式隔离的 init 从
/// nonisolated loader 静态上下文调用会断裂类型推断（编译期连锁报错）。
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

/// 请求句柄：注册取消时请求 ID 可能尚未返回（竞态窗口），
/// 句柄内部补挂 cancel，保证流被消费方放弃后系统请求一定被终止。
nonisolated final class ImageRequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var requestId: PHImageRequestID?
    private var cancelled = false

    func activate(_ id: PHImageRequestID) {
        lock.lock()
        defer { lock.unlock() }
        requestId = id
        if cancelled {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let requestId {
            PHImageManager.default().cancelImageRequest(requestId)
        }
    }
}

// MARK: - 加载结果

/// 相册图片加载结果：失败时区分原因，供调用方给出可行动的用户指引
enum PhotoLoadOutcome: Sendable, Equatable {
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
