//
//  StickerMakerView.swift
//  Holo
//
//  统一外观选择器（2026-11-18 全链路修复重构 · 方案 §2.2）：
//  VisualAppearancePickerView 只回答两件事——现在用的是什么、从哪来新图
//  （拍照 / 相册 / 文件 / 复用已有贴纸）；采到新图后同栈 push 进
//  StickerConfirmEditorView 做确认主体 / 裁剪 / 修边，不再叠二层 Sheet。
//  - 推入模式（isPushed: true）：嵌入调用方已有 NavigationStack（编辑表单等），零新增弹层
//  - 弹层模式（isPushed: false）：自带 NavigationStack 的单层 Sheet（详情直达等）
//  - 回执语义：选择器不绑业务对象——onPick(assetID, presentation) 给调用方收口
//  - 交互口径（东林 11-18 拍板）：表单场景草稿随「保存」统一生效；详情直达场景立即生效
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
    @Published var scale: Double = 1.0
    /// 确认页拖动贴纸的平移（pt，保存时归一化到预览框尺寸入 offsetX/Y）
    @Published var offset: CGSize = .zero
    /// 贴纸命名（确认页输入；空=存默认名「贴纸 MMDD」）
    @Published var name: String = ""
    /// 贴纸分组（确认页可选；nil=未分组）
    @Published var groupName: String? = nil
    @Published var libraryAssets: [VisualAsset] = []
    @Published var saveErrorMessage: String?

    @Published private(set) var workingImage: VisualWorkingImage?
    /// 异步预览缓存（B5 根治）：拖「大小」滑块只动 scaleEffect，零 CoreImage 重算；
    /// workingImage/mask/纸边变化由后台 Task 重算（generation 防旧结果覆盖）
    @Published private(set) var renderedPreview: CGImage?
    @Published private(set) var isRenderingPreview = false
    /// 预览输入版本号：素材/遮罩变化时 +1，确认页据此触发一次异步重算
    @Published private(set) var previewInputsStamp = 0

    private(set) var occupancyMask: CVPixelBuffer?
    private(set) var instanceCount = 1
    private var previewGeneration = 0

    /// 修边真源：基线遮罩 + 笔画历史（撤销=重放）
    private var baselineMask: CVPixelBuffer?
    private var strokes: [(points: [CGPoint], erase: Bool, brush: CGFloat)] = []

    /// 编辑模式目标（「编辑贴纸」原地更新；nil=新建另存）
    var editTargetAssetID: UUID?
    /// 编辑时保留的原图字节（commit 后回写 sourceData：原图是「重新制作」重抠的唯一通道，
    /// 不能被紧裁主体覆盖——11-19 东林实报「编辑把抠图干没了」的对偶防线）
    var preservedSource: (data: Data, utType: String)?

    init(initialMode: Mode = .sticker) {
        mode = initialMode
    }

    // MARK: - 素材网格

    func reloadLibrary(tab: VisualAssetLibraryView.Tab) {
        let filter: VisualAssetFilter
        switch tab {
        case .recent: filter = .recent
        case .all: filter = .all
        case .favorite: filter = .favorite
        }
        reloadLibrary(filter: filter, searchText: "")
    }

    func reloadLibrary(filter: VisualAssetFilter, searchText: String) {
        libraryAssets = VisualAssetGroupStore.fetchAssets(
            filter: filter, searchText: searchText, in: CoreDataStack.shared.viewContext)
    }

    func resetTransform() {
        scale = 1.0
        offset = .zero
    }

    // MARK: - 输入接管

    /// 采集统一入口：透明 PNG 直通（免二次抠图），其余按模式走 Vision 提取/照片
    func ingestSmart(data: Data) async {
        if let type = VisualAssetImageProcessor.probeUTType(of: data), type.conforms(to: .png),
           let working = try? VisualAssetImageProcessor.prepareWorkingImage(from: data),
           working.hasAlpha {
            await ingestTransparentPNG(data: data)
        } else {
            await ingest(data: data)
        }
    }

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
            bumpPreviewInputs()
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
            bumpPreviewInputs()
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
            bumpPreviewInputs()
        } catch SubjectExtractionError.noSubjectFound {
            phase = .failed(.noSubjectFound)
        } catch {
            phase = .failed(.requestFailed)
        }
    }

    /// 模式切换（B8 根治）：照片 → 贴纸且遮罩缺失时自动补跑主体提取
    func switchMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .sticker, occupancyMask == nil, let working = workingImage {
            phase = .processing   // 立即反馈（提取在后台补跑）
            Task { await extractSubject(from: working) }
        } else if newMode == .photo {
            if workingImage != nil { phase = .editing }
            bumpPreviewInputs()
        }
    }

    func fallBackToPhoto() {
        mode = .photo
        occupancyMask = nil
        if workingImage != nil { phase = .editing }
        bumpPreviewInputs()
    }

    func backToPicker() {
        phase = .picking
        reloadLibrary(tab: .recent)
    }

    /// 编辑现有贴纸（正确语义 11-19 修复）：直接载入**已抠好的主体+遮罩**——
    /// 保留用户修过的形状；不走原图重跑 Vision（旧实现把抠图成果整个丢掉）。
    /// 原 sourceData 字节另行保留，commit 时回写（见 preservedSource）。
    func loadEdited(subjectData: Data, maskData: Data?) -> Bool {
        guard let subject = VisualAssetImageProcessor.decodeWorkingCGImage(from: subjectData) else {
            return false
        }
        let mask: CVPixelBuffer?
        if let maskData,
           let decoded = VisualAssetImageProcessor.decodeMask(from: maskData,
                                                              width: subject.width,
                                                              height: subject.height),
           CVPixelBufferGetWidth(decoded) == subject.width,
           CVPixelBufferGetHeight(decoded) == subject.height {
            mask = decoded
        } else {
            // 遮罩缺失/尺寸不符：按主体 alpha 重建（紧裁主体通常全占用，等价无损）
            mask = VisualAssetImageProcessor.occupancyMask(fromAlphaOf: subject)
        }
        loadEdited(subject: subject, mask: mask)
        return true
    }

    /// 缓冲直入版（测试/内存态调用）：载入已抠好的主体与遮罩，立即进入编辑态
    func loadEdited(subject: CGImage, mask: CVPixelBuffer?) {
        workingImage = VisualWorkingImage(cgImage: subject, hasAlpha: true)
        occupancyMask = mask
        baselineMask = copyMask(mask)
        strokes = []
        mode = .sticker
        phase = .editing
        bumpPreviewInputs()
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
            bumpPreviewInputs()
        }
    }

    // MARK: - 修边

    func applyStroke(_ points: [CGPoint], erase: Bool, brush: CGFloat) {
        guard var mask = occupancyMask, let working = workingImage else { return }
        strokes.append((points, erase, brush))
        Self.paint(points: points, erase: erase, brush: brush,
                   on: mask, width: working.width, height: working.height)
        occupancyMask = mask
        bumpPreviewInputs()
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
        bumpPreviewInputs()
    }

    func resetMask() {
        guard let mask = occupancyMask, let baseline = baselineMask else { return }
        copyInto(baseline, mask)
        strokes = []
        occupancyMask = mask
        bumpPreviewInputs()
    }

    // MARK: - 修边会话快照（取消回滚，B6）

    struct MaskSessionSnapshot {
        let mask: CVPixelBuffer
        let baseline: CVPixelBuffer
        let strokes: [(points: [CGPoint], erase: Bool, brush: CGFloat)]
    }

    func snapshotMaskSession() -> MaskSessionSnapshot? {
        guard let mask = occupancyMask, let baseline = baselineMask,
              let maskCopy = copyMask(mask) else { return nil }
        return MaskSessionSnapshot(mask: maskCopy, baseline: baseline, strokes: strokes)
    }

    /// 取消修边：整段回滚到进入前的遮罩/笔画状态
    func restoreMaskSession(_ snapshot: MaskSessionSnapshot) {
        occupancyMask = snapshot.mask
        baselineMask = snapshot.baseline
        strokes = snapshot.strokes
        bumpPreviewInputs()
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
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
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

    // MARK: - 预览（异步缓存，B5/B6 根治）

    private func bumpPreviewInputs() {
        previewInputsStamp += 1
    }

    /// 确认页异步预览：捕获值快照 → 后台 ≤960px 合成；generation 序号防旧结果覆盖
    func schedulePreviewRender() {
        previewGeneration += 1
        let generation = previewGeneration
        guard let working = workingImage else {
            renderedPreview = nil
            return
        }
        let subject = working.cgImage
        let mask = mode == .sticker ? occupancyMask : nil
        let style = borderStyle
        let weight = borderWeight
        isRenderingPreview = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let image: CGImage? = Self.composePreview(subject: subject, mask: mask,
                                                      style: style, weight: weight)
            await MainActor.run {
                guard let self, self.previewGeneration == generation else { return }
                self.renderedPreview = image
                self.isRenderingPreview = false
            }
        }
    }

    /// 修边页重算预览：松手/撤销/重置后各调一次（拖动中绝不调用）
    func renderPreviewAsync() async -> CGImage? {
        guard let working = workingImage else { return nil }
        let subject = working.cgImage
        let mask = mode == .sticker ? occupancyMask : nil
        let style = borderStyle
        let weight = borderWeight
        return await Task.detached(priority: .userInitiated) {
            Self.composePreview(subject: subject, mask: mask, style: style, weight: weight)
        }.value
    }

    nonisolated private static func composePreview(subject: CGImage, mask: CVPixelBuffer?,
                                       style: VisualPlacementPayload.Presentation.BorderStyle,
                                       weight: VisualPlacementPayload.Presentation.BorderWeight) -> CGImage? {
        if let mask {
            return StickerRenderer.renderConfirmPreview(
                subject: subject, mask: mask,
                presentation: .init(borderStyle: style, borderWeight: weight))
        }
        // 照片模式：直接降采样显示原图
        return VisualAssetImageProcessor.downscale(subject, targetLongest: 960)
    }

    func originalPreview() -> CGImage? {
        workingImage?.cgImage
    }

    // MARK: - 提交（素材入库，绑定由调用方收口）

    func commit() async -> UUID? {
        guard let working = workingImage else {
            saveErrorMessage = String(localized: "未找到可保存的图片")
            phase = .failed(.saveFailed)
            return nil
        }
        if mode == .sticker && occupancyMask == nil {
            saveErrorMessage = String(localized: "贴纸遮罩尚未就绪，请重试")
            phase = .failed(.saveFailed)
            return nil
        }
        saveErrorMessage = nil
        phase = .committing
        let operationID = UUID()
        let kind: VisualAssetKind = mode == .sticker ? .sticker : .photo
        let mask = mode == .sticker ? occupancyMask : nil
        do {
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetGroup = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedBorderStyle = borderStyle
            let savedBorderWeight = borderWeight
            let preserved = preservedSource
            let assign: (VisualAsset) -> Void = { asset in
                Self.fill(asset: asset, kind: kind, working: working, mask: mask)
                if !displayName.isEmpty {
                    asset.setValue(displayName, forKey: "displayName")
                }
                // 资产级默认纸边与分组存入 transformJSON（零 Schema 改动、CloudKit 自动同步）
                var meta = asset.visualMetadata
                meta.groupName = (targetGroup?.isEmpty == false) ? targetGroup : nil
                if kind == .sticker {
                    meta.defaultBorderStyle = savedBorderStyle.rawValue
                    meta.defaultBorderWeight = savedBorderWeight.rawValue
                }
                asset.visualMetadata = meta
                asset.setValue(Date(), forKey: "metadataUpdatedAt")
                // 编辑模式：原图字节回写（fill 存的是紧裁主体；sourceWidth/Height 保持
                // 紧裁尺寸与 mask 对齐，渲染主路径走 contentData 不受影响）
                if let preserved {
                    asset.setValue(preserved.data, forKey: "sourceData")
                    asset.setValue(preserved.utType, forKey: "sourceUTType")
                    asset.setValue(VisualAssetDraftStore.sha256(preserved.data), forKey: "sourceHash")
                }
            }
            let command: VisualCommitCommand
            if let editID = editTargetAssetID {
                command = .updateAsset(operationID: operationID, assetID: editID, assignAsset: assign)
            } else {
                command = .createAssetOnly(operationID: operationID, assignAsset: assign)
            }
            let receipt = try await VisualCommitCoordinator.shared.commit(
                command, in: CoreDataStack.shared.persistentContainer)
            phase = .editing
            return receipt.assetID
        } catch {
            saveErrorMessage = error.localizedDescription
            phase = .failed(.saveFailed)
            return nil
        }
    }

    static func fill(asset: VisualAsset, kind: VisualAssetKind,
                     working: VisualWorkingImage, mask: CVPixelBuffer?) {
        asset.setValue(kind.rawValue, forKey: "kind")
        asset.setValue(kind == .sticker ? "visible" : "recordOnly", forKey: "libraryVisibility")
        guard let sourcePNG = VisualAssetImageProcessor.encodePNG(working.cgImage) else { return }
        asset.setValue(sourcePNG, forKey: "sourceData")
        asset.setValue(UTType.png.identifier, forKey: "sourceUTType")
        asset.setValue(VisualAssetDraftStore.sha256(sourcePNG), forKey: "sourceHash")
        asset.setValue(working.width, forKey: "sourceWidth")
        asset.setValue(working.height, forKey: "sourceHeight")
        if kind == .sticker, let mask {
            if let tight = VisualAssetImageProcessor.tightCropWithMask(working.cgImage, mask: mask, maxLongest: 1536),
               let tightPNG = VisualAssetImageProcessor.encodePNG(tight.image),
               let tightMaskPNG = VisualAssetImageProcessor.encodeMaskPNG(tight.mask) {
                asset.setValue(tightPNG, forKey: "contentData")
                asset.setValue(UTType.png.identifier, forKey: "contentUTType")
                asset.setValue(VisualAssetDraftStore.sha256(tightPNG), forKey: "contentHash")
                asset.setValue(tight.image.width, forKey: "contentWidth")
                asset.setValue(tight.image.height, forKey: "contentHeight")
                asset.setValue(tightMaskPNG, forKey: "maskData")
                asset.setValue(VisualAssetDraftStore.sha256(tightMaskPNG), forKey: "maskHash")
            } else if let maskPNG = VisualAssetImageProcessor.encodeMaskPNG(mask) {
                asset.setValue(maskPNG, forKey: "maskData")
                asset.setValue(VisualAssetDraftStore.sha256(maskPNG), forKey: "maskHash")
            }
        }
        if let thumbPNG = VisualAssetImageProcessor.encodePNG(
            VisualAssetImageProcessor.downscale(working.cgImage, targetLongest: 320)) {
            asset.setValue(thumbPNG, forKey: "thumbnailData")
            asset.setValue(VisualAssetDraftStore.sha256(thumbPNG), forKey: "thumbnailHash")
        }
    }
}

// MARK: - 统一外观选择器（推入/弹层双态）

struct VisualAppearancePickerView: View {
    @StateObject private var model: StickerMakerModel
    /// true=嵌入调用方 NavigationStack（表单 push）；false=自带 NavigationStack 的单层 Sheet
    var isPushed: Bool = false
    let onPick: (UUID, VisualPlacementPayload.Presentation?) -> Void
    var pickerTitle: String = String(localized: "外观")
    var currentPlacement: ResolvedPlacement? = nil
    var fallbackIcon: String = "bag.fill"
    var inUseAssetID: UUID? = nil
    var onRestoreDefault: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var activeMediaSource: VisualMediaSource?
    @State private var cameraDenied = false
    @State private var libraryFilter: VisualAssetFilter = .recent
    @State private var searchText = ""
    @State private var groups: [String] = []
    @State private var selectedAssetID: UUID?
    /// 长按删除的确认目标（11-19 需求 4）
    @State private var deleteTarget: VisualAsset?
    @State private var showManageLibrary = false
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""

    init(isPushed: Bool = false,
         initialMode: StickerMakerModel.Mode = .sticker,
         pickerTitle: String = String(localized: "外观"),
         currentPlacement: ResolvedPlacement? = nil,
         fallbackIcon: String = "bag.fill",
         inUseAssetID: UUID? = nil,
         onRestoreDefault: (() -> Void)? = nil,
         onPick: @escaping (UUID, VisualPlacementPayload.Presentation?) -> Void) {
        _model = StateObject(wrappedValue: StickerMakerModel(initialMode: initialMode))
        self.isPushed = isPushed
        self.pickerTitle = pickerTitle
        self.currentPlacement = currentPlacement
        self.fallbackIcon = fallbackIcon
        self.inUseAssetID = inUseAssetID
        self.onRestoreDefault = onRestoreDefault
        self.onPick = onPick
    }

    var body: some View {
        root
            .visualMediaPresenter(activeSource: $activeMediaSource) { data in
                // 新采集=新建语义：清掉长按「编辑贴纸」的目标，防止新图覆盖旧贴纸
                model.editTargetAssetID = nil
                model.preservedSource = nil
                model.name = ""
                model.resetTransform()
                if case .group(let g) = libraryFilter {
                    model.groupName = g
                } else {
                    model.groupName = nil
                }
                await model.ingestSmart(data: data)
            }
            .alert(String(localized: "无法访问相机"),
                   isPresented: $cameraDenied) {
                Button(String(localized: "去设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "请在系统设置里允许 Holo 使用相机，或改用相册/文件导入"))
            }
            .alert(String(localized: "新建分组"), isPresented: $showNewGroupAlert) {
                TextField(String(localized: "分组名称，如：数码、咖啡"), text: $newGroupName)
                Button(String(localized: "取消"), role: .cancel) { newGroupName = "" }
                Button(String(localized: "创建")) {
                    if let created = VisualAssetGroupStore.addGroup(newGroupName) {
                        refreshLibrary()
                        libraryFilter = .group(created)
                    }
                    newGroupName = ""
                }
            }
            .alert(String(localized: "删除这张贴纸？"),
                   isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } })) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "删除"), role: .destructive) {
                    if let target = deleteTarget {
                        do {
                            try VisualAssetManagement.hardDelete(asset: target,
                                                                 in: CoreDataStack.shared.viewContext)
                            if selectedAssetID == (target.value(forKey: "id") as? UUID) {
                                selectedAssetID = nil
                            }
                        } catch {
                            HoloToastCenter.shared.show(String(localized: "删除没有完成，请重试"), type: .error)
                        }
                        deleteTarget = nil
                        refreshLibrary()
                    }
                }
            } message: {
                Text(String(localized: "正在使用这张贴纸的地方会回退到默认图标。"))
            }
            .sheet(isPresented: $showManageLibrary, onDismiss: { refreshLibrary() }) {
                VisualAssetLibraryView()
            }
            .onAppear { refreshLibrary() }
            .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
                refreshLibrary()
            }
    }

    private func refreshLibrary() {
        let context = CoreDataStack.shared.viewContext
        groups = VisualAssetGroupStore.allGroups(in: context)
        if case .group(let g) = libraryFilter, !groups.contains(g) {
            libraryFilter = .all
        }
        model.reloadLibrary(filter: libraryFilter, searchText: searchText)
    }

    /// 仅当当前位置确实已设置贴纸或正在同步时，顶部才显示「当前外观」卡（避免未设贴纸时白占一行）
    private var shouldShowCurrentCard: Bool {
        guard let currentPlacement else { return false }
        switch currentPlacement {
        case .assetReady, .pending: return true
        default: return false
        }
    }

    /// 选择器长按管理（11-19 需求 4）：编辑=载原图原地更新；删除=确认后彻底删
    private func handleManage(_ asset: VisualAsset, action: VisualAssetGrid.ManageAction) {
        switch action {
        case .edit:
            beginEditing(asset, model: model)
        case .delete:
            deleteTarget = asset
        }
    }

    /// 编辑贴纸（正确语义）：载入已抠好的主体+遮罩；回显名称、分组、默认纸边
    private func beginEditing(_ asset: VisualAsset, model: StickerMakerModel) {
        guard let assetID = asset.value(forKey: "id") as? UUID else { return }
        let subjectData = (asset.value(forKey: "contentData") as? Data)
            ?? (asset.value(forKey: "sourceData") as? Data)
        guard let subjectData, !subjectData.isEmpty else {
            HoloToastCenter.shared.show(String(localized: "这张素材没有可编辑的主体，请用「重新制作一份」"), type: .error)
            return
        }
        let loaded = model.loadEdited(subjectData: subjectData,
                                      maskData: asset.value(forKey: "maskData") as? Data)
        guard loaded else {
            HoloToastCenter.shared.show(String(localized: "贴纸内容无法读取，请用「重新制作一份」"), type: .error)
            return
        }
        model.editTargetAssetID = assetID
        model.name = (asset.value(forKey: "displayName") as? String) ?? ""
        model.groupName = asset.groupName
        let meta = asset.visualMetadata
        model.borderStyle = meta.resolvedBorderStyle ?? .adaptivePaper
        model.borderWeight = meta.resolvedBorderWeight ?? .standard
        model.resetTransform()
        if let source = asset.value(forKey: "sourceData") as? Data {
            model.preservedSource = (source, (asset.value(forKey: "sourceUTType") as? String) ?? UTType.png.identifier)
        }
    }

    /// 弹层模式自带 NavigationStack；推入模式复用调用方的栈。
    /// navigationDestination 必须挂在栈内容（pickerContent）上——挂在 NavigationStack
    /// 外层注册无效：弹层模式确认页从未推入，选完图停回首屏空态（2026-11-18 东林实报
    /// 「想法添加图片完全没有效果」的根因）
    private var root: some View {
        Group {
            if isPushed {
                pickerContent
            } else {
                NavigationStack { pickerContent }
            }
        }
    }

    /// 确认页激活 = 素材在途/处理/编辑中；系统返回手势把 phase 收回 picking
    private var confirmActive: Binding<Bool> {
        .init(get: { model.phase != .picking },
              set: { if !$0 { model.backToPicker() } })
    }

    private func finish(with assetID: UUID, presentation: VisualPlacementPayload.Presentation?) {
        onPick(assetID, presentation)
        model.backToPicker()
        // 推入模式：弹出由调用方在 onPick 回执里收 binding 驱动——在推入页上调
        // dismiss() 会与 navigationDestination 的 binding 弹出竞争，把宿主 Sheet
        // 一起关掉（2026-11-18 走查实锤：新增表单被整体关闭）；弹层模式才 dismiss
        if !isPushed { dismiss() }
    }

    // MARK: - 选择器首屏

    private var pickerContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 当前外观条：仅已有贴纸/同步中时占一行（未设贴纸不白占空间）
                    if shouldShowCurrentCard, let currentPlacement {
                        VisualCurrentAppearanceCard(currentPlacement: currentPlacement,
                                                    fallbackIcon: fallbackIcon,
                                                    compact: true) {
                            onRestoreDefault?()
                            if !isPushed { dismiss() }
                        }
                    }
                    // 一行轻量采集操作栏（把首屏主体让给贴纸网格）
                    HStack(spacing: 8) {
                        capsuleButton(icon: "camera", title: String(localized: "拍照")) { launchCamera() }
                        capsuleButton(icon: "photo.on.rectangle", title: String(localized: "相册")) {
                            launchPhotoLibrary()
                        }
                        capsuleButton(icon: "doc", title: String(localized: "文件")) {
                            activeMediaSource = .document
                        }
                    }

                    VisualAssetFilterBar(
                        searchText: $searchText,
                        filter: $libraryFilter,
                        groups: groups,
                        onAddGroup: { showNewGroupAlert = true }
                    )
                    .onChange(of: libraryFilter) { _ in refreshLibrary() }
                    .onChange(of: searchText) { _ in refreshLibrary() }

                    if model.libraryAssets.isEmpty {
                        Text(pickerEmptyMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .padding(.top, 8)
                    } else {
                        VisualAssetGrid(assets: model.libraryAssets,
                                        selectedAssetID: $selectedAssetID,
                                        inUseAssetID: inUseAssetID,
                                        onPick: { _ in },
                                        onManage: { asset, action in
                                            handleManage(asset, action: action)
                                        })
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
        .background(Color.holoToolBackground)
        // 栈内注册确认页目的地（弹层/推入两态都走这里，见 root 注释）
        .navigationDestination(isPresented: confirmActive) {
            StickerConfirmEditorView(model: model,
                                     useTitle: String(localized: "使用这张贴纸"),
                                     onChangeImage: { model.backToPicker() }) { assetID, presentation in
                finish(with: assetID, presentation: presentation)
            }
        }
        .navigationTitle(pickerTitle)
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !isPushed {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "管理")) {
                    showManageLibrary = true
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                guard let assetID = selectedAssetID else { return }
                let pickedAsset = model.libraryAssets.first { ($0.value(forKey: "id") as? UUID) == assetID }
                finish(with: assetID, presentation: pickedAsset?.defaultPresentation)
            } label: {
                Text(String(localized: "使用这张贴纸"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selectedAssetID == nil ? .holoToolTextSecondary : .holoToolOnAction)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(selectedAssetID == nil ? Color.holoToolSurface : Color.holoToolAction)
                    .cornerRadius(13)
            }
            .disabled(selectedAssetID == nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var pickerEmptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "没有找到匹配的贴纸，换个关键词试试")
        }
        switch libraryFilter {
        case .favorite:
            return String(localized: "还没有收藏的贴纸")
        case .group(let name):
            return String(localized: "「\(name)」分组还没有贴纸，拍一张或从「管理」里移入")
        default:
            return String(localized: "还没有贴纸。拍一件身边的东西试试——耳机、水杯、跑鞋都行")
        }
    }

    private func capsuleButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundColor(.holoToolAction)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color.holoToolSurface)
            .cornerRadius(11)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.holoToolBorder, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func launchCamera() {
        Task {
            if await VisualMediaAcquisition.requestCameraAccess() {
                activeMediaSource = .camera
            } else {
                cameraDenied = true
            }
        }
    }

    /// 相册入口：读取权限一次性前置（iCloud 原图渐进下载的前提，想法模块同款）；
    /// 被拒不阻断——选择器传输通道兜底，只是 iCloud 图无法自动下载
    private func launchPhotoLibrary() {
        Task {
            await PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()
            activeMediaSource = .photoLibrary
        }
    }
}
