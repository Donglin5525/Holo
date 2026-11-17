//
//  StickerMakerView.swift
//  Holo
//
//  拍照制作贴纸（方案 01 §3，原型即契约——场景一/来源选择器 1:1）：
//  三条来源一等公民（拍照 / 从相册选 / 从文件导入，含透明 PNG 不二次抠图）；
//  贴纸/照片双模式；确认页贴纸与原图可对照、纸边三档×厚度两档；
//  等待约 10 秒恢复可操作，取消立即返回；「使用」放回来源页面由调用方承接。
//  状态机（02 §3.6）：idle → acquiring → processing → editing → prepared → committing。
//

import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import CoreData

// MARK: - 状态机

@MainActor
final class StickerMakerModel: ObservableObject {

    enum Phase: Equatable {
        case picking                 // 来源选择
        case acquiring               // 读 iCloud 原图（可联网）
        case processing              // 端侧分割（不联网）
        case editing                 // 确认页（贴纸/原图对照、纸边）
        case committing              // 提交中
        case failed(StickerMakerFailure)
    }

    enum StickerMakerFailure: Equatable {
        case noSubjectFound          // 没找到清晰主体：可裁近重试 / 换图 / 改用照片
        case requestFailed           // 端侧能力不可用或调用失败
        case tooLarge
        case corrupted
        case saveFailed
    }

    enum Mode: String, CaseIterable {
        case sticker = "贴纸"
        case photo = "照片"
    }

    @Published var phase: Phase = .picking
    @Published var mode: Mode = .sticker
    @Published var showOriginal = false            // 确认页对照切换
    @Published var borderStyle: VisualPlacementPayload.Presentation.BorderStyle = .adaptivePaper
    @Published var borderWeight: VisualPlacementPayload.Presentation.BorderWeight = .standard

    /// 工作产物（editing 后有效）
    private(set) var workingImage: VisualWorkingImage?
    private(set) var occupancyMask: CVPixelBuffer?
    private(set) var originalData: Data?
    private(set) var instanceCount = 1

    /// 初始展示模式跟随调用场景（「制作贴纸」进默认贴纸；「添加照片头图」进默认照片）
    init(initialMode: Mode = .sticker) {
        mode = initialMode
    }

    // MARK: - 输入接管（三条来源等价）

    func ingest(data: Data) async {
        phase = .acquiring
        do {
            let working = try VisualAssetImageProcessor.prepareWorkingImage(from: data)
            originalData = data
            workingImage = working
            if mode == .sticker {
                await extractSubject(from: working)
            } else {
                occupancyMask = nil
                phase = .editing
            }
        } catch VisualAssetImageError.tooLarge {
            phase = .failed(.tooLarge)
        } catch {
            phase = .failed(.corrupted)
        }
    }

    /// 透明 PNG 导入：不二次抠图、默认不加纸边（02 §3.4 / 01 §3.1）
    func ingestTransparentPNG(data: Data) async {
        phase = .acquiring
        do {
            let working = try VisualAssetImageProcessor.prepareWorkingImage(from: data)
            guard working.hasAlpha else {
                // 不是真透明图：走普通照片/贴纸路径
                await ingest(data: data)
                return
            }
            originalData = data
            workingImage = working
            occupancyMask = VisualAssetImageProcessor.occupancyMask(fromAlphaOf: working.cgImage)
            borderStyle = .none
            mode = .sticker
            phase = .editing
        } catch {
            phase = .failed(.corrupted)
        }
    }

    private func extractSubject(from working: VisualWorkingImage) async {
        phase = .processing
        do {
            let result = try await SubjectExtractionService.shared.extract(from: working.cgImage)
            occupancyMask = result.occupancyMask
            instanceCount = result.instanceIndices.count
            phase = .editing
        } catch SubjectExtractionError.noSubjectFound {
            phase = .failed(.noSubjectFound)
        } catch {
            phase = .failed(.requestFailed)
        }
    }

    /// 改用照片（失败出口之一：不强求抠图，01 §3.5）
    func fallBackToPhoto() {
        mode = .photo
        occupancyMask = nil
        if workingImage != nil { phase = .editing }
    }

    // MARK: - 预览（纸边即时重绘）

    func previewImage() -> CGImage? {
        guard let working = workingImage else { return nil }
        if mode == .photo { return working.cgImage }
        guard let mask = occupancyMask else { return nil }
        let presentation = VisualPlacementPayload.Presentation(borderStyle: borderStyle,
                                                               borderWeight: borderWeight)
        return StickerRenderer.renderDisplayImageForPreview(subject: working.cgImage,
                                                            mask: mask, presentation: presentation)
    }

    func originalPreview() -> CGImage? {
        workingImage?.cgImage
    }

    // MARK: - 提交（调用方持有 owner 信息）

    func commit(ownerKind: String, ownerKey: String, slot: String,
                expectedWinner: UUID?,
                in container: NSPersistentContainer) async -> Bool {
        guard let working = workingImage, let originalData else { return false }
        phase = .committing
        let operationID = UUID()
        let kind: VisualAssetKind = mode == .sticker ? .sticker : .photo
        let mask = occupancyMask
        let data = originalData
        let presentation = VisualPlacementPayload.Presentation(borderStyle: borderStyle,
                                                              borderWeight: borderWeight)
        do {
            // 普通照片默认不进素材库；贴纸做完默认入「我的贴纸」（01 §3.1）
            let payload: VisualPlacementPayload
            if ownerKind.isEmpty {
                payload = .clear // createAssetOnly 路径不用 payload
                _ = try await VisualCommitCoordinator.shared.commit(
                    .createAssetOnly(operationID: operationID) { asset in
                        Self.fill(asset: asset, kind: kind, working: working,
                                  originalData: data, mask: mask)
                    }, in: container)
            } else {
                payload = .setAsset(.asset(UUID()), presentation: presentation)
                _ = try await VisualCommitCoordinator.shared.commit(
                    .createAssetAndApply(operationID: operationID, ownerKind: ownerKind,
                                         ownerKey: ownerKey, slot: slot,
                                         expectedSlotWinnerRevisionID: expectedWinner,
                                         payload: payload) { asset in
                        Self.fill(asset: asset, kind: kind, working: working,
                                  originalData: data, mask: mask)
                    }, in: container)
            }
            phase = .editing
            return true
        } catch {
            phase = .failed(.saveFailed)
            return false
        }
    }

    /// 素材字段填充（像素不可变组：工作图/遮罩/紧裁主体/缩略图 + 尺寸/hash）
    static func fill(asset: VisualAsset, kind: VisualAssetKind,
                     working: VisualWorkingImage, originalData: Data, mask: CVPixelBuffer?) {
        guard let sourcePNG = VisualAssetImageProcessor.encodePNG(working.cgImage) else { return }
        asset.setValue(sourcePNG, forKey: "sourceData")
        asset.setValue(UTType.png.identifier, forKey: "sourceUTType")
        asset.setValue(VisualAssetDraftStore.sha256(sourcePNG), forKey: "sourceHash")
        asset.setValue(working.width, forKey: "sourceWidth")
        asset.setValue(working.height, forKey: "sourceHeight")
        if kind == .sticker, let mask,
           let maskPNG = VisualAssetImageProcessor.encodeMaskPNG(mask) {
            asset.setValue(maskPNG, forKey: "maskData")
            asset.setValue(VisualAssetDraftStore.sha256(maskPNG), forKey: "maskHash")
            if let tight = VisualAssetImageProcessor.tightCrop(working.cgImage, mask: mask,
                                                               maxLongest: 1536),
               let tightPNG = VisualAssetImageProcessor.encodePNG(tight) {
                asset.setValue(tightPNG, forKey: "contentData")
                asset.setValue(UTType.png.identifier, forKey: "contentUTType")
                asset.setValue(VisualAssetDraftStore.sha256(tightPNG), forKey: "contentHash")
                asset.setValue(tight.width, forKey: "contentWidth")
                asset.setValue(tight.height, forKey: "contentHeight")
            }
        }
        if let thumbPNG = VisualAssetImageProcessor.encodePNG(
            VisualAssetImageProcessor.downscale(working.cgImage, targetLongest: 320)) {
            asset.setValue(thumbPNG, forKey: "thumbnailData")
            asset.setValue(VisualAssetDraftStore.sha256(thumbPNG), forKey: "thumbnailHash")
        }
        asset.setValue(kind.rawValue, forKey: "kind")
        asset.setValue("visible", forKey: "libraryVisibility")
    }
}

// MARK: - 主视图

struct StickerMakerView: View {
    @StateObject private var model: StickerMakerModel
    /// 「使用」回执：调用方关闭弹层并刷新
    let onFinished: (Bool) -> Void
    /// 应用目标；ownerKind 空串 = 只存入素材库
    var ownerKind: String = ""
    var ownerKey: String = ""
    var slot: String = ""
    var expectedWinner: UUID? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showDocument = false
    @State private var commitToast: String?

    init(initialMode: StickerMakerModel.Mode = .sticker,
         ownerKind: String = "", ownerKey: String = "", slot: String = "",
         expectedWinner: UUID? = nil, onFinished: @escaping (Bool) -> Void) {
        _model = StateObject(wrappedValue: StickerMakerModel(initialMode: initialMode))
        self.ownerKind = ownerKind
        self.ownerKey = ownerKey
        self.slot = slot
        self.expectedWinner = expectedWinner
        self.onFinished = onFinished
    }

    var body: some View {
        HoloSheetScaffold(title: model.mode == .sticker && model.phase != .picking ? "确认主体" : "制作贴纸",
                          onClose: { dismiss() },
                          primaryTitle: primaryTitle,
                          primaryAction: primaryAction,
                          primaryDisabled: model.phase != .editing,
                          primaryHint: primaryHint) {
            content
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { data in
                if let data { Task { await model.ingest(data: data) } }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showLibrary) {
            PhotoLibraryPicker { data in
                if let data { Task { await model.ingest(data: data) } }
            }
        }
        .fileImporter(isPresented: $showDocument, allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let isTransparentPNG: Bool
                    if let type = VisualAssetImageProcessor.probeUTType(of: data), type.conforms(to: .png),
                       let working = try? VisualAssetImageProcessor.prepareWorkingImage(from: data) {
                        isTransparentPNG = working.hasAlpha
                    } else {
                        isTransparentPNG = false
                    }
                    Task {
                        if isTransparentPNG {
                            await model.ingestTransparentPNG(data: data)
                        } else {
                            await model.ingest(data: data)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .picking:
            sourcePicker
        case .acquiring:
            ProgressView("正在读取照片…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .processing:
            processingView
        case .editing:
            confirmView
        case .committing:
            ProgressView("正在保存…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            failureView(failure)
        }
    }

    /// 来源选择（01 §3.1：三条来源都是基本入口；顶部拍照/相册/文件）
    private var sourcePicker: some View {
        VStack(spacing: 14) {
            Picker("模式", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(StickerMakerModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            HStack(spacing: 10) {
                sourceOption(icon: "camera", title: "拍照制作", caption: "在需要用图的地方直接拍") {
                    showCamera = true
                }
                sourceOption(icon: "photo.on.rectangle", title: "从相册选", caption: "已在手机的图") {
                    showLibrary = true
                }
                sourceOption(icon: "doc", title: "从文件导入", caption: "含透明 PNG · 不二次抠图") {
                    showDocument = true
                }
            }
            .padding(.horizontal)

            Text("不拍照也完全可用；照片在设备上处理，不上传。")
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func sourceOption(icon: String, title: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.holoToolAction)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.holoToolSurface)
            .cornerRadius(13)
        }
        .buttonStyle(.plain)
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在提取主体…")
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
            Text("可以取消；不伪造进度")
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 确认页（原型场景一：对照、纸边三档、厚度、使用）
    private var confirmView: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 对照画布
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.holoToolInset)
                    if let image = model.showOriginal ? model.originalPreview() : model.previewImage() {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(14)
                    }
                }
                .frame(height: 264)

                if model.mode == .sticker {
                    // 贴纸 / 原图对照
                    Picker("对照", selection: Binding(get: { model.showOriginal }, set: { model.showOriginal = $0 })) {
                        Text("贴纸（已去背景）").tag(false)
                        Text("原图").tag(true)
                    }
                    .pickerStyle(.segmented)

                    // 纸边风格（默认自适应＋标准）
                    VStack(alignment: .leading, spacing: 7) {
                        Text("纸边风格")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                        Picker("纸边", selection: Binding(get: { model.borderStyle }, set: { model.borderStyle = $0 })) {
                            Text("自适应").tag(VisualPlacementPayload.Presentation.BorderStyle.adaptivePaper)
                            Text("纯白").tag(VisualPlacementPayload.Presentation.BorderStyle.white)
                            Text("无").tag(VisualPlacementPayload.Presentation.BorderStyle.none)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("厚度").font(.system(size: 11.5)).foregroundColor(.holoToolTextSecondary)
                            Picker("厚度", selection: Binding(get: { model.borderWeight }, set: { model.borderWeight = $0 })) {
                                Text("细").tag(VisualPlacementPayload.Presentation.BorderWeight.thin)
                                Text("标准").tag(VisualPlacementPayload.Presentation.BorderWeight.standard)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func failureView(_ failure: StickerMakerModel.StickerMakerFailure) -> some View {
        VStack(spacing: 12) {
            switch failure {
            case .noSubjectFound:
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(.holoToolTextSecondary)
                Text("没有找到清晰的主体，可以裁近一点再试")
                    .font(.system(size: 14, weight: .medium))
                Button("改用普通照片") { model.fallBackToPhoto() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolAction)
            case .tooLarge:
                Text("这张图片太大了，换一张试试")
                    .font(.system(size: 14))
            case .corrupted:
                Text("图片无法读取，可能已损坏")
                    .font(.system(size: 14))
            case .requestFailed:
                Text("这张图片暂时无法自动制作贴纸")
                    .font(.system(size: 14))
                Button("改用普通照片") { model.fallBackToPhoto() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolAction)
            case .saveFailed:
                Text("保存没有完成，已保留当前编辑")
                    .font(.system(size: 14))
            }
            Button("重新选择") { model.phase = .picking }
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部按钮

    private var primaryTitle: String? {
        switch model.phase {
        case .editing: return "使用"
        default: return nil
        }
    }

    private var primaryHint: String? {
        if case .editing = model.phase, model.mode == .sticker, model.instanceCount > 1 {
            return "识别到 \(model.instanceCount) 个主体，已选全部"
        }
        return nil
    }

    private func primaryAction() {
        guard case .editing = model.phase else { return }
        Task {
            let container = CoreDataStack.shared.persistentContainer
            let ok = await model.commit(ownerKind: ownerKind, ownerKey: ownerKey,
                                        slot: slot, expectedWinner: expectedWinner,
                                        in: container)
            if ok {
                onFinished(true)
                dismiss()
            }
        }
    }
}

// MARK: - 相机（UIImagePickerController 系统管理预览，规避自管 AVCapture 的线程坑）

struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            // 模拟器等无相机环境：退回相册（相机权限被拒同样不影响相册路径）
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onCapture(image?.normalizedJpegData())
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
            parent.dismiss()
        }
    }
}

/// PhotosPicker 的轻封装：选完直接回调 Data
private struct PhotoLibraryPicker: View {
    let onData: (Data?) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            HStack {
                Image(systemName: "photo.on.rectangle")
                Text("选择照片")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 40)
        .presentationDetents([.medium])
        .onChange(of: item) { newItem in
            guard let newItem else { return }
            Task {
                // loadTransferable 返回 Data?，try? 再包一层需双重解开
                let loaded = (try? await newItem.loadTransferable(type: Data.self)) ?? nil
                onData(loaded)
                item = nil
            }
        }
    }
}

extension UIImage {
    /// 相机原图 → JPEG（EXIF 方向由管线统一处理一次）
    func normalizedJpegData() -> Data? {
        jpegData(compressionQuality: 0.92)
    }
}
