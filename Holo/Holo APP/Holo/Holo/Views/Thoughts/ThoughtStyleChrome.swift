import SwiftUI

extension ThoughtStyle {
    private var assetName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var paper: Color { self == .plain ? .holoToolSurface : Color("Thought\(assetName)Paper") }
    var ink: Color { self == .plain ? .holoToolText : Color("Thought\(assetName)Ink") }
    var accent: Color { self == .plain ? .holoToolTextSecondary : Color("Thought\(assetName)Accent") }
    var muted: Color { self == .plain ? .holoToolTextSecondary : accent }
    var editorPaper: Color { paper }
    var editorInk: Color { ink }
    var listPaper: Color { paper }
    var listBorder: Color { self == .plain ? .holoToolBorder : Color("Thought\(assetName)Border") }
    var listAccent: Color { accent }
    var textInset: CGFloat { self == .fold ? ThoughtPaperMetrics.foldInset : ThoughtPaperMetrics.inset }
    var trailingInset: CGFloat { self == .ticket ? 32 : ThoughtPaperMetrics.inset }
}

/// 列表只提示本条模板，状态、菜单和标签继续保留原位置。
struct ThoughtStyleSignature: View {
    let style: ThoughtStyle
    var body: some View {
        if style != .plain {
            Image(systemName: style.symbol)
                .font(.holoLabel)
                .foregroundStyle(style.listAccent)
                .lineLimit(1)
                .accessibilityLabel(String(localized: "样式：") + style.title)
        }
    }
}

struct ThoughtStyleCardDecoration: View {
    let style: ThoughtStyle
    var body: some View {
        ThoughtStationeryBackground(style: style, compact: true)
            .accessibilityHidden(true)
    }
}

struct ThoughtStyleHeaderRule: View {
    let style: ThoughtStyle
    var body: some View {
        if style == .field || style == .post {
            ThoughtPaperRule()
                .stroke(style.accent.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: style == .post ? [3, 3] : []))
                .frame(height: 1)
        }
    }
}

struct ThoughtPaperRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// 报告分享卡也使用这条虚线，保留既有公共名称。
typealias HoloDashedDivider = ThoughtPaperRule

/// 编辑、预览和分享共用页眉；日期只来自记录，不补造地点、天气或署名。
struct ThoughtPaperHeader: View {
    let style: ThoughtStyle
    let date: Date

    var body: some View {
        Group {
            switch style {
            case .plain:
                EmptyView()
            case .calendar:
                ThoughtCalendarMasthead(date: date)
            case .post:
                HStack(alignment: .center) {
                    dateLine
                    Spacer(minLength: HoloSpacing.sm)
                    ThoughtPostageStamp(style: style)
                }
            case .field:
                HStack {
                    dateLine
                    Spacer(minLength: HoloSpacing.sm)
                    Image(systemName: "leaf").accessibilityHidden(true)
                }
                .padding(.bottom, HoloSpacing.sm)
                .overlay(alignment: .bottom) { rule }
            case .ticket:
                HStack {
                    dateLine
                    Spacer(minLength: HoloSpacing.sm)
                }
                .padding(.bottom, HoloSpacing.md)
                .overlay(alignment: .bottom) {
                    ThoughtPaperRule().stroke(style.accent.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).frame(height: 1)
                }
            case .fold:
                dateLine.frame(maxWidth: .infinity, alignment: .leading)
            case .film:
                HStack {
                    dateLine
                    Spacer(minLength: HoloSpacing.sm)
                }
                .padding(.bottom, HoloSpacing.sm)
                .overlay(alignment: .bottom) { rule }
            case .bookmark:
                dateLine.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, HoloSpacing.xl)
                    .padding(.bottom, HoloSpacing.md)
                    .overlay(alignment: .bottom) { rule }
            case .dots:
                HStack {
                    dateLine
                    Spacer(minLength: HoloSpacing.sm)
                    HStack(spacing: HoloSpacing.sm) {
                        Circle().stroke(style.accent.opacity(0.4), lineWidth: 0.5).frame(width: 4, height: 4)
                        Circle().stroke(style.accent.opacity(0.4), lineWidth: 0.5).frame(width: 4, height: 4)
                    }.accessibilityHidden(true)
                }
            }
        }
        .font(.holoLabel)
        .foregroundStyle(style.accent)
        .padding(.leading, style == .plain ? 0 : style.textInset)
        .padding(.trailing, style == .plain ? 0 : style.trailingInset)
        .padding(.top, style == .plain ? 0 : HoloSpacing.lg)
        .padding(.bottom, style == .plain ? 0 : HoloSpacing.md)
        .accessibilityElement(children: .combine)
    }

    private var dateLine: some View { Text(ThoughtPaperDate.text(date, format: "yyyy.MM.dd")).fixedSize(horizontal: false, vertical: true) }
    private var rule: some View { Rectangle().fill(style.accent.opacity(0.25)).frame(height: 0.5) }
}

struct ThoughtPostageStamp: View {
    let style: ThoughtStyle
    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            Circle().fill(Color.holoPrimary.opacity(0.6)).frame(width: 16, height: 16)
            Rectangle().fill(style.accent.opacity(0.35)).frame(width: 16, height: 0.5)
        }
        .foregroundStyle(style.accent)
        .frame(width: 32, height: 38)
        .overlay(Rectangle().stroke(style.accent.opacity(0.6), style: StrokeStyle(lineWidth: 0.5, dash: [1, 2])))
        .accessibilityHidden(true)
    }
}

struct ThoughtCardDateMark: View {
    let date: Date
    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text(ThoughtPaperDate.text(date, format: "d"))
                .font(ThoughtTypography.font(.serif, size: 32, relativeTo: .title))
            Text(ThoughtPaperDate.text(date, format: "M月")).font(.holoLabel)
        }
        .foregroundStyle(ThoughtStyle.calendar.accent)
        .padding(.trailing, HoloSpacing.sm)
        .overlay(alignment: .trailing) { Rectangle().fill(ThoughtStyle.calendar.accent.opacity(0.2)).frame(width: 0.5) }
        .accessibilityHidden(true)
    }
}

enum ThoughtPaperDate {
    private static let formats: [String: DateFormatter] = {
        Dictionary(uniqueKeysWithValues: ["yyyy.MM.dd", "yyyy.MM.dd HH:mm", "yyyy", "M月", "d", "EEE", "HH:mm", "yyyy.MM"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            return (format, formatter)
        })
    }()
    static func text(_ date: Date, format: String) -> String { formats[format]?.string(from: date) ?? "" }
}

