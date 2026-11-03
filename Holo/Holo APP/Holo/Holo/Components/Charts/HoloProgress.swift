import SwiftUI

/// nil 表示尚无可用数据，和真实的 0 进度分开；超额部分由文字保留真实值。
struct HoloProgress: View {
    enum Shape { case ring, bar }
    let value: Double?
    var color: Color = .holoPrimary
    var shape: Shape = .bar
    var lineWidth: CGFloat = 10
    var trackColor: Color = .holoToolBorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fraction: Double { min(max(value ?? 0, 0), 1) }

    var body: some View {
        Group {
            if shape == .ring {
                ZStack {
                    Circle().stroke(trackColor, lineWidth: lineWidth)
                    if value != nil, fraction > 0 {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    if value == nil { Text("—").font(.caption).foregroundStyle(Color.holoToolTextSecondary) }
                }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(trackColor)
                        if value != nil, fraction > 0 {
                            Capsule().fill(color).frame(width: geometry.size.width * fraction)
                        }
                    }
                }
                .frame(height: lineWidth)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "完成 \(HoloChartFormat.number($0 * 100))%" } ?? "暂无进度数据")
    }
}

struct HoloProportionSegment: Identifiable {
    let id: String
    let label: String
    let weight: Double
    let color: Color
}

/// 构成比例条按总量精确归一；零份额不占宽，细小份额不会被强制放大。
struct HoloProportionBar: View {
    let segments: [HoloProportionSegment]
    var height: CGFloat = 8
    private var visible: [HoloProportionSegment] { segments.filter { $0.weight > 0 && $0.weight.isFinite } }
    var body: some View {
        GeometryReader { geometry in
            let total = visible.reduce(0) { $0 + $1.weight }
            let available = max(geometry.size.width - CGFloat(max(visible.count - 1, 0)) * 2, 0)
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    Capsule().fill(segment.color).frame(width: total > 0 ? available * segment.weight / total : 0)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visible.map { "\($0.label) \(HoloChartFormat.number($0.weight))" }.joined(separator: "，"))
    }
}
