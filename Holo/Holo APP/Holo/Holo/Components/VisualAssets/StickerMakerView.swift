//
//  StickerMakerView.swift
//  Holo
//
//  统一外观选择器（2026-11-17 交互重设计 · ios-design 方案 · 东林拍板立即生效）：
//  一个弹层回答三件事——现在用的是什么、从哪来新图（拍/相册/文件/复用）、确认能不能用。
//  - picking 阶段=选择器：当前外观卡 + 三入口 + 「最近使用/我的贴纸」网格
//  - 确认页（同弹层换相）：模式分段 + 贴纸/原图对照 + 纸边三档×厚度 + 重新裁剪 + 修边 + 换一张
//  - 回执语义：选择器不绑业务对象——onPick(assetID) 给调用方；
//    编辑场景调用方立即 applyPlacement（立即生效），新增场景暂存 draft 随保存绑定
//  - 透明 PNG 导入不二次抠图；无主体给「裁近重试/换一张/改用照片」出口，不卡死
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
        case picking
        case acquiring
        case processing
        case editing
        case committing
        case failed(StickerMakerFailure)
    }

    enum StickerMakerFailure: Equatable {
        case noSubjectFound
        case requestFailed
        case tooLarge
        case corrupted
        case saveFailed
    }

    enum Mode: String, CaseIterable {
        case sticker = "贴纸"
        case photo = "照片"
    }

    @Published var phase: Phase = .picking
    @Published var mode: Mode
    @Published var showOriginal = false
    @Published var borderStyle: VisualPlacementPayload.Presentation.BorderStyle = .adaptivePaper
    @Published var borderWeight: VisualPlacementPayload.Presentation.BorderWeight = .standard
    @Published var libraryAssets: [VisualAsset] = []

    private(set) var workingImage: VisualWorkingImage?
    private(set) var occupancyMask: CVPixelBuffer?
    private(set) var instanceCount = 1

    /// 修边真源：基线遮罩 + 笔画历史（撤销=重放）
    private var baselineMask: CVPixelBuffer?
    private var strokes: [(points: [CGPoint], erase: Bool, brush: CGFloat)] = []

    init(initialMode: Mode = .sticker) {
        mode = initialMode
    }

    // MARK: - 素材网格

    func reloadLibrary(tab: VisualAssetLibraryView.Tab) {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        switch tab {
        case .recent:
            request.sortDescriptors = [NSSortDescriptor(key: "metadataUpdatedAt", ascending: false)]
            request.fetchLimit = 30
        case .all, .favorite:
            if case .favorite = tab {
                request.predicate = NSPredicate(format: "libraryVisibility == %@ AND isFavorite == YES", "visible")
            }
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        }
        libraryAssets = (try? context.fetch(request)) ?? []
    }

    // MARK: - 输入接管

    func ingest(data: Data) async {
        phase = .acquiring
        do {
            let working = try VisualAssetImageProcessor.prepareWorkingImage(from: data)
            workingImage = working
            baselineMask = nil
            strokes = []
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

    func ingestTransparentPNG(data: Data) async {
        phase = .acquiring
        do {
            let working = try VisualAssetImageProcessor.prepareWorkingImage(from: data)
            guard working.hasAlpha else {
                await ingest(data: data)
                return
            }
            workingImage = working
            occupancyMask = VisualAssetImageProcessor.occupancyMask(fromAlphaOf: working.cgImage)
            baselineMask = copyMask(occupancyMask)
            strokes = []
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
            baselineMask = copyMask(occupancyMask)
            strokes = []
            instanceCount = result.instanceIndices.count
            phase = .editing
        } catch SubjectExtractionError.noSubjectFound {
            phase = .failed(.noSubjectFound)
        } catch {
            phase = .failed(.requestFailed)
        }
    }

    func fallBackToPhoto() {
        mode = .photo
        occupancyMask = nil
        if workingImage != nil { phase = .editing }
    }

    func backToPicker() {
        phase = .picking
        reloadLibrary(tab: .recent)
    }

    // MARK: - 重新裁剪

    func recrop(normalizedRect: CGRect) async {
        guard let working = workingImage else { return }
        let px = CGRect(x: normalizedRect.minX * CGFloat(working.width),
                        y: normalizedRect.minY * CGFloat(working.height),
                        width: normalizedRect.width * CGFloat(working.width),
                        height: normalizedRect.height * CGFloat(working.height))
            .integral
        guard px.width >= 40, px.height >= 40,
              let cropped = working.cgImage.cropping(to: px) else { return }
        let newWorking = VisualWorkingImage(cgImage: cropped, hasAlpha: working.hasAlpha)
        workingImage = newWorking
        if mode == .sticker {
            await extractSubject(from: newWorking)
        } else {
            occupancyMask = nil
            phase = .editing
        }
    }

    // MARK: - 修边

    func applyStroke(_ points: [CGPoint], erase: Bool, brush: CGFloat) {
        guard var mask = occupancyMask, let working = workingImage else { return }
        strokes.append((points, erase, brush))
        Self.paint(points: points, erase: erase, brush: brush,
                   on: mask, width: working.width, height: working.height)
        occupancyMask = mask
    }

    func undoStroke() {
        guard let mask = occupancyMask, let baseline = baselineMask, let working = workingImage else { return }
        strokes.removeLast()
        copyInto(baseline, mask)
        for stroke in strokes {
            Self.paint(points: stroke.points, erase: stroke.erase, brush: stroke.brush,
                       on: mask, width: working.width, height: working.height)
        }
        occupancyMask = mask
    }

    func resetMask() {
        guard let mask = occupancyMask, let baseline = baselineMask else { return }
        copyInto(baseline, mask)
        strokes = []
        occupancyMask = mask
    }

    static func paint(points: [CGPoint], erase: Bool, brush: CGFloat,
                      on mask: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(mask, [])
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?
            .assumingMemoryBound(to: UInt8.self) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let radius = max(2, Int(brush * CGFloat(width) / 2))
        for p in points {
            let cx = Int(p.x * CGFloat(width))
            let cy = Int(p.y * CGFloat(height))
            for dy in -radius...radius {
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    base[y * rowBytes + x] = erase ? 0 : 255
                }
            }
        }
    }

    private func copyMask(_ source: CVPixelBuffer?) -> CVPixelBuffer? {
        guard let source else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                            kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let copy = buffer else { return nil }
        copyInto(source, copy)
        return copy
    }

    private func copyInto(_ source: CVPixelBuffer, _ target: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, [])
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(source, [])
        }
        guard let sb = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
              let tb = CVPixelBufferGetBaseAddress(target)?.assumingMemoryBound(to: UInt8.self) else { return }
        let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(target))
        let sRow = CVPixelBufferGetBytesPerRow(source)
        let tRow = CVPixelBufferGetBytesPerRow(target)
        let cols = min(sRow, tRow)
        for y in 0..<rows {
            memcpy(tb + y * tRow, sb + y * sRow, cols)
        }
    }

    // MARK: - 预览

    func previewImage() -> CGImage? {
        guard let working = workingImage else { return nil }
        if mode == .photo { return working.cgImage }
        guard let mask = occupancyMask else { return nil }
        return StickerRenderer.renderDisplayImageForPreview(
            subject: working.cgImage, mask: mask,
            presentation: .init(borderStyle: borderStyle, borderWeight: borderWeight))
    }

    func originalPreview() -> CGImage? {
        workingImage?.cgImage
    }

    // MARK: - 提交（素材入库，绑定由调用方收口）

    func commit() async -> UUID? {
        guard let working = workingImage else { return nil }
        phase = .committing
        let operationID = UUID()
        let kind: VisualAssetKind = mode == .sticker ? .sticker : .photo
        let mask = mode == .sticker ? occupancyMask : nil
        do {
            let receipt = try await VisualCommitCoordinator.shared.commit(
                .createAssetOnly(operationID: operationID) { asset in
                    Self.fill(asset: asset, kind: kind, working: working, mask: mask)
                }, in: CoreDataStack.shared.persistentContainer)
            phase = .editing
            return receipt.assetID
        } catch {
            phase = .failed(.saveFailed)
            return nil
        }
    }

    static func fill(asset: VisualAsset, kind: VisualAssetKind,
                     working: VisualWorkingImage, mask: CVPixelBuffer?) {
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
            if let tight = VisualAssetImageProcessor.tightCrop(working.cgImage, mask: mask, maxLongest: 1536),
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
        asset.setValue(kind == .sticker ? "visible" : "recordOnly", forKey: "libraryVisibility")
    }
}

// MARK: - 统一外观选择器视图

struct StickerMakerView: View {
    @StateObject private var model: StickerMakerModel
    let onPick: (UUID, VisualPlacementPayload.Presentation?) -> Void
    var pickerTitle: String = String(localized: "外观")
    var currentPlacement: ResolvedPlacement? = nil
    var fallbackIcon: String = "bag.fill"
    var inUseAssetID: UUID? = nil
    var onRestoreDefault: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showDocument = false
    @State private var showCrop = false
    @State private var showBrush = false
    @State private var libraryTab: VisualAssetLibraryView.Tab = .recent
    @State private var selectedAssetID: UUID?
    @State private var previewRev = 0

    init(initialMode: StickerMakerModel.Mode = .sticker,
         pickerTitle: String = String(localized: "外观"),
         currentPlacement: ResolvedPlacement? = nil,
         fallbackIcon: String = "bag.fill",
         inUseAssetID: UUID? = nil,
         onRestoreDefault: (() -> Void)? = nil,
         onPick: @escaping (UUID, VisualPlacementPayload.Presentation?) -> Void) {
        _model = StateObject(wrappedValue: StickerMakerModel(initialMode: initialMode))
        self.pickerTitle = pickerTitle
        self.currentPlacement = currentPlacement
        self.fallbackIcon = fallbackIcon
        self.inUseAssetID = inUseAssetID
        self.onRestoreDefault = onRestoreDefault
        self.onPick = onPick
    }

    var body: some View {
        HoloSheetScaffold(title: scaffoldTitle,
                          onClose: { dismiss() },
                          primaryTitle: primaryTitle,
                          primaryAction: primaryAction,
                          primaryDisabled: primaryDisabled,
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
        .sheet(isPresented: $showCrop) {
            if let image = model.originalPreview() {
                StickerCropView(image: image,
                                onCancel: { showCrop = false }) { rect in
                    showCrop = false
                    Task { await model.recrop(normalizedRect: rect) }
                }
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showBrush) {
            MaskBrushEditor(previewProvider: { model.previewImage() },
                            onStroke: { points, erase, brush in
                                model.applyStroke(points, erase: erase, brush: brush)
                            },
                            onUndo: { model.undoStroke() },
                            onReset: { model.resetMask() },
                            onDone: { showBrush = false },
                            onCancel: { showBrush = false })
                .presentationDetents([.large])
        }
        .onAppear { model.reloadLibrary(tab: libraryTab) }
    }

    private var scaffoldTitle: String {
        switch model.phase {
        case .editing: return model.mode == .sticker ? String(localized: "确认主体") : String(localized: "调整照片")
        default: return pickerTitle
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .picking:
            pickerContent
        case .acquiring:
            ProgressView(String(localized: "正在读取照片…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .processing:
            processingView
        case .editing:
            confirmView
        case .committing:
            ProgressView(String(localized: "正在保存…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            failureView(failure)
        }
    }

    private var pickerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let currentPlacement {
                    VisualCurrentAppearanceCard(currentPlacement: currentPlacement,
                                                fallbackIcon: fallbackIcon) {
                        onRestoreDefault?()
                        dismiss()
                    }
                }
                HStack(spacing: 10) {
                    sourceOption(icon: "camera", title: String(localized: "拍照制作"),
                                 caption: String(localized: "直接拍一件物品")) {
                        showCamera = true
                    }
                    sourceOption(icon: "photo.on.rectangle", title: String(localized: "从相册选"),
                                 caption: String(localized: "选手机里的图")) {
                        showLibrary = true
                    }
                    sourceOption(icon: "doc", title: String(localized: "从文件导入"),
                                 caption: String(localized: "支持透明 PNG")) {
                        showDocument = true
                    }
                }
                Picker(String(localized: "素材"), selection: $libraryTab) {
                    Text(String(localized: "最近使用")).tag(VisualAssetLibraryView.Tab.recent)
                    Text(String(localized: "我的贴纸")).tag(VisualAssetLibraryView.Tab.all)
                }
                .pickerStyle(.segmented)
                .onChange(of: libraryTab) { _ in model.reloadLibrary(tab: libraryTab) }

                if model.libraryAssets.isEmpty {
                    Text(String(localized: "还没有贴纸。拍一件身边的东西试试——耳机、水杯、跑鞋都行"))
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                } else {
                    VisualAssetGrid(assets: model.libraryAssets,
                                    selectedAssetID: $selectedAssetID,
                                    inUseAssetID: inUseAssetID) { _ in }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    private func sourceOption(icon: String, title: String, caption: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.holoToolAction)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.holoToolSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.holoToolBorder, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "正在提取主体…"))
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
            Button(String(localized: "取消")) {
                model.backToPicker()
            }
            .font(.system(size: 13))
            .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker(String(localized: "模式"), selection: Binding(
                    get: { model.mode }, set: { model.mode = $0 })) {
                    Text(String(localized: "贴纸")).tag(StickerMakerModel.Mode.sticker)
                    Text(String(localized: "照片")).tag(StickerMakerModel.Mode.photo)
                }
                .pickerStyle(.segmented)

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.holoToolInset)
                    if let image = model.showOriginal ? model.originalPreview() : model.previewImage() {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(14)
                            .id(previewRev)
                    }
                }
                .frame(height: 264)

                if model.mode == .sticker {
                    Picker(String(localized: "对照"), selection: Binding(
                        get: { model.showOriginal }, set: { model.showOriginal = $0 })) {
                        Text(String(localized: "贴纸（已去背景）")).tag(false)
                        Text(String(localized: "原图")).tag(true)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(String(localized: "纸边风格"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                        Picker(String(localized: "纸边"), selection: Binding(
                            get: { model.borderStyle },
                            set: { model.borderStyle = $0; previewRev += 1 })) {
                            Text(String(localized: "自适应")).tag(VisualPlacementPayload.Presentation.BorderStyle.adaptivePaper)
                            Text(String(localized: "纯白")).tag(VisualPlacementPayload.Presentation.BorderStyle.white)
                            Text(String(localized: "无")).tag(VisualPlacementPayload.Presentation.BorderStyle.none)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text(String(localized: "厚度"))
                                .font(.system(size: 11.5))
                                .foregroundColor(.holoToolTextSecondary)
                            Picker(String(localized: "厚度"), selection: Binding(
                                get: { model.borderWeight },
                                set: { model.borderWeight = $0; previewRev += 1 })) {
                                Text(String(localized: "细")).tag(VisualPlacementPayload.Presentation.BorderWeight.thin)
                                Text(String(localized: "标准")).tag(VisualPlacementPayload.Presentation.BorderWeight.standard)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    VStack(spacing: 0) {
                        confirmActionRow(icon: "crop", title: String(localized: "重新裁剪"),
                                         caption: String(localized: "裁小范围重新识别")) {
                            showCrop = true
                        }
                        Divider().padding(.leading, 40)
                        confirmActionRow(icon: "paintbrush", title: String(localized: "修边"),
                                         caption: String(localized: "擦掉多余，恢复误删")) {
                            showBrush = true
                        }
                        Divider().padding(.leading, 40)
                        confirmActionRow(icon: "arrow.counterclockwise", title: String(localized: "换一张"),
                                         caption: String(localized: "重新拍照或换一张图")) {
                            model.backToPicker()
                        }
                    }
                    .background(Color.holoToolSurface)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
        }
    }

    private func confirmActionRow(icon: String, title: String, caption: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13.5))
                        .foregroundColor(.holoToolText)
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func failureView(_ failure: StickerMakerModel.StickerMakerFailure) -> some View {
        VStack(spacing: 12) {
            switch failure {
            case .noSubjectFound:
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(.holoToolTextSecondary)
                Text(String(localized: "没有找到清晰的主体，可以拍近一点再试"))
                    .font(.system(size: 14, weight: .medium))
                Button(String(localized: "改用普通照片")) { model.fallBackToPhoto() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolAction)
            case .tooLarge:
                Text(String(localized: "这张图片太大了，换一张试试"))
                    .font(.system(size: 14))
            case .corrupted:
                Text(String(localized: "图片无法读取，可能已损坏"))
                    .font(.system(size: 14))
            case .requestFailed:
                Text(String(localized: "这张图片暂时无法自动制作贴纸"))
                    .font(.system(size: 14))
                Button(String(localized: "改用普通照片")) { model.fallBackToPhoto() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolAction)
            case .saveFailed:
                Text(String(localized: "保存没有完成，已保留当前编辑"))
                    .font(.system(size: 14))
            }
            Button(String(localized: "换一张")) { model.backToPicker() }
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primaryTitle: String? {
        switch model.phase {
        case .picking: return String(localized: "使用这张贴纸")
        case .editing: return String(localized: "使用")
        default: return nil
        }
    }

    private var primaryDisabled: Bool {
        switch model.phase {
        case .picking: return selectedAssetID == nil
        case .editing: return false
        default: return true
        }
    }

    private var primaryHint: String? {
        if case .picking = model.phase, selectedAssetID == nil {
            return String(localized: "先在下方选一张，或拍照做一张新的")
        }
        if case .editing = model.phase, model.mode == .sticker, model.instanceCount > 1 {
            return String(localized: "识别到 \(model.instanceCount) 个主体，已选全部")
        }
        return nil
    }

    private func primaryAction() {
        switch model.phase {
        case .picking:
            guard let assetID = selectedAssetID else { return }
            onPick(assetID, nil)
            dismiss()
        case .editing:
            Task {
                if let assetID = await model.commit() {
                    onPick(assetID, VisualPlacementPayload.Presentation(
                        borderStyle: model.borderStyle, borderWeight: model.borderWeight))
                    dismiss()
                }
            }
        default:
            break
        }
    }
}

// MARK: - 相机

struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

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
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onCapture(image?.jpegData(compressionQuality: 0.92))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
            parent.dismiss()
        }
    }
}

struct PhotoLibraryPicker: View {
    let onData: (Data?) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            HStack {
                Image(systemName: "photo.on.rectangle")
                Text(String(localized: "选择照片"))
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
                let loaded = (try? await newItem.loadTransferable(type: Data.self)) ?? nil
                onData(loaded)
                item = nil
            }
        }
    }
}
