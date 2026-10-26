import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Foundation

struct HoloHeatmapDay: Identifiable, Equatable {
    let date: Date
    let count: Int
    let isFuture: Bool
    var id: Date { date }
}

/// 列为周、行为周几。绘制与二维命中共同使用同一个等分槽位。
struct HoloHeatmap: View {
    let days: [HoloHeatmapDay]
    var weekdayLabels: [String] = []
    var showsMonthAxis = true
    var palette: Color.HoloHeatmapPalette = .mist
    var selectedDate: Date? = nil
    var onSelect: ((HoloHeatmapDay) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var inspectedDate: Date?
    @State private var containerWidth: CGFloat = 320
    private var labelWidth: CGFloat { weekdayLabels.count == 7 ? 22 : 0 }
    private var gridHeight: CGFloat { max(containerWidth - labelWidth, 1) / CGFloat(weeks) * 7 }

    private var weeks: Int { max(Int(ceil(Double(days.count) / 7)), 1) }
    private var focusedDate: Date? { selectedDate ?? inspectedDate }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let day = days.first(where: { $0.date == focusedDate }) {
                Text("\(HoloChartFormat.date(day.date, template: "yMMMd")) · \(day.count) 条")
                    .font(.caption).monospacedDigit().foregroundStyle(Color.holoToolText)
            } else {
                Text("点按查看 · 按住滑选日期")
                    .font(.caption).foregroundStyle(Color.holoToolTextSecondary)
            }
            GeometryReader { geometry in
                let width = max(geometry.size.width - labelWidth, 1)
                let pitch = width / CGFloat(weeks)
                VStack(spacing: 0) {
                    if showsMonthAxis {
                        monthAxis(pitch: pitch).padding(.leading, labelWidth).frame(height: 20).allowsHitTesting(false)
                    }
                    HStack(spacing: weekdayLabels.count == 7 ? 6 : 0) {
                        if weekdayLabels.count == 7 {
                            VStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { row in
                                    Text(weekdayLabels[row]).font(.caption2).foregroundStyle(Color.holoToolTextSecondary)
                                        .frame(width: 16, height: pitch)
                                }
                            }
                        }
                        grid(width: width, pitch: pitch)
                    }
                }
                .onAppear { containerWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in containerWidth = width }
            }
            .frame(height: gridHeight + (showsMonthAxis ? 20 : 0))
        }
        .onChange(of: selectedDate) { _, date in inspectedDate = date }
        .onChange(of: days) { _, _ in inspectedDate = nil }
    }

    private func monthAxis(pitch: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<weeks, id: \.self) { week in
                Text(monthLabel(week)).font(.caption2).foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: pitch, alignment: .leading)
            }
        }
    }

    private func monthLabel(_ week: Int) -> String {
        guard days.indices.contains(week * 7) else { return "" }
        let date = days[week * 7].date
        if week == 0 || Calendar.current.component(.month, from: days[(week - 1) * 7].date) != Calendar.current.component(.month, from: date) {
            return HoloChartFormat.date(date, template: "M月")
        }
        return ""
    }

    private func grid(width: CGFloat, pitch: CGFloat) -> some View {
        let size = CGSize(width: width, height: pitch * 7)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                let selected = focusedDate.map { Calendar.current.isDate($0, inSameDayAs: day.date) } ?? false
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.holoHeatmapColor(level: HoloChartGeometry.countLevel(day.count), palette: palette, colorScheme: colorScheme))
                    .overlay {
                        if selected { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.holoPrimary, lineWidth: 2) }
                    }
                    .opacity(day.isFuture ? 0.3 : 1)
                    .frame(width: max(pitch - 3, 1), height: max(pitch - 3, 1))
                    .position(x: (CGFloat(index / 7) + 0.5) * pitch, y: (CGFloat(index % 7) + 0.5) * pitch)
                    .accessibilityLabel("\(HoloChartFormat.date(day.date, template: "yMMMd")) · \(day.count) 条")
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                    .accessibilityAction { select(index) }
                    .accessibilityHidden(day.isFuture)
            }
            HoloHeatmapGestureOverlay { point in
                guard let index = HoloChartGeometry.heatmapIndex(point: point, size: size, weeks: weeks) else { return }
                select(index)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holo.heatmap.grid")
    }

    private func select(_ index: Int) {
        guard days.indices.contains(index), !days[index].isFuture, focusedDate != days[index].date else { return }
        inspectedDate = days[index].date
        onSelect?(days[index])
    }
}

#if canImport(UIKit)
private struct HoloHeatmapGestureOverlay: UIViewRepresentable {
    let onSelect: (CGPoint) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 10
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onSelect = onSelect }
    final class Coordinator: NSObject {
        var onSelect: (CGPoint) -> Void
        init(onSelect: @escaping (CGPoint) -> Void) { self.onSelect = onSelect }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onSelect(gesture.location(in: gesture.view)) }
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed { onSelect(gesture.location(in: gesture.view)) }
        }
    }
}

#else
/// macOS：无 UILongPress/UITap 体系，用带位置的点按 + 长按拖动等价实现
private struct HoloHeatmapGestureOverlay: View {
    let onSelect: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { location in
                onSelect(location)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSelect(value.location)
                    }
            )
    }
}
#endif
