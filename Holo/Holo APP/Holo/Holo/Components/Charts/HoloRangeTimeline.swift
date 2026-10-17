import SwiftUI

struct HoloTimelineSegment: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let label: String
    let color: Color
}

struct HoloRangeTimeline: View {
    let start: Date
    let end: Date
    let segments: [HoloTimelineSegment]
    @State private var selectedID: String?
    private var span: TimeInterval { max(end.timeIntervalSince(start), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(readout).font(.caption).foregroundStyle(Color.holoToolTextSecondary).monospacedDigit()
                .frame(minHeight: 30, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.holoToolInset)
                    ForEach(segments) { segment in
                        let left = max(segment.start, start).timeIntervalSince(start) / span * geometry.size.width
                        let right = min(segment.end, end).timeIntervalSince(start) / span * geometry.size.width
                        if right > left {
                            Rectangle().fill(segment.color).frame(width: right - left)
                                .overlay { if segment.id == selectedID { Rectangle().strokeBorder(Color.holoToolText, lineWidth: 2) } }
                                .offset(x: left)
                        }
                    }
                }
                .clipShape(Capsule())
                .overlay {
                    DirectionalChartGestureOverlay(onChanged: { inspect($0, width: geometry.size.width) },
                                                   onEnded: { _ in }, onCancelled: {},
                                                   onTap: { inspect($0, width: geometry.size.width) })
                }
            }.frame(height: 28)
        }
        .onChange(of: start) { _, _ in selectedID = nil }
        .onChange(of: end) { _, _ in selectedID = nil }
    }

    private var readout: String {
        guard let segment = segments.first(where: { $0.id == selectedID }) else { return "点击或横滑查看睡眠阶段" }
        return "\(segment.label) · \(HoloChartFormat.date(segment.start, template: "HHmm"))–\(HoloChartFormat.date(segment.end, template: "HHmm")) · \(Int(segment.end.timeIntervalSince(segment.start) / 60)) 分钟"
    }

    private func inspect(_ point: CGPoint, width: CGFloat) {
        guard width > 0 else { return }
        let date = start.addingTimeInterval(min(max(point.x / width, 0), 1) * span)
        selectedID = segments.first { $0.start <= date && date < $0.end }?.id
    }
}
