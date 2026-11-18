//
//  VisualMediaAcquisition.swift
//  Holo
//
//  媒体采集统一桥接层（2026-11-18 全链路修复 · 方案 §2.2.1）：
//  相机 / 相册 / 文件三条采集通道收敛到一个互斥的 activeSource 状态，
//  由 .visualMediaPresenter 统一呈现——三条 presentation 挂在各自独立的
//  空宿主节点上，任一时刻最多激活一个，杜绝多层套娃下的呈现冲突（B3/B4 根治）。
//  - 相机：权限前置检查（notDetermined 先请求；denied 由调用方弹引导），
//    Coordinator 不手动 dismiss，回调驱动 SwiftUI 状态统一关闭
//  - 相册：PHPickerViewController 封装；取图走想法模块同款
//    PhotoLibraryImageLoader（本机秒回 / iCloud 原图渐进下载带 toast 进度 /
//    失败分类提示不静默——2026-11-18 东林实报「选完照片完全没反应」根治：
//    旧实现 loadDataRepresentation 失败被当取消吞掉）
//  - 文件：.fileImporter 直挂宿主，支持透明 PNG 直通
//

import SwiftUI
import AVFoundation
import PhotosUI
import Photos
import UniformTypeIdentifiers

// MARK: - 采集源（互斥）

enum VisualMediaSource: String, Identifiable {
    case camera
    case photoLibrary
    case document
    var id: String { rawValue }
}

@MainActor
enum VisualMediaAcquisition {

    /// 相机权限前置：authorized 直放行；notDetermined 先请求；denied/restricted 拒绝（调用方弹引导去设置）
    static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// 相册选中项 → 图片字节（iCloud 感知，失败不吞）：
    /// 1. 有资产标识（已授权读取）→ PhotoLibraryImageLoader 渐进加载：
    ///    本机图秒回；iCloud 原图系统渐进下载（toast 进度提示）；失败按原因分类提示
    /// 2. 无资产标识（未授权等）→ 选择器传输通道直读原始字节；失败如实提示
    static func loadPhotoData(from result: PHPickerResult) async -> Data? {
        if let assetIdentifier = result.assetIdentifier {
            let outcome = await PhotoLibraryImageLoader.loadImageData(assetIdentifier: assetIdentifier)
            if case .data(let data) = outcome {
                return data
            }
            switch outcome {
            case .permissionRequired:
                PhotoLibraryImageLoader.announceLoadFailure(failedCount: 1, totalCount: 1, permissionRequired: true)
            case .limitedAccess:
                PhotoLibraryImageLoader.announceLoadFailure(failedCount: 1, totalCount: 1, limitedAccess: true)
            case .cloudDownloadFailed:
                PhotoLibraryImageLoader.announceLoadFailure(failedCount: 1, totalCount: 1, cloudFailed: true)
            default:
                PhotoLibraryImageLoader.announceLoadFailure(failedCount: 1, totalCount: 1)
            }
            return nil
        }
        return await loadViaProvider(result.itemProvider)
    }

    /// 无资产标识的兜底通道：选择器内容经系统授权传输，不依赖读取权限；
    /// 失败如实提示（不再静默当取消吞掉）
    private static func loadViaProvider(_ provider: NSItemProvider) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            await MainActor.run {
                HoloToastCenter.shared.show(String(localized: "无法读取所选图片，请换一张"), type: .error)
            }
            return nil
        }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                DispatchQueue.main.async {
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        HoloToastCenter.shared.show(
                            String(localized: "无法读取所选图片，请检查网络后重试，或换一张"),
                            type: .error)
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - 相机（UIImagePickerController，无手动 dismiss）

/// 相机采集：Coordinator 只回调不 dismiss——由 SwiftUI 的 activeSource 状态翻转统一关闭
/// （对齐 TaskImagePicker / TransactionReceiptViews 的既有可靠范式）。
/// 无相机硬件（模拟器）时兜底相册。
struct VisualCameraCapture: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VisualCameraCapture
        init(_ parent: VisualCameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onCapture(image?.jpegData(compressionQuality: 0.92))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
        }
    }
}

// MARK: - 相册（PHPickerViewController，原始字节直读）

/// PHPicker 封装：filter .images / selectionLimit 1；选完回传 PHPickerResult，
/// 取图由 ``VisualMediaAcquisition/loadPhotoData(from:)`` 统一走 iCloud 感知通道；
/// 取消与选中都由回调驱动，无双重 dismiss
struct VisualPhotoLibraryPicker: UIViewControllerRepresentable {
    let onResult: (PHPickerResult) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VisualPhotoLibraryPicker
        init(_ parent: VisualPhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if let result = results.first {
                parent.onResult(result)
            } else {
                parent.onCancel()
            }
        }
    }
}

// MARK: - 统一呈现修饰器

private struct VisualMediaPresenterModifier: ViewModifier {
    @Binding var activeSource: VisualMediaSource?
    let onPickedData: (Data) async -> Void

    func body(content: Content) -> some View {
        content
            .background {
                // 三条 presentation 各挂独立空宿主，互斥激活；
                // Color.clear 不参与命中测试，纯当稳定宿主用
                ZStack {
                    Color.clear
                        .fullScreenCover(isPresented: cameraActive) {
                            VisualCameraCapture { data in
                                activeSource = nil
                                if let data { Task { await onPickedData(data) } }
                            }
                            .ignoresSafeArea()
                        }
                    Color.clear
                        .sheet(isPresented: libraryActive) {
                            VisualPhotoLibraryPicker { result in
                                activeSource = nil
                                // 取图交给 iCloud 感知通道：等待期/失败都有可见反馈
                                Task { await onPickedPhoto(result) }
                            } onCancel: {
                                activeSource = nil
                            }
                            .ignoresSafeArea()
                        }
                    Color.clear
                        .fileImporter(isPresented: documentActive,
                                      allowedContentTypes: [.image],
                                      allowsMultipleSelection: false) { result in
                            activeSource = nil
                            guard case .success(let urls) = result, let url = urls.first else { return }
                            let secured = url.startAccessingSecurityScopedResource()
                            defer { if secured { url.stopAccessingSecurityScopedResource() } }
                            guard let data = try? Data(contentsOf: url) else { return }
                            Task { await onPickedData(data) }
                        }
                }
            }
    }

    /// 相册选中：iCloud 感知加载成功才进入制作管线
    private func onPickedPhoto(_ result: PHPickerResult) async {
        guard let data = await VisualMediaAcquisition.loadPhotoData(from: result) else { return }
        await onPickedData(data)
    }

    private var cameraActive: Binding<Bool> {
        .init(get: { activeSource == .camera },
              set: { if !$0, activeSource == .camera { activeSource = nil } })
    }
    private var libraryActive: Binding<Bool> {
        .init(get: { activeSource == .photoLibrary },
              set: { if !$0, activeSource == .photoLibrary { activeSource = nil } })
    }
    private var documentActive: Binding<Bool> {
        .init(get: { activeSource == .document },
              set: { if !$0, activeSource == .document { activeSource = nil } })
    }
}

extension View {
    /// 媒体采集统一宿主：activeSource 三态互斥；拿到图片字节后异步回投。
    /// 相机入口请先过 `VisualMediaAcquisition.requestCameraAccess()`（被拒由调用方弹引导）；
    /// 相册入口建议先 `PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()`（iCloud 渐进下载前提）
    func visualMediaPresenter(activeSource: Binding<VisualMediaSource?>,
                              onPickedData: @escaping (Data) async -> Void) -> some View {
        modifier(VisualMediaPresenterModifier(activeSource: activeSource, onPickedData: onPickedData))
    }
}
