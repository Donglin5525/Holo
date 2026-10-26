//
//  ThoughtShareCard.swift
//  Holo
//
//  想法分享卡：把一条想法完整排成多种风格长图（正文/图片/标签/心情/时间），
//  宽度固定、高度随内容生长，不做任何截断；导出图片供系统分享或存相册。
//  渲染目标是纯 SwiftUI（ImageRenderer 不支持 UIViewRepresentable），
//  且静态图上不得出现任何交互暗示元素（按钮/「点击」话术）。
//

import SwiftUI
import CoreData

// MARK: - 分享卡（渲染目标）

struct ThoughtShareCard: View {

    let contentNodes: [HoloContentNode]
    let attachments: [ThoughtShareCardPhoto]
    let tagNames: [String]
    let moodLabel: String?
    let createdAt: Date
    /// 作者署名（用户昵称）：未设置昵称时为 nil，页眉不显示也不造假占位
    var authorName: String? = nil
    var style: ThoughtStyle = .post
    /// 品牌尾注开关（用户可在分享面板取消）
    var showsBrandFooter: Bool = true

    /// 完整构造器：编辑记录与分享共用同一套样式标识。
    init(
        contentNodes: [HoloContentNode],
        attachments: [ThoughtShareCardPhoto],
        tagNames: [String],
        moodLabel: String?,
        createdAt: Date,
        authorName: String?,
        style: ThoughtStyle,
        showsBrandFooter: Bool
    ) {
        self.contentNodes = contentNodes
        self.attachments = attachments
        self.tagNames = tagNames
        self.moodLabel = moodLabel
        self.createdAt = createdAt
        self.authorName = authorName
        self.style = style
        self.showsBrandFooter = showsBrandFooter
    }

    /// 保留暖纸手账的原有构造入口，兼容现有调用与导出测试。
    init(
        contentNodes: [HoloContentNode],
        attachments: [ThoughtShareCardPhoto],
        tagNames: [String],
        moodLabel: String?,
        createdAt: Date,
        authorName: String?
    ) {
        self.init(
            contentNodes: contentNodes,
            attachments: attachments,
            tagNames: tagNames,
            moodLabel: moodLabel,
            createdAt: createdAt,
            authorName: authorName,
            style: .post,
            showsBrandFooter: true
        )
    }

    /// 导出宽度固定；高度由内容决定
    static let cardWidth: CGFloat = 340

    /// 正文区宽度（卡宽减左右 28 边距），拍立得槽位由它派生
    static let photoAreaWidth: CGFloat = cardWidth - 56

    /// 拍立得槽位：定长 frame 是唯一能真正钳住 scaledToFill 封面尺寸的写法
    /// （maxWidth/maxHeight .infinity 不构成上界，竖图会撑爆槽位、白框盖住正文与邻行）
    static let singlePhotoSlot = CGSize(width: photoAreaWidth, height: 150)
    static let gridPhotoSlot = CGSize(width: (photoAreaWidth - 12) / 2, height: 104)

    /// ImageRenderer 渲染上限约 8192px（实测 6077px 正常、9115px 起输出全透明空图），
    /// 长图按内容高度动态降 scale 压回 8000px 内，超长笔记以轻度降清换可用性
    static let maxRenderPixel: CGFloat = 8000

    /// 导出渲染：先按 3x，尺寸超渲染上限时降 scale 重渲（超限会得到尺寸正确但全透明的空图）
    @MainActor static func renderExportImage(_ card: ThoughtShareCard) -> UIImage? {
        #if canImport(UIKit)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        var image = renderer.uiImage
        if let first = image {
            let maxPixel = max(first.size.width, first.size.height) * first.scale
            if maxPixel > maxRenderPixel {
                let retry = ImageRenderer(content: card)
                retry.scale = maxRenderPixel / max(first.size.width, first.size.height)
                image = retry.uiImage
            }
        }
        // 奇数像素高度时 ImageRenderer 底行会采样出 1px 杂色线（实测纯绿，偶数高度不出现），
        // 底缘恒为纯背景色内边距，统一裁掉 1 设备像素无视觉损失
        if let cg = image?.cgImage {
            image = UIImage(cgImage: cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height - 1)) ?? cg, scale: image?.scale ?? 1, orientation: .up)
        }
        return image
        #else
        // macOS：ImageRenderer 走 NSImage 出口（无底行杂色问题，无需裁剪）
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.nsImage
        #endif
    }

    var body: some View {
        ThoughtStationeryDocument(
            style: style,
            nodes: contentNodes,
            photos: attachments.map { ThoughtPaperPhotoSource(id: $0.id, image: $0.image) },
            createdAt: createdAt,
            width: Self.cardWidth,
            tagNames: tagNames,
            moodLabel: moodLabel,
            authorName: authorName,
            showsBrandFooter: showsBrandFooter
        )
        // 分享图固定浅色纸面；App 内的纸张仍按系统明暗适配。
        .environment(\.colorScheme, .light)
    }

    static func dateLine(from date: Date) -> String {
        ThoughtPaperDate.text(date, format: "yyyy.MM.dd HH:mm")
    }

    /// 把内容节点合成成一段排版好的富文本：text 走行内 Markdown，tag/reference/task 展开为可读文本。
    /// 全部拼接进同一个 AttributedString——分享图上的正文是连续阅读流。
    static func composedBodyAttributed(
        nodes: [HoloContentNode],
        baseFont: Font,
        ink: Color,
        holoDeep: Color,
        inkSoft: Color,
        style: ThoughtStyle? = nil
    ) -> AttributedString? {
        var result = AttributedString()
        for node in nodes {
            switch node {
            case .text(let value):
                let inline = markdownAttributed(
                    value,
                    baseFont: baseFont,
                    ink: ink,
                    style: style
                )
                result += inline
            case .tag(_, let displayPath):
                var segment = AttributedString("#\(displayPath)")
                segment.font = baseFont
                segment.foregroundColor = holoDeep
                result += segment
            case .reference(_, let displayText, _):
                var segment = AttributedString("@\(displayText)")
                segment.font = baseFont
                segment.foregroundColor = inkSoft
                result += segment
            case .taskMark(_, _, let displayText, _):
                var segment = AttributedString(
                    displayText.isEmpty
                        ? String(localized: "已转为任务")
                        : String(localized: "已转为任务：\(displayText)")
                )
                segment.font = baseFont
                segment.foregroundColor = inkSoft
                result += segment
            }
        }
        guard !result.characters.isEmpty else { return nil }
        return result
    }

    /// 行内 Markdown（**粗**/*斜*/*斜*/`code`/~~删~~）→ SwiftUI 可直接渲染的富文本；
    /// 解析失败（含未闭合记号）时退回纯文本，保证任何内容都能完整导出。
    private static func markdownAttributed(_ text: String, baseFont: Font, ink: Color, style: ThoughtStyle?) -> AttributedString {
        if let style { return ThoughtTypography.exportText(text, style: style) }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if var attributed = try? AttributedString(markdown: text, options: options) {
            attributed.font = baseFont
            attributed.foregroundColor = ink
            return attributed
        }
        var plain = AttributedString(text)
        plain.font = baseFont
        plain.foregroundColor = ink
        return plain
    }
}

// MARK: - 拍立得照片

struct ThoughtShareCardPhoto: Identifiable {
    let id: UUID
    let image: UIImage
}

// MARK: - 分享面板（深色舞台：缩放预览 + 尾注开关 + 分享/存相册）

struct ThoughtShareSheet: View {

    @ObservedObject var thought: Thought
    var onStyleChange: ((ThoughtStyle) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("thoughtShareCard.showsBrandFooter") private var showsBrandFooter = true
    @State private var selectedStyleRaw: String

    @State private var renderedImage: UIImage?
    /// 预览专用降采样图：超长图（3x 下像素高度可破万）超过 GPU 纹理上限无法直接上屏，
    /// 但导出/分享走文件通道不受限——预览降采样，导出保持全量高清。
    @State private var previewImage: UIImage?
    @State private var saveState: SaveState = .idle
    /// 内容解析缓存（节点 + 解码后的图片）：面板生命周期内 thought 不变，
    /// 切换模板只重排不重新解码原图——全尺寸解码是切换卡顿的主要来源
    @State private var parsedNodes: [HoloContentNode]?
    @State private var parsedPhotos: [ThoughtShareCardPhoto]?

    private enum SaveState {
        case idle, saved, failed
    }

    private let stageTop = Color(red: 0.090, green: 0.071, blue: 0.102)
    private let stageBottom = Color(red: 0.141, green: 0.102, blue: 0.125)

    init(thought: Thought, onStyleChange: ((ThoughtStyle) -> Void)? = nil) {
        _thought = ObservedObject(wrappedValue: thought)
        _selectedStyleRaw = State(initialValue: thought.appearanceStyle.rawValue)
        self.onStyleChange = onStyleChange
    }

    private var selectedStyle: ThoughtStyle {
        ThoughtStyle(storedValue: selectedStyleRaw)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4.5)
                .padding(.top, 10)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭"))

                Spacer()

                Text(String(localized: "分享这个想法"))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)

                Spacer()

                Color.clear.frame(width: 34, height: 34)
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)

            ZStack {
                if let previewImage {
                    // 长图极端宽高比下「整图缩放适配」会缩成细丝，改为预览区内全宽可滚动
                    GeometryReader { geo in
                        ScrollView(.vertical) {
                            #if canImport(UIKit)
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width)
                                .frame(maxWidth: .infinity)
                                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
                            #else
                            Image(nsImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width)
                                .frame(maxWidth: .infinity)
                                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
                            #endif
                        }
                        .scrollIndicators(.hidden)
                    }
                    .padding(.horizontal, 30)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text(String(localized: "正在生成分享图…"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.top, 20)
            .frame(maxHeight: .infinity, alignment: .center)

            HStack {
                Text(String(localized: "本条样式：") + thought.appearanceStyle.title)
                Spacer()
                Text(selectedStyle == thought.appearanceStyle ? String(localized: "沿用本条样式") : String(localized: "仅用于本次分享"))
            }
            .font(.holoTinyLabel)
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)

            templatePicker
                .padding(.top, 12)
                .padding(.bottom, 12)

            Button {
                do {
                    try ThoughtRepository().updateStyle(selectedStyle, thoughtId: thought.id)
                    onStyleChange?(selectedStyle)
                    HapticManager.success()
                } catch {
                    HoloToastCenter.shared.show(String(localized: "样式保存失败，请重试"), type: .error)
                }
            } label: {
                Text(selectedStyle == thought.appearanceStyle ? String(localized: "已与想法一致") : String(localized: "设为这条想法的样式"))
                    .font(.holoLabel)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .foregroundStyle(.white.opacity(0.85))
            .disabled(selectedStyle == thought.appearanceStyle)
            .accessibilityIdentifier("thought.share.applyStyle")

            HStack {
                Image("HoloFaceLineArt")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                Text(String(localized: "显示 Holo 品牌尾注"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Toggle("", isOn: $showsBrandFooter)
                    .labelsHidden()
                    .tint(Color(red: 0.957, green: 0.427, blue: 0.220))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                if let renderedImage {
                    #if canImport(UIKit)
                    let shareItemImage = Image(uiImage: renderedImage)
                    #else
                    let shareItemImage = Image(nsImage: renderedImage)
                    #endif
                    ShareLink(
                        item: shareItemImage,
                        preview: SharePreview(
                            String(localized: "HOLO · 人生数据库"),
                            image: shareItemImage
                        )
                    ) {
                        actionLabel(title: String(localized: "分享图片"), icon: "square.and.arrow.up", filled: true)
                    }
                    Button {
                        saveToAlbum(renderedImage)
                    } label: {
                        actionLabel(
                            title: saveState == .saved ? String(localized: "已保存") : String(localized: "保存到相册"),
                            icon: saveState == .saved ? "checkmark" : "square.and.arrow.down",
                            filled: false
                        )
                    }
                    .disabled(saveState == .saved)
                } else {
                    actionLabel(title: String(localized: "分享图片"), icon: "square.and.arrow.up", filled: true)
                        .opacity(0.4)
                    actionLabel(title: String(localized: "保存到相册"), icon: "square.and.arrow.down", filled: false)
                        .opacity(0.4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .task(id: "\(selectedStyleRaw)|\(showsBrandFooter)") {
            await regenerateImage()
        }
    }

    private var templatePicker: some View {
        ThoughtTemplateChooser(selected: selectedStyle, date: thought.createdAt, onSelect: { style in
            guard selectedStyle != style else { return }
            HapticManager.selection()
            renderedImage = nil
            previewImage = nil
            saveState = .idle
            selectedStyleRaw = style.rawValue
        }, identifierPrefix: "thought.share.style", previewsLightPaper: true)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoToolSurface)
    }

    private func actionLabel(title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 14, weight: .heavy))
        .foregroundColor(filled ? .white : Color(red: 0.957, green: 0.427, blue: 0.220))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(filled ? Color(red: 0.957, green: 0.427, blue: 0.220) : Color.white.opacity(0.10))
        )
    }

    /// 渲染导出图。照片解码走共享后台通道（此前主线程同步解原图，带图分享时
    /// 弹层明显卡顿）；ImageRenderer 仅主线程可用，渲染段保持主线程。
    private func regenerateImage() async {
        let requestedStyle = selectedStyleRaw
        let requestedFooter = showsBrandFooter
        if parsedNodes == nil {
            parsedNodes = RichContentSerializer.nodes(
                richJSON: thought.richContentJSON,
                fallbackPlainText: thought.content
            )
        }
        if parsedPhotos == nil {
            // 主线程取附件快照（objectID + 回退文件名），画质与原链路同序：原图优先、缩略图兜底
            let thoughtId = thought.id
            let snapshots = thought.sortedAttachments.map { attachment in
                (id: attachment.id,
                 objectID: attachment.objectID,
                 fileName: attachment.fileName,
                 thumbnailFileName: attachment.thumbnailFileName)
            }
            var photos: [ThoughtShareCardPhoto] = []
            for snapshot in snapshots {
                var image = await AttachmentImageLoader.fullImage(
                    objectID: snapshot.objectID,
                    fallbackFileName: snapshot.fileName,
                    ownerID: thoughtId
                )
                if image == nil {
                    image = await AttachmentImageLoader.thumbnail(
                        objectID: snapshot.objectID,
                        fallbackFileName: snapshot.thumbnailFileName,
                        ownerID: thoughtId
                    )
                }
                if let image {
                    photos.append(ThoughtShareCardPhoto(id: snapshot.id, image: image))
                }
            }
            parsedPhotos = photos
        }
        guard !Task.isCancelled, selectedStyleRaw == requestedStyle, showsBrandFooter == requestedFooter,
              let nodes = parsedNodes, let photos = parsedPhotos else { return }
        let card = ThoughtShareCard(
            contentNodes: nodes,
            attachments: photos,
            tagNames: displayTagNames,
            moodLabel: thought.moodType?.displayName,
            createdAt: thought.createdAt,
            authorName: authorName,
            style: selectedStyle,
            showsBrandFooter: showsBrandFooter
        )
        renderedImage = ThoughtShareCard.renderExportImage(card)
        previewImage = renderedImage.flatMap { Self.downsampledPreview($0) }
    }

    /// 把超大位图缩到 GPU 纹理上限以内（模拟器/老设备常见上限 4096，取 3500 留余量），仅供预览上屏
    private static func downsampledPreview(_ image: UIImage, maxPixel: CGFloat = 3500) -> UIImage {
        #if canImport(UIKit)
        let widthPx = image.size.width * image.scale
        let heightPx = image.size.height * image.scale
        let maxDimension = max(widthPx, heightPx)
        guard maxDimension > maxPixel else { return image }

        let ratio = maxPixel / maxDimension
        let targetSize = CGSize(width: widthPx * ratio, height: heightPx * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        #else
        // macOS：Phase A 预览不降采样（GPU 纹理上限问题在桌面端不成立）
        return image
        #endif
    }

    private var displayTagNames: [String] {
        thought.recognizedTagNames.map { ThoughtTagNormalizer.lastSegment($0) }
    }

    /// 页眉署名：与首页问候语同源同规则（真设置过昵称才显示，兜底代词「你」不算）
    private var authorName: String? {
        let raw = UserDefaults.standard.string(forKey: UserDisplayNameSettings.displayNameKey)
        guard UserDisplayNameSettings.isDisplayNameSet(raw) else { return nil }
        return UserDisplayNameSettings.normalizedDisplayName(raw)
    }

#if canImport(UIKit)
    private func saveToAlbum(_ image: UIImage) {
        // 必须等系统回调再报结果：权限被拒/写入失败时立刻显示「已保存」是假成功（2026-10-22 挑刺修复）
        let target = PhotoAlbumSaveTarget { error in
            Task { @MainActor in
                if let error {
                    HoloToastCenter.shared.show(
                        String(localized: "保存失败：\(error.localizedDescription)"), type: .error)
                    saveState = .idle
                    return
                }
                saveState = .saved
                HapticManager.success()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                saveState = .idle
            }
        }
        UIImageWriteToSavedPhotosAlbum(
            image, target,
            #selector(PhotoAlbumSaveTarget.image(_:didFinishSavingWithError:contextInfo:)),
            Unmanaged.passRetained(target).toOpaque())
    }
#else
    /// macOS：无系统相册写入 API；保存按钮给出如实反馈（Phase A）
    private func saveToAlbum(_ image: UIImage) {
        HoloToastCenter.shared.show(String(localized: "Mac 版暂不支持保存到相册"), type: .warning)
    }
#endif
}

#if canImport(UIKit)
/// UIImageWriteToSavedPhotosAlbum 只认 ObjC selector 回调；contextInfo 携带自持引用，回调后释放。
private final class PhotoAlbumSaveTarget: NSObject {
    private let completion: (Error?) -> Void

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer) {
        completion(error)
        Unmanaged<PhotoAlbumSaveTarget>.fromOpaque(contextInfo).release()
    }
}
#endif
