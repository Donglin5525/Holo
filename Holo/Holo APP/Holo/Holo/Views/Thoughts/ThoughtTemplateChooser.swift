import SwiftUI

/// 选择器展示纸面结构缩略图，不用大块色卡代替模板。
struct ThoughtTemplateChooser: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme
    let selected: ThoughtStyle
    let date: Date
    let onSelect: (ThoughtStyle) -> Void
    var identifierPrefix = "thought.style.option"
    var previewsLightPaper = false

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.sm), count: sizeCategory.isAccessibilityCategory ? 3 : 5), spacing: HoloSpacing.sm) {
            ForEach(ThoughtStyle.allCases) { style in
                Button { onSelect(style) } label: {
                    VStack(spacing: HoloSpacing.xs) {
                        ThoughtStyleThumbnail(style: style, date: date)
                            .environment(\.colorScheme, previewsLightPaper ? .light : colorScheme)
                            .frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: ThoughtPaperMetrics.corner).stroke(selected == style ? Color.holoToolAction : style.listBorder, lineWidth: selected == style ? 2 : 0.5))
                            .overlay(alignment: .bottomTrailing) {
                                if selected == style {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.holoToolAction, Color.holoToolSurface)
                                        .padding(2)
                                }
                            }
                        Text(style.shortTitle)
                            .font(.holoLabel)
                            .foregroundStyle(selected == style ? Color.holoToolAction : Color.holoToolText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("\(identifierPrefix).\(style.rawValue)")
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(selected == style ? [.isSelected] : [])
            }
        }
    }
}

struct ThoughtStyleThumbnail: View {
    let style: ThoughtStyle
    let date: Date

    var body: some View {
        Canvas { context, size in
            let tone = style.accent
            let inset: CGFloat = style == .fold ? 13 : 7
            var start: CGFloat = 19
            if style == .calendar {
                context.draw(Text(ThoughtPaperDate.text(date, format: "d")).font(.custom(ThoughtTypography.fontName(.serif), fixedSize: 24)).foregroundStyle(tone), at: CGPoint(x: size.width / 2, y: 17))
                start = 35
            } else if style == .film {
                context.fill(Path(CGRect(x: 4, y: 7, width: max(1, size.width - 8), height: 22)), with: .color(tone.opacity(0.16)))
                for x in [4.0, size.width - 6] {
                    context.fill(Path(CGRect(x: x, y: 7, width: 2, height: 22)), with: .color(tone.opacity(0.65)))
                }
                start = 37
            } else {
                context.fill(Path(CGRect(x: inset, y: 13, width: max(1, size.width * 0.5), height: style == .ticket ? 4 : 2)), with: .color(tone.opacity(0.5)))
            }
            for row in 0..<3 {
                let line = CGRect(x: inset, y: start + CGFloat(row) * 5, width: max(1, size.width - inset - 7), height: 0.5)
                context.fill(Path(line), with: .color(tone.opacity(0.2)))
            }
            if style != .plain && style != .film {
                let width = (size.width - inset - 7) * (style == .dots || style == .bookmark ? 0.6 : 1)
                context.fill(Path(CGRect(x: style == .bookmark ? size.width - width - 7 : inset, y: start + 18, width: max(1, width), height: 12)), with: .color(tone.opacity(0.1)))
            }
            if style == .post {
                context.stroke(Path(CGRect(x: size.width - 15, y: 7, width: 8, height: 11)), with: .color(tone.opacity(0.65)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 1]))
            }
        }
        .background(style.paper)
        .overlay { ThoughtStationeryBackground(style: style, compact: true) }
        .clipShape(RoundedRectangle(cornerRadius: ThoughtPaperMetrics.corner))
        .accessibilityHidden(true)
    }
}
