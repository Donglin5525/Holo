import SwiftUI

/// 完整纸面预览与分享共用；不生成标题、不改写正文，照片按模板构图呈现。
struct ThoughtStationeryDocument: View {
    let style: ThoughtStyle
    let nodes: [HoloContentNode]
    let photos: [ThoughtPaperPhotoSource]
    let createdAt: Date
    var width: CGFloat = ThoughtShareCard.cardWidth
    var tagNames: [String] = []
    var moodLabel: String? = nil
    var authorName: String? = nil
    var showsBrandFooter = false
    var showsPlaceholder = false

    private var textWidth: CGFloat { max(1, width - style.textInset - style.trailingInset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThoughtPaperHeader(style: style, date: createdAt)
            if authorName != nil || moodLabel != nil { metadata }
            if style.photosLead { photoSection }
            bodyText
                .padding(.leading, style.textInset)
                .padding(.trailing, style.trailingInset)
                .padding(.top, nodes.isEmpty && !showsPlaceholder ? 0 : style == .plain ? HoloSpacing.lg : HoloSpacing.sm)
            if !style.photosLead { photoSection }
            if !tagNames.isEmpty {
                Text(tagNames.map { "#\($0)" }.joined(separator: "  "))
                    .font(.holoLabel)
                    .foregroundStyle(style.accent)
                    .padding(.leading, style.textInset)
                    .padding(.trailing, style.trailingInset)
                    .padding(.top, HoloSpacing.lg)
            }
            ThoughtPaperFooter(style: style, showsBrand: showsBrandFooter)
        }
        .frame(width: max(1, width), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(style.paper)
        .overlay { ThoughtStationeryBackground(style: style) }
        .clipShape(RoundedRectangle(cornerRadius: ThoughtPaperMetrics.corner))
    }

    private var bodyText: some View {
        let attributed = ThoughtShareCard.composedBodyAttributed(
            nodes: nodes,
            baseFont: ThoughtTypography.font(style.fontRole),
            ink: style.ink,
            holoDeep: style.accent,
            inkSoft: style.muted,
            style: style
        )
        return Text(attributed ?? AttributedString(showsPlaceholder ? String(localized: "写下你的第一句话，让今天的一个片刻留在这里。") : ""))
            .font(ThoughtTypography.font(style.fontRole))
            .foregroundStyle(style.ink)
            .lineSpacing(ThoughtPaperMetrics.lineSpacing)
            .frame(maxWidth: .infinity, minHeight: showsPlaceholder && nodes.isEmpty ? 96 : 0, alignment: .topLeading)
            .background { ThoughtWritingGuide(style: style) }
    }

    private var photoSection: some View {
        ThoughtPaperPhotos(sources: photos, style: style, width: textWidth)
            .padding(.leading, style.textInset)
            .padding(.trailing, style.trailingInset)
            .padding(.top, photos.isEmpty ? 0 : HoloSpacing.lg)
            .padding(.bottom, style.photosLead && !photos.isEmpty ? HoloSpacing.md : 0)
    }

    private var metadata: some View {
        HStack(spacing: HoloSpacing.sm) {
            if let authorName { Text(authorName) }
            if let moodLabel { Text(moodLabel) }
        }
        .font(.holoLabel)
        .foregroundStyle(style.muted)
        .padding(.leading, style.textInset)
        .padding(.trailing, style.trailingInset)
        .padding(.bottom, HoloSpacing.sm)
    }
}

struct ThoughtPaperFooter: View {
    let style: ThoughtStyle
    var showsBrand = false
    var body: some View {
        if style != .plain || showsBrand {
            HStack(spacing: HoloSpacing.sm) {
                Rectangle().fill(style.accent.opacity(0.35)).frame(width: 28, height: 0.5)
                Spacer(minLength: HoloSpacing.sm)
                if showsBrand { Text(String(localized: "Holo · 人生数据库")).font(.holoLabel) }
            }
            .foregroundStyle(style.muted)
            .padding(.leading, style.textInset)
            .padding(.trailing, style.trailingInset)
            .padding(.top, HoloSpacing.lg)
            .padding(.bottom, HoloSpacing.lg)
            .accessibilityHidden(!showsBrand)
        } else {
            Color.clear.frame(height: HoloSpacing.lg).accessibilityHidden(true)
        }
    }
}
