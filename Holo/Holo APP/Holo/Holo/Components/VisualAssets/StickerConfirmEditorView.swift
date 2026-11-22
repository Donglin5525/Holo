//
//  StickerConfirmEditorView.swift
//  Holo
//
//  制作/确认主体页（2026-11-18 全链路修复 · 方案 §2.2.2）：
//  从外观选择器或「我的贴纸」采集到新图后，在同一个 NavigationStack 内 push 进本页，
//  完成模式确认 / 大小 / 纸边 / 重新裁剪 / 修边——不再叠二层 Sheet。
//  - 异步预览缓存（B5 根治）：workingImage/mask/纸边变化由后台 Task 重算 ≤960px 预览，
//    generation 序号防旧结果覆盖；拖「大小」滑块只动 scaleEffect，零 CoreImage 重算
//  - 模式切换（B8 根治）：照片 → 贴纸且遮罩缺失时自动补跑主体提取；
//    纸边「无」时隐藏「厚度」行
//  - 裁剪/修边走栈内 push（StickerCropView / MaskBrushEditor）
//  - 主按钮文案按场景：表单/详情=「使用这张贴纸」；素材库=「保存到我的贴纸」
//

import SwiftUI

struct StickerConfirmEditorView: View {
    @ObservedObject var model: StickerMakerModel
    /// 底部主按钮文案（场景差异）
    var useTitle: String = String(localized: "使用这张贴纸")
    /// 是否支持照片模式（素材库场景传 false：photo 素材 recordOnly 不进「我的贴纸」
    /// 列表，「保存到我的贴纸」与照片模式语义冲突，收掉照片分支）
    var supportsPhotoMode: Bool = true
    /// 是否允许调整具体使用位置的平移/缩放（素材库模式传 false，避免「调了但素材库不存位置」的假控件感）
    var allowsPositionAdjust: Bool = true
    /// 「换一张」入口（nil=隐藏；选择器场景传 backToPicker，素材库场景隐藏）
    var onChangeImage: (() -> Void)? = nil
    /// 确认使用：回执 (assetID, presentation)，页面关闭由调用方收口
    let onUse: (UUID, VisualPlacementPayload.Presentation) -> Void

    @State private var showCrop = false
    @State private var showBrush = false
    @State private var brushSnapshot: StickerMakerModel.MaskSessionSnapshot?
    /// 拖动/捏合的基线（手势 translation/magnification 是从起点的总量，基线+增量合成）
    @State private var dragBase: CGSize = .zero
    @State private var pinchBase: CGFloat = 1
    /// 预览框尺寸（保存时把拖动 pt 归一化成 offsetX/Y 的分母）
    @State private var previewSize: CGSize = .zero
    @State private var availableGroups: [String] = []
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""

    var body: some View {
        Group {
            switch model.phase {
            case .acquiring:
                ProgressView(String(localized: "正在读取照片…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .processing:
                processingView
            case .editing:
                editorContent
            case .committing:
                ProgressView(String(localized: "正在保存…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let failure):
                failureView(failure)
            case .picking:
                // 选择器场景被外部收口时的瞬时态：保持空白等待 pop
                Color.clear
            }
        }
        .background(Color.holoToolBackground)
        .navigationTitle(model.mode == .sticker && model.phase == .editing
                         ? String(localized: "确认主体")
                         : String(localized: "调整照片"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(isPresented: $showCrop) {
            if let image = model.originalPreview() {
                StickerCropView(
                    image: image,
                    confirmTitle: model.mode == .sticker
                        ? String(localized: "重新识别")
                        : String(localized: "完成裁剪")
                ) { rect in
                    showCrop = false
                    model.resetTransform()
                    dragBase = .zero
                    pinchBase = 1
                    Task { await model.recrop(normalizedRect: rect) }
                }
            }
        }
        .navigationDestination(isPresented: $showBrush) {
            MaskBrushEditor(
                imagePixelSize: brushCanvasSize,
                originalImage: model.originalPreview(),
                refreshPreview: { await model.renderPreviewAsync() },
                onStroke: { points, erase, brush in
                    model.applyStroke(points, erase: erase, brush: brush)
                },
                onUndo: { model.undoStroke() },
                onReset: { model.resetMask() },
                onDone: { showBrush = false },
                onCancel: {
                    if let snapshot = brushSnapshot {
                        model.restoreMaskSession(snapshot)
                    }
                    showBrush = false
                })
        }
        .alert(String(localized: "新建分组"), isPresented: $showNewGroupAlert) {
            TextField(String(localized: "分组名称，如：数码、咖啡"), text: $newGroupName)
            Button(String(localized: "取消"), role: .cancel) { newGroupName = "" }
            Button(String(localized: "创建")) {
                if let created = VisualAssetGroupStore.addGroup(newGroupName) {
                    availableGroups = VisualAssetGroupStore.allGroups(in: CoreDataStack.shared.viewContext)
                    model.groupName = created
                }
                newGroupName = ""
            }
        }
        .onAppear {
            availableGroups = VisualAssetGroupStore.allGroups(in: CoreDataStack.shared.viewContext)
            dragBase = model.offset
            pinchBase = model.scale
            model.schedulePreviewRender()
        }
        .onChange(of: model.previewInputsStamp) { _ in model.schedulePreviewRender() }
        .onChange(of: model.borderStyle) { _ in model.schedulePreviewRender() }
        .onChange(of: model.borderWeight) { _ in model.schedulePreviewRender() }
        .onChange(of: model.showOriginal) { _ in }
    }

    /// 修边画布几何真源：工作图像素尺寸（mask 与工作图同尺寸）
    private var brushCanvasSize: CGSize {
        if let working = model.originalPreview() {
            return CGSize(width: working.width, height: working.height)
        }
        return .zero
    }

    // MARK: - 处理中

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "正在提取主体…"))
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 编辑主体

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if supportsPhotoMode {
                    Picker(String(localized: "模式"), selection: Binding(
                        get: { model.mode }, set: { model.switchMode($0) })) {
                        Text(String(localized: "贴纸")).tag(StickerMakerModel.Mode.sticker)
                        Text(String(localized: "照片")).tag(StickerMakerModel.Mode.photo)
                    }
                    .pickerStyle(.segmented)
                }

                previewCanvas

                // 轻量横向工具条：裁剪 / 修边 / 换一张（替代旧三行大列表，把一屏空间还给预览与核心属性）
                HStack(spacing: 8) {
                    toolChip(icon: "crop", title: String(localized: "重新裁剪")) {
                        showCrop = true
                    }
                    if model.mode == .sticker {
                        toolChip(icon: "paintbrush", title: String(localized: "修边")) {
                            brushSnapshot = model.snapshotMaskSession()
                            showBrush = true
                        }
                    }
                    if let onChangeImage {
                        toolChip(icon: "arrow.counterclockwise", title: String(localized: "换一张")) {
                            onChangeImage()
                        }
                    }
                }

                // 大小调整（仅业务位置使用场景展示；纯 scaleEffect 60fps，且与双指捏合基线同步）
                if allowsPositionAdjust {
                    HStack(spacing: 10) {
                        Text(String(localized: "大小"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                        Slider(value: Binding(
                            get: { model.scale },
                            set: {
                                model.scale = $0
                                pinchBase = $0
                            }
                        ), in: 0.6...1.2, step: 0.05)
                        .tint(.holoToolAction)
                        Text("\(Int((model.scale * 100).rounded()))%")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.holoToolSurface)
                    .cornerRadius(12)
                }

                // 名称 + 分组卡片（贴纸模式支持分组，照片模式仅提示）
                if model.mode == .sticker {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text(String(localized: "名称"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(width: 36, alignment: .leading)
                            TextField(String(localized: "不填自动按日期命名"), text: $model.name)
                                .font(.system(size: 13.5))
                                .foregroundColor(.holoToolText)
                                .textFieldStyle(.plain)
                                .submitLabel(.done)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        Divider().padding(.leading, 14)

                        HStack(spacing: 10) {
                            Text(String(localized: "分组"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(width: 36, alignment: .leading)
                            Menu {
                                Button {
                                    model.groupName = nil
                                } label: {
                                    if model.groupName == nil {
                                        Label(String(localized: "未分组"), systemImage: "checkmark")
                                    } else {
                                        Text(String(localized: "未分组"))
                                    }
                                }
                                if !availableGroups.isEmpty {
                                    Divider()
                                    ForEach(availableGroups, id: \.self) { group in
                                        Button {
                                            model.groupName = group
                                        } label: {
                                            if model.groupName == group {
                                                Label(group, systemImage: "checkmark")
                                            } else {
                                                Text(group)
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    showNewGroupAlert = true
                                } label: {
                                    Label(String(localized: "新建分组…"), systemImage: "plus")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(model.groupName ?? String(localized: "未分组"))
                                        .font(.system(size: 13.5))
                                        .foregroundColor(model.groupName == nil ? .holoToolTextSecondary : .holoToolText)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.holoToolTextSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .background(Color.holoToolSurface)
                    .cornerRadius(12)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(String(localized: "纸边风格"))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                            Spacer()
                            if model.instanceCount > 1 {
                                Text(String(localized: "已识别 \(model.instanceCount) 个主体"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoToolTextSecondary)
                            }
                        }
                        Picker(String(localized: "纸边"), selection: $model.borderStyle) {
                            Text(String(localized: "自适应")).tag(VisualPlacementPayload.Presentation.BorderStyle.adaptivePaper)
                            Text(String(localized: "纯白")).tag(VisualPlacementPayload.Presentation.BorderStyle.white)
                            Text(String(localized: "无")).tag(VisualPlacementPayload.Presentation.BorderStyle.none)
                        }
                        .pickerStyle(.segmented)
                        // 纸边「无」时厚度无意义，隐藏该行（B8）
                        if model.borderStyle != .none {
                            HStack(spacing: 10) {
                                Text(String(localized: "厚度"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.holoToolTextSecondary)
                                Picker(String(localized: "厚度"), selection: $model.borderWeight) {
                                    Text(String(localized: "细")).tag(VisualPlacementPayload.Presentation.BorderWeight.thin)
                                    Text(String(localized: "标准")).tag(VisualPlacementPayload.Presentation.BorderWeight.standard)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.holoToolSurface)
                    .cornerRadius(12)
                } else {
                    Text(String(localized: "照片仅用于当前位置，不存入「我的贴纸」"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    if let assetID = await model.commit() {
                        onUse(assetID, buildPresentation())
                    }
                }
            } label: {
                Text(editButtonTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoToolOnAction)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.holoToolAction)
                    .cornerRadius(13)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var previewCanvas: some View {
        let hasTransform = abs(model.scale - 1.0) > 0.01
            || abs(model.offset.width) > 1
            || abs(model.offset.height) > 1
        let base = ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.holoToolInset)
            if model.showOriginal, let original = model.originalPreview() {
                Image(uiImage: UIImage(cgImage: original))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(allowsPositionAdjust ? model.scale : 1.0)
                    .offset(allowsPositionAdjust ? model.offset : .zero)
                    .padding(14)
            } else if let preview = model.renderedPreview {
                Image(uiImage: UIImage(cgImage: preview))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(allowsPositionAdjust ? model.scale : 1.0)
                    .offset(allowsPositionAdjust ? model.offset : .zero)
                    .padding(14)
            } else if model.isRenderingPreview {
                ProgressView()
            }
        }
        .frame(height: 256)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background {
            GeometryReader { g in
                Color.clear.onAppear { previewSize = g.size }
                    .onChange(of: g.size) { previewSize = $0 }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.mode == .sticker {
                Button {
                    model.showOriginal.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.showOriginal ? "smallcircle.filled.circle" : "eye")
                            .font(.system(size: 11, weight: .medium))
                        Text(model.showOriginal ? String(localized: "看贴纸") : String(localized: "看原图"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if allowsPositionAdjust && hasTransform {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        model.resetTransform()
                        dragBase = .zero
                        pinchBase = 1
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(String(localized: "复位"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }

        if allowsPositionAdjust {
            base
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            model.offset = clampOffset(CGSize(width: dragBase.width + value.translation.width,
                                                              height: dragBase.height + value.translation.height))
                        }
                        .onEnded { _ in dragBase = model.offset }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            model.scale = min(max(pinchBase * value, 0.6), 1.2)
                        }
                        .onEnded { _ in pinchBase = model.scale }
                )
        } else {
            base
        }
    }

    private func toolChip(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundColor(.holoToolText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color.holoToolSurface)
            .cornerRadius(11)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.holoToolBorder, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    /// 保存时的 presentation：缩放/纸边 + 拖动位移归一化（预览框尺寸为分母，±0.5 clamp）
    private func buildPresentation() -> VisualPlacementPayload.Presentation {
        let w = max(previewSize.width, 1), h = max(previewSize.height, 1)
        return VisualPlacementPayload.Presentation(
            scale: allowsPositionAdjust ? model.scale : 1.0,
            offsetX: allowsPositionAdjust ? min(max(model.offset.width / w, -0.5), 0.5) : 0,
            offsetY: allowsPositionAdjust ? min(max(model.offset.height / h, -0.5), 0.5) : 0,
            borderStyle: model.borderStyle,
            borderWeight: model.borderWeight)
    }

    /// 拖动范围 clamp（预览框内自由移动，±框半宽/半高）
    private func clampOffset(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, -previewSize.width / 2), previewSize.width / 2),
               height: min(max(size.height, -previewSize.height / 2), previewSize.height / 2))
    }

    /// 编辑模式用「保存修改」，照片模式用「使用这张照片」，其余按场景文案
    private var editButtonTitle: String {
        if model.editTargetAssetID != nil { return String(localized: "保存修改") }
        if model.mode == .photo { return String(localized: "使用这张照片") }
        return useTitle
    }

    // MARK: - 失败出口（不卡死）

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
                if supportsPhotoMode {
                    Button(String(localized: "改用普通照片")) { model.fallBackToPhoto() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoToolAction)
                }
            case .tooLarge:
                Text(String(localized: "这张图片太大了，换一张试试"))
                    .font(.system(size: 14))
            case .corrupted:
                Text(String(localized: "图片无法读取，可能已损坏"))
                    .font(.system(size: 14))
            case .requestFailed:
                Text(String(localized: "这张图片暂时无法自动制作贴纸"))
                    .font(.system(size: 14))
                if supportsPhotoMode {
                    Button(String(localized: "改用普通照片")) { model.fallBackToPhoto() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoToolAction)
                }
            case .saveFailed:
                Text(String(localized: "保存没有完成，已保留当前编辑"))
                    .font(.system(size: 14))
                if let detail = model.saveErrorMessage, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button(String(localized: "重试保存")) {
                    Task {
                        if let assetID = await model.commit() {
                            onUse(assetID, buildPresentation())
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoToolAction)
            }
            if let onChangeImage {
                Button(String(localized: "换一张")) { onChangeImage() }
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
