//
//  ThoughtShareCard.swift
//  Holo
//
//  想法分享卡：把一条想法完整排成暖纸手账风长图（正文/图片/标签/心情/时间），
//  宽度固定、高度随内容生长，不做任何截断；导出图片供系统分享或存相册。
//  渲染目标是纯 SwiftUI（ImageRenderer 不支持 UIViewRepresentable），
//  且静态图上不得出现任何交互暗示元素（按钮/「点击」话术）。
//

import SwiftUI

// MARK: - 分享卡（渲染目标）

struct ThoughtShareCard: View {

    let contentNodes: [HoloContentNode]
    let attachments: [ThoughtShareCardPhoto]
    let tagNames: [String]
    let moodEmoji: String?
    let createdAt: Date
    /// 品牌尾注开关（用户可在分享面板取消）
    var showsBrandFooter: Bool = true

    /// 导出宽度固定；高度由内容决定
    static let cardWidth: CGFloat = 340

    /// ImageRenderer 渲染上限约 8192px（实测 6077px 正常、9115px 起输出全透明空图），
    /// 长图按内容高度动态降 scale 压回 8000px 内，超长笔记以轻度降清换可用性
    static let maxRenderPixel: CGFloat = 8000

    /// 导出渲染：先按 3x，尺寸超渲染上限时降 scale 重渲（超限会得到尺寸正确但全透明的空图）
    @MainActor static func renderExportImage(_ card: ThoughtShareCard) -> UIImage? {
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
        return image
    }

    // 暖纸手账固定色板（导出图与深色模式无关，刻意不随系统变色）
    private let ink = Color(red: 0.239, green: 0.196, blue: 0.161)          // #3D3229
    private let inkSoft = Color(red: 0.627, green: 0.541, blue: 0.455)      // #A08D77 附近
    private let holo = Color(red: 0.957, green: 0.427, blue: 0.220)         // #F46D38
    private let holoDeep = Color(red: 0.918, green: 0.345, blue: 0.047)     // #EA580C

    /// 正文衬线字体：中文走宋体（iOS 内置），缺失时系统自动回退
    private let bodyFont = Font.custom("Songti SC", size: 15.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 30)

            HoloDashedDivider()
                .stroke(
                    LinearGradient(
                        colors: [holo.opacity(0.55), Color(red: 0.784, green: 0.667, blue: 0.510).opacity(0.18), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 18)

            bodyText
                .padding(.horizontal, 28)

            photosSection
                .padding(.horizontal, 28)
                .padding(.top, attachments.isEmpty ? 0 : 18)

            tagsSection
                .padding(.horizontal, 28)
                .padding(.top, tagNames.isEmpty ? 0 : 20)

            Spacer().frame(height: 22)

            if showsBrandFooter {
                brandFooter
            }
        }
        .frame(width: Self.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.992, green: 0.976, blue: 0.941), Color(red: 0.980, green: 0.953, blue: 0.902)],
                    startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)
                )
                RadialGradient(
                    colors: [holo.opacity(0.06), .clear],
                    center: UnitPoint(x: 0.1, y: 0.02), startRadius: 8, endRadius: 240
                )
                RadialGradient(
                    colors: [holo.opacity(0.07), .clear],
                    center: UnitPoint(x: 0.92, y: 0.98), startRadius: 8, endRadius: 220
                )
            }
        )
    }

    // MARK: 头部（心情 + 日期）

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if let moodEmoji, !moodEmoji.isEmpty {
                Text(moodEmoji)
                    .font(.system(size: 21))
            }
            Spacer()
            Text(Self.dateLine(from: createdAt))
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.5)
                .foregroundColor(Color(red: 0.627, green: 0.553, blue: 0.467))
        }
    }

    // MARK: 正文（完整呈现，不截断）

    @ViewBuilder
    private var bodyText: some View {
        let attributed = Self.composedBodyAttributed(
            nodes: contentNodes,
            baseFont: bodyFont,
            ink: ink,
            holoDeep: holoDeep,
            inkSoft: Color(red: 0.541, green: 0.478, blue: 0.416)
        )
        if attributed != nil {
            Text(attributed ?? AttributedString())
                .lineSpacing(9)
                .kerning(0.4)
        } else {
            // 空内容兜底（正常保存的想法至少有一段文字）
            Text(" ")
                .font(bodyFont)
        }
    }

    // MARK: 图片（全部随文流入，1 图大图 / 2 张起两列拍立得）

    private var photoRowCount: Int {
        (attachments.count + 1) / 2
    }

    @ViewBuilder
    private var photosSection: some View {
        if !attachments.isEmpty {
            if attachments.count == 1 {
                PolaroidPhoto(photo: attachments[0], rotation: .zero)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 12) {
                    ForEach(0..<photoRowCount, id: \.self) { rowIndex in
                        photoRow(rowIndex)
                    }
                }
            }
        }
    }

    private func photoRow(_ rowIndex: Int) -> some View {
        let start = rowIndex * 2
        let end = min(start + 2, attachments.count)
        let row = Array(attachments[start..<end])
        return HStack(spacing: 12) {
            photoCell(rowIndex, 0, row[0])
            // 末行单张时补空位保持两列对齐
            if row.count > 1 {
                photoCell(rowIndex, 1, row[1])
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    /// 拍立得交错微旋转：奇偶行方向相反，避免整齐划一的机械感
    private func photoCell(_ rowIndex: Int, _ colIndex: Int, _ photo: ThoughtShareCardPhoto) -> some View {
        let evenRow = rowIndex % 2 == 0
        let angle: CGFloat = evenRow ? (colIndex == 0 ? -2.2 : 1.6) : (colIndex == 0 ? 1.6 : -2.2)
        return PolaroidPhoto(photo: photo, rotation: .degrees(angle))
            .frame(height: 104)
            .frame(maxWidth: .infinity)
    }

    // MARK: 标签胶囊（≤3，超出 +N）

    @ViewBuilder
    private var tagsSection: some View {
        if !tagNames.isEmpty {
            let shown = tagNames.prefix(3)
            HStack(spacing: 7) {
                ForEach(Array(shown), id: \.self) { name in
                    Text("#\(name)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(holoDeep)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(holo.opacity(0.09)))
                        .overlay(Capsule().stroke(holo.opacity(0.28), lineWidth: 0.8))
                }
                if tagNames.count > shown.count {
                    Text(String(localized: "+\(tagNames.count - shown.count)"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(inkSoft)
                }
            }
        }
    }

    // MARK: 品牌尾注（金线侧脸 + slogan，可被用户取消）

    private var brandFooter: some View {
        VStack(spacing: 0) {
            HoloDashedDivider()
                .stroke(Color(red: 0.690, green: 0.580, blue: 0.439).opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .padding(.horizontal, 28)

            HStack(spacing: 7) {
                Image("HoloFaceLineArt")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 15)
                    .opacity(0.9)
                Text(String(localized: "HOLO · 记下此刻"))
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(2.5)
                    .foregroundColor(Color(red: 0.659, green: 0.573, blue: 0.478))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
    }

    // MARK: - 工具

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("E")
        return formatter
    }()

    private static let timeStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func dateLine(from date: Date) -> String {
        // 模板按语区输出（zh: 2026年8月30日 / 周六），与设计稿「日期 · 周几 时间」一致
        let weekday = weekdayFormatter.string(from: date)
        let time = timeStampFormatter.string(from: date)
        return "\(dateStampFormatter.string(from: date)) · \(weekday) \(time)"
    }

    /// 把内容节点合成成一段排版好的富文本：text 走行内 Markdown，tag/reference/task 展开为可读文本。
    /// 全部拼接进同一个 AttributedString——分享图上的正文是连续阅读流。
    static func composedBodyAttributed(
        nodes: [HoloContentNode],
        baseFont: Font,
        ink: Color,
        holoDeep: Color,
        inkSoft: Color
    ) -> AttributedString? {
        var result = AttributedString()
        for node in nodes {
            switch node {
            case .text(let value):
                let inline = markdownAttributed(
                    value,
                    baseFont: baseFont,
                    ink: ink
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
    private static func markdownAttributed(_ text: String, baseFont: Font, ink: Color) -> AttributedString {
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

private struct PolaroidPhoto: View {
    let photo: ThoughtShareCardPhoto
    let rotation: Angle

    var body: some View {
        Image(uiImage: photo.image)
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .padding(5)
            .padding(.bottom, 14)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .shadow(color: Color(red: 0.353, green: 0.275, blue: 0.196).opacity(0.16), radius: 7, y: 4)
            )
            .rotationEffect(rotation)
    }
}

// MARK: - 虚线分隔（手账缝线感）

struct HoloDashedDivider: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - 分享面板（深色舞台：缩放预览 + 尾注开关 + 分享/存相册）

struct ThoughtShareSheet: View {

    let thought: Thought

    @Environment(\.dismiss) private var dismiss
    @AppStorage("thoughtShareCard.showsBrandFooter") private var showsBrandFooter = true

    @State private var renderedImage: UIImage?
    /// 预览专用降采样图：超长图（3x 下像素高度可破万）超过 GPU 纹理上限无法直接上屏，
    /// 但导出/分享走文件通道不受限——预览降采样，导出保持全量高清。
    @State private var previewImage: UIImage?
    @State private var saveState: SaveState = .idle

    private enum SaveState {
        case idle, saved, failed
    }

    private let stageTop = Color(red: 0.090, green: 0.071, blue: 0.102)
    private let stageBottom = Color(red: 0.141, green: 0.102, blue: 0.125)

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4.5)
                .padding(.top, 10)

            Text(String(localized: "分享这个想法"))
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 14)

            ZStack {
                if let previewImage {
                    // 长图极端宽高比下「整图缩放适配」会缩成细丝，改为预览区内全宽可滚动
                    GeometryReader { geo in
                        ScrollView(.vertical) {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width)
                                .frame(maxWidth: .infinity)
                                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
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
                    ShareLink(
                        item: Image(uiImage: renderedImage),
                        preview: SharePreview(
                            String(localized: "Holo · 记下此刻"),
                            image: Image(uiImage: renderedImage)
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
        .task(id: showsBrandFooter) {
            regenerateImage()
        }
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

    /// 渲染导出图。ImageRenderer 仅主线程可用；长图渲染一次性成本，配「正在生成」占位。
    private func regenerateImage() {
        let nodes = RichContentSerializer.nodes(
            richJSON: thought.richContentJSON,
            fallbackPlainText: thought.content
        )
        let photos = thought.sortedAttachments.compactMap { attachment -> ThoughtShareCardPhoto? in
            loadImage(for: attachment).map {
                ThoughtShareCardPhoto(id: attachment.id, image: $0)
            }
        }
        let card = ThoughtShareCard(
            contentNodes: nodes,
            attachments: photos,
            tagNames: displayTagNames,
            moodEmoji: thought.moodType?.emoji,
            createdAt: thought.createdAt,
            showsBrandFooter: showsBrandFooter
        )
        renderedImage = ThoughtShareCard.renderExportImage(card)
        previewImage = renderedImage.flatMap { Self.downsampledPreview($0) }
    }

    /// 把超大位图缩到 GPU 纹理上限以内（模拟器/老设备常见上限 4096，取 3500 留余量），仅供预览上屏
    private static func downsampledPreview(_ image: UIImage, maxPixel: CGFloat = 3500) -> UIImage {
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
    }

    private var displayTagNames: [String] {
        thought.recognizedTagNames.map { ThoughtTagNormalizer.lastSegment($0) }
    }

    /// 分享画质优先原图（Core Data 二进制 → 文件原图），都缺失时退回缩略图
    private func loadImage(for attachment: ThoughtAttachment) -> UIImage? {
        if let data = attachment.imageData, let image = UIImage(data: data) {
            return image
        }
        if let thoughtId = attachment.thought?.id,
           let full = AttachmentFileManager.loadFullImage(fileName: attachment.fileName, taskId: thoughtId) {
            return full
        }
        if let data = attachment.thumbnailData, let image = UIImage(data: data) {
            return image
        }
        if let thoughtId = attachment.thought?.id {
            return AttachmentFileManager.loadThumbnail(
                fileName: attachment.thumbnailFileName,
                taskId: thoughtId
            )
        }
        return nil
    }

    private func saveToAlbum(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        // 写入请求已提交；系统仅在没有相册写入授权时弹窗，结果通过回调不可用于此简化入口
        saveState = .saved
        HapticManager.success()
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            saveState = .idle
        }
    }
}
