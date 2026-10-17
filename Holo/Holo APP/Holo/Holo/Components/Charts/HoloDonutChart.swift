import SwiftUI
import Charts

struct HoloDonutSegment: Identifiable {
    let id: String
    let name: String
    let weight: Double
    let valueText: String
    let color: Color
}

struct HoloDonutChart: View {
    let segments: [HoloDonutSegment]
    let selectedID: String?
    var centerText = ""
    var showsList = true
    var onSelect: ((String?) -> Void)? = nil
    @State private var inspectedID: String?
    private var focused: String? { selectedID ?? inspectedID }
    private var total: Double { segments.reduce(0) { $0 + $1.weight } }

    var body: some View {
        VStack(spacing: 12) {
            Chart(segments) { segment in
                SectorMark(angle: .value("占比", segment.weight), innerRadius: .ratio(0.68), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(segment.color)
                    .annotation(position: .overlay) {
                        if focused == segment.id { Circle().fill(Color.holoToolSurface).frame(width: 7, height: 7) }
                    }
                    .accessibilityLabel(segment.name)
                    .accessibilityValue("\(segment.valueText)，\(percentage(segment))")
            }
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 3) {
                    Text(segments.first { $0.id == focused }?.name ?? "合计")
                        .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
                    Text(segments.first { $0.id == focused }?.valueText ?? centerText)
                        .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Color.holoToolText)
                }.padding(24).allowsHitTesting(false)
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        DirectionalChartGestureOverlay(onChanged: { select($0, frame: frame) }, onEnded: { _ in }, onCancelled: {},
                                                       onTap: { select($0, frame: frame) })
                    }
                }
            }
            .frame(height: 200)
            if showsList {
            ForEach(segments) { segment in
                Button { apply(segment.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.name).foregroundStyle(Color.holoToolText)
                        Spacer(minLength: 4)
                        Text(segment.valueText).foregroundStyle(Color.holoToolText).monospacedDigit()
                        Text(percentage(segment)).foregroundStyle(Color.holoToolTextSecondary).monospacedDigit()
                    }
                    .font(.subheadline).padding(.horizontal, 8).frame(minHeight: 44)
                    .background(focused == segment.id ? Color.holoToolInset : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("holo.donut.segment.\(segment.id)")
            }
            }
        }
        .onChange(of: segments.map { "\($0.id):\($0.weight)" }) { _, _ in inspectedID = nil }
        .onChange(of: selectedID) { _, id in inspectedID = id }
    }

    private func percentage(_ segment: HoloDonutSegment) -> String {
        String(format: "%.1f%%", total > 0 ? segment.weight / total * 100 : 0)
    }

    private func select(_ point: CGPoint, frame: CGRect) {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = hypot(dx, dy)
        guard distance >= radius * 0.68, distance <= radius, total > 0 else { return }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += .pi * 2 }
        let weight = angle / (.pi * 2) * total
        var cumulative = 0.0
        for segment in segments {
            cumulative += segment.weight
            if weight <= cumulative { apply(segment.id); return }
        }
    }

    private func apply(_ id: String) {
        guard inspectedID != id else { return }
        inspectedID = id
        onSelect?(id)
    }
}
