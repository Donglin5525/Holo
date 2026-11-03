import SwiftUI

/// 只画纸页边缘，正文和图片留出独立空间，装饰不参与触摸。
struct ThoughtStationeryBackground: View {
    let style: ThoughtStyle
    var compact = false

    var body: some View {
        Canvas { context, size in
            let tone = style.accent
            switch style {
            case .plain, .calendar, .film, .dots:
                break
            case .post:
                for index in 0..<Int(size.width / 28) {
                    let rect = CGRect(x: CGFloat(index) * 28, y: 0, width: 12, height: compact ? 2 : 4)
                    context.fill(Path(rect), with: .color(index.isMultiple(of: 2) ? tone.opacity(0.65) : Color.holoPrimary.opacity(0.55)))
                }
                if compact {
                    let stamp = CGRect(x: size.width - 43, y: 62, width: 22, height: 28)
                    context.stroke(Path(stamp), with: .color(tone.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 2]))
                }
            case .field:
                line(&context, from: CGPoint(x: 0, y: 1), to: CGPoint(x: size.width, y: 1), color: tone.opacity(0.65))
                if !compact {
                    // 笔记刻度只在页边留白内，长文、字号与滚动不会让横线穿过文字。
                    line(&context, from: CGPoint(x: 12, y: 24), to: CGPoint(x: 12, y: size.height - 24), color: tone.opacity(0.16))
                    for y in stride(from: 72.0, to: max(72, size.height - 24), by: 28) {
                        line(&context, from: CGPoint(x: 12, y: y), to: CGPoint(x: 18, y: y), color: tone.opacity(0.2))
                    }
                }
            case .ticket:
                let x = size.width - (compact ? 12.0 : 16.0)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 16))
                path.addLine(to: CGPoint(x: x, y: size.height - 16))
                context.stroke(path, with: .color(tone.opacity(0.28)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                if !compact {
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 5)), with: .color(tone.opacity(0.15)))
                    for x in [-7.0, size.width - 7] {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: size.height * 0.45, width: 14, height: 24)), with: .color(.holoToolInset))
                    }
                }
            case .fold:
                let x: CGFloat = compact ? 12 : ThoughtPaperMetrics.foldRail
                line(&context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height), color: tone.opacity(0.2))
                line(&context, from: CGPoint(x: x + 2, y: 0), to: CGPoint(x: x + 2, y: size.height), color: tone.opacity(0.08))
                var fold = Path()
                fold.move(to: CGPoint(x: size.width - 20, y: 0))
                fold.addLine(to: CGPoint(x: size.width - 20, y: 20))
                fold.addLine(to: CGPoint(x: size.width, y: 20))
                fold.closeSubpath()
                context.fill(fold, with: .color(tone.opacity(0.1)))
            case .bookmark:
                let x = size.width - (compact ? 46.0 : 44.0)
                let width: CGFloat = compact ? 10 : 16
                let height: CGFloat = compact ? 25 : 44
                var ribbon = Path()
                ribbon.move(to: CGPoint(x: x, y: 0))
                ribbon.addLine(to: CGPoint(x: x + width, y: 0))
                ribbon.addLine(to: CGPoint(x: x + width, y: height))
                ribbon.addLine(to: CGPoint(x: x + width / 2, y: height - 6))
                ribbon.addLine(to: CGPoint(x: x, y: height))
                ribbon.closeSubpath()
                context.fill(ribbon, with: .color(tone.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func line(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color), lineWidth: 0.5)
    }
}

struct ThoughtWritingGuide: View {
    let style: ThoughtStyle
    var body: some View {
        Canvas { context, size in
            if style == .dots {
                for y in stride(from: 8.0, through: size.height, by: 12) {
                    for x in stride(from: 2.0, through: size.width, by: 12) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(style.accent.opacity(0.14)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
