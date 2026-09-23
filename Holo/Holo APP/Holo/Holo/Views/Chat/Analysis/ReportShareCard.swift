//
//  ReportShareCard.swift
//  Holo
//
//  深度分析报告分享卡：把一份报告（提问＋标题＋核心结论＋优先建议＋观察章节）
//  排成暖纸手账风长图，与想法分享卡同一「HOLO 出品」识别，导出图不随系统深浅模式变。
//  双档内容：完整报告＝含全部观察章节（长图随内容生长）；核心摘要＝一屏短卡。
//  渲染/降采样策略与 ThoughtShareCard 同源（超 8000px 降 scale 重渲、预览降采样）。
//

import SwiftUI

// MARK: - 分享卡（渲染目标）

struct ReportShareCard: View {

    enum ContentMode {
        /// 提问＋标题＋核心结论＋优先建议＋全部观察章节
        case full
        /// 提问＋标题＋核心结论＋优先建议（一屏短卡，适合快速转发）
        case summary
    }

    let narrative: AgentDeepAnalysisNarrativeModel
    let question: String?
    let scopeLabel: String?
    let generatedAt: Date?
    let mode: ContentMode
    /// 品牌尾注开关（用户可在分享面板取消）
    var showsBrandFooter: Bool = true

    /// 导出宽度固定；高度由内容决定（与想法分享卡同宽，同一视觉体系）
    static let cardWidth: CGFloat = 340

    /// ImageRenderer 渲染上限约 8192px（实测 6077px 正常、9115px 起输出全透明空图），
    /// 长报告按内容高度动态降 scale 压回 8000px 内，超长报告以轻度降清换可用性
    static let maxRenderPixel: CGFloat = 8000

    /// 导出渲染：先按 3x，尺寸超渲染上限时降 scale 重渲（超限会得到尺寸正确但全透明的空图）
    @MainActor static func renderExportImage(_ card: ReportShareCard) -> UIImage? {
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

    // 暖纸手账固定色板（与 ThoughtShareCard 同源，刻意不随系统深色模式变）
    private let ink = Color(red: 0.239, green: 0.196, blue: 0.161)          // #3D3229
    private let inkSoft = Color(red: 0.627, green: 0.541, blue: 0.455)      // #A08D77 附近
    private let holo = Color(red: 0.957, green: 0.427, blue: 0.220)         // #F46D38
    private let holoDeep = Color(red: 0.918, green: 0.345, blue: 0.047)     // #EA580C

    private let titleFont = Font.custom("Songti SC", size: 21)
    private let bodyFont = Font.custom("Songti SC", size: 13)
    private let questionFont = Font.custom("Songti SC", size: 14.5)

    /// 观察章节左侧竖条轮换色（与详情页 accentColor 同一节奏）
    private let accentPalette: [Color] = [
        Color(red: 0.43, green: 0.55, blue: 0.49),
        Color(red: 0.957, green: 0.427, blue: 0.220),
        Color(red: 0.72, green: 0.52, blue: 0.38)
    ]

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMM")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 28)

            dashedDivider
                .padding(.horizontal, 28)
                .padding(.top, 16)

            if let question {
                questionBlock(question)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                dashedDivider
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }

            mainContent
                .padding(.horizontal, 28)
                .padding(.top, 16)

            Spacer().frame(height: 24)

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

    // MARK: 头部（品牌 + 深度分析章 + 范围行）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(holo)
                Text("HOLO")
                    .font(.system(size: 14, weight: .heavy))
                    .kerning(2.5)
                    .foregroundColor(ink)
                Spacer()
                Text(String(localized: "深度分析"))
                    .font(.system(size: 10, weight: .bold))
                    .kerning(2)
                    .foregroundColor(holoDeep)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(holo.opacity(0.07)))
                    .overlay(Capsule().stroke(holoDeep.opacity(0.45), lineWidth: 1))
                    .rotationEffect(.degrees(-2))
            }

            Text(scopeLine)
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.5)
                .foregroundColor(inkSoft)
        }
    }

    private var scopeLine: String {
        var parts: [String] = []
        if let scopeLabel, !scopeLabel.isEmpty {
            parts.append(scopeLabel)
        }
        if let generatedAt {
            parts.append(Self.monthFormatter.string(from: generatedAt))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 提问引文块（先看到问的是什么，再读答的是什么）

    private func questionBlock(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "提问"))
                .font(.system(size: 10, weight: .heavy))
                .kerning(3)
                .foregroundColor(holoDeep)
            Text(question)
                .font(questionFont.weight(.semibold))
                .foregroundColor(ink)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
                .overlay(alignment: .topLeading) {
                    Text(verbatim: "“")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundColor(holo)
                        .offset(x: -2, y: -5)
                }
        }
    }

    // MARK: 主体（标题 / 核心结论 / 建议 / 观察章节）

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(narrative.openingTitle)
                .font(titleFont.weight(.bold))
                .foregroundColor(ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if let keyInsight = narrative.keyInsight {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(holo)
                        .frame(width: 3)
                    Text(keyInsight)
                        .font(bodyFont.weight(.semibold))
                        .foregroundColor(ink.opacity(0.88))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                .padding(.trailing, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(holo.opacity(0.08))
                )
            }

            if !narrative.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel(String(localized: "优先建议"))
                    ForEach(Array(narrative.recommendations.enumerated()), id: \.offset) { index, recommendation in
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(holoDeep)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(holo.opacity(0.13)))
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recommendation.title)
                                    .font(Font.custom("Songti SC", size: 14).weight(.bold))
                                    .foregroundColor(ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(recommendation.body)
                                    .font(bodyFont)
                                    .foregroundColor(ink.opacity(0.82))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if mode == .full {
                observationSection
            }
        }
    }

    @ViewBuilder
    private var observationSection: some View {
        if !narrative.observations.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                sectionLabel(String(localized: "观察"))
                ForEach(Array(narrative.observations.enumerated()), id: \.offset) { _, observation in
                    observationChapter(observation)
                }
            }
        }
    }

    private func observationChapter(_ observation: AgentDeepAnalysisNarrativeModel.Observation) -> some View {
        let accent = accentPalette[observation.accentIndex % accentPalette.count]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3, height: 14)
                    .padding(.top, 3)
                Text(observation.title)
                    .font(Font.custom("Songti SC", size: 14.5).weight(.bold))
                    .foregroundColor(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(observation.body)
                .font(bodyFont)
                .foregroundColor(ink.opacity(0.82))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if let interpretation = observation.interpretation {
                Text(interpretation)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(inkSoft)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .kerning(3)
            .foregroundColor(inkSoft)
    }

    // MARK: 品牌尾注（金线侧脸 + slogan，可被用户取消）

    private var brandFooter: some View {
        VStack(spacing: 0) {
            dashedDivider
                .padding(.horizontal, 28)

            HStack(spacing: 7) {
                Image("HoloFaceLineArt")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 15)
                    .opacity(0.9)
                Text(String(localized: "HOLO · 人生数据库"))
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(2.5)
                    .foregroundColor(Color(red: 0.659, green: 0.573, blue: 0.478))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
    }

    // MARK: 虚线分隔（手账缝线感）

    private var dashedDivider: some View {
        HoloDashedDivider()
            .stroke(
                LinearGradient(
                    colors: [holo.opacity(0.55), Color(red: 0.784, green: 0.667, blue: 0.510).opacity(0.18), .clear],
                    startPoint: .leading, endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            .frame(height: 1)
    }
}

// MARK: - 分享面板（深色舞台：双档切换 + 预览 + 尾注开关 + 分享/存相册）

struct ReportShareSheet: View {

    let narrative: AgentDeepAnalysisNarrativeModel
    let question: String?
    let scopeLabel: String?
    let generatedAt: Date?

    @AppStorage("reportShareCard.showsBrandFooter") private var showsBrandFooter = true
    @State private var mode: ReportShareCard.ContentMode = .full
    @State private var renderedImage: UIImage?
    /// 预览专用降采样图：长报告 3x 下像素高度可破 GPU 纹理上限无法直接上屏，
    /// 导出/分享走文件通道不受限——预览降采样，导出保持全量高清。
    @State private var previewImage: UIImage?
    @State private var saveState: SaveState = .idle

    private enum SaveState {
        case idle, saved, failed
    }

    private let holoOrange = Color(red: 0.957, green: 0.427, blue: 0.220)
    private let stageTop = Color(red: 0.090, green: 0.071, blue: 0.102)
    private let stageBottom = Color(red: 0.141, green: 0.102, blue: 0.125)

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4.5)
                .padding(.top, 10)

            Text(String(localized: "分享报告"))
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 14)

            modeSwitcher
                .padding(.top, 14)

            ZStack {
                if let previewImage {
                    // 长图极端宽高比下「整图缩放适配」会缩成细丝，预览区内全宽可滚动
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
            .padding(.top, 18)
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
                    .tint(holoOrange)
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
                            String(localized: "HOLO · 人生数据库"),
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

            Text(String(localized: "分享图包含你的个人数据分析，请确认后再发送"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .task(id: renderKey) {
            regenerateImage()
        }
    }

    // MARK: 双档切换（完整报告 / 核心摘要）

    private var modeSwitcher: some View {
        HStack(spacing: 3) {
            modeButton(String(localized: "完整报告"), target: .full)
            modeButton(String(localized: "核心摘要"), target: .summary)
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 24)
    }

    private func modeButton(_ title: String, target: ReportShareCard.ContentMode) -> some View {
        Button {
            guard mode != target else { return }
            mode = target
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(mode == target ? .white : Color.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(mode == target ? holoOrange : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var renderKey: String {
        "\(mode == .full ? "full" : "summary")-\(showsBrandFooter)"
    }

    private func actionLabel(title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 14, weight: .heavy))
        .foregroundColor(filled ? .white : holoOrange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(filled ? holoOrange : Color.white.opacity(0.10))
        )
    }

    /// 渲染导出图。ImageRenderer 仅主线程可用；长报告渲染一次性成本，配「正在生成」占位。
    private func regenerateImage() {
        let card = ReportShareCard(
            narrative: narrative,
            question: question,
            scopeLabel: scopeLabel,
            generatedAt: generatedAt,
            mode: mode,
            showsBrandFooter: showsBrandFooter
        )
        renderedImage = ReportShareCard.renderExportImage(card)
        previewImage = renderedImage.flatMap { Self.downsampledPreview($0) }
    }

    /// 把超大位图缩到 GPU 纹理上限以内（与 ThoughtShareSheet 同源策略，取 3500 留余量），仅供预览上屏
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
