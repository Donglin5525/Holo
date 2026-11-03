import SwiftUI

/// 候选样式先在完整纸面上预览；关闭不改宿主，点使用才交回本条想法。
struct ThoughtStylePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var candidate: ThoughtStyle
    let currentStyle: ThoughtStyle
    let content: String
    let photoCount: Int
    let createdAt: Date
    let nodes: [HoloContentNode]
    let photos: [ThoughtPaperPhotoSource]
    let onApply: (ThoughtStyle) -> Void

    init(style: ThoughtStyle, content: String, photoCount: Int, createdAt: Date, nodes: [HoloContentNode]? = nil, photos: [ThoughtPaperPhotoSource] = [], onApply: @escaping (ThoughtStyle) -> Void) {
        currentStyle = style
        _candidate = State(initialValue: style)
        self.content = content
        self.photoCount = photoCount
        self.createdAt = createdAt
        self.nodes = nodes ?? RichContentSerializer.nodes(richJSON: nil, fallbackPlainText: content)
        self.photos = photos
        self.onApply = onApply
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "选择样式"),
            onClose: { dismiss() },
            primaryTitle: candidate == currentStyle ? String(localized: "保留当前样式") : String(localized: "使用「") + candidate.title + "」",
            primaryAction: { onApply(candidate); dismiss() }
        ) {
            GeometryReader { proxy in
                if sizeCategory.isAccessibilityCategory {
                    // 大字号让选择与纸面沿同一滚动流排列，避免把预览压成一条缝。
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: HoloSpacing.md) {
                            choices
                            preview(width: proxy.size.width)
                        }
                    }
                    .background(Color.holoToolInset)
                } else {
                    VStack(spacing: 0) {
                        ScrollView(showsIndicators: false) { preview(width: proxy.size.width) }
                            .background(Color.holoToolInset)
                        choices
                    }
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("thought.style.picker")
    }

    private func preview(width: CGFloat) -> some View {
        ThoughtStationeryDocument(
            style: candidate,
            nodes: nodes,
            photos: photos,
            createdAt: createdAt,
            width: max(1, min(520, width - HoloSpacing.page * 2)),
            showsPlaceholder: true
        )
        .overlay(RoundedRectangle(cornerRadius: ThoughtPaperMetrics.corner).stroke(candidate.listBorder, lineWidth: 0.5))
        .accessibilityIdentifier("thought.style.preview.\(candidate.rawValue)")
        .padding(HoloSpacing.page)
        .frame(maxWidth: .infinity)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text(candidate.title)
                Spacer(minLength: HoloSpacing.sm)
                Text(candidate == currentStyle ? String(localized: "正在使用") : String(localized: "仅预览，尚未应用"))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .font(.holoLabel)
            ThoughtTemplateChooser(selected: candidate, date: createdAt) { style in
                HapticManager.selection()
                candidate = style
            }
            Text(String(localized: "仅应用到本条，文字与图片保留"))
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, HoloSpacing.page)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoToolSurface)
    }
}
