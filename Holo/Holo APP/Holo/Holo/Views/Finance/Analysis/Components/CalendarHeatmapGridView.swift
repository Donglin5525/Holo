import SwiftUI

/// 兼容既有调用；布局、配色等级和二维选择均复用中立组件。
struct CalendarHeatmapGridView: View {
    typealias Day = HoloHeatmapDay
    let days: [Day]
    var weekdayLabels: [String] = []
    var showsMonthAxis = false
    var palette: Color.HoloHeatmapPalette = .mist
    var selectedDate: Date? = nil
    var onTapDay: ((Day) -> Void)? = nil

    var body: some View {
        HoloHeatmap(days: days, weekdayLabels: weekdayLabels, showsMonthAxis: showsMonthAxis,
                    palette: palette, selectedDate: selectedDate, onSelect: onTapDay)
    }
}
