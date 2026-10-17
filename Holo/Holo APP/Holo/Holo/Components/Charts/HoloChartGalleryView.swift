import SwiftUI

/// 只在调试启动参数下展示的原生样板；不写入业务数据。
struct HoloChartGalleryView: View {
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-HoloChartGallery")
        #else
        false
        #endif
    }
    @State private var tab = 0
    @State private var selection: String?
    @State private var heatSelection: Date?
    @State private var heatID = "未选中"
    @State private var generation = 0
    @State private var plotFrame: CGRect = .zero
    private let calendar = Calendar(identifier: .gregorian)
    /// 测试坐标是机器数据，不能用本地化插值；宽度过千时千位逗号会破坏解析。
    private var geometryValue: String {
        [plotFrame.minX, plotFrame.minY, plotFrame.width, plotFrame.height]
            .map { String(Double($0)) }.joined(separator: "|")
    }
    private var origin: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)) ?? Date() }
    private var buckets: [HoloChartBucket] {
        (0..<12).map { index in
            HoloChartBucket(id: "slot-\(index)", label: "\(index + 1)日",
                            values: [index == 2 ? nil : Double(index * 10), Double(index * 5)], isFuture: index == 11)
        }
    }
    private var days: [HoloHeatmapDay] {
        (0..<84).map { index in
            HoloHeatmapDay(date: calendar.date(byAdding: .day, value: index, to: origin) ?? origin,
                           count: index % 12, isFuture: index >= 82)
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("样板类型", selection: $tab) {
                        Text("柱状").tag(0)
                        Text("折线").tag(1)
                        Text("格子").tag(2)
                        Text("占比").tag(3)
                        Text("排名").tag(4)
                    }.pickerStyle(.segmented)
                    Text(tab == 2 ? heatID : (selection ?? "未选中"))
                        .accessibilityIdentifier("chart.gallery.selection")
                    Text("绘图区")
                        .font(.caption2)
                        .accessibilityValue(Text(verbatim: geometryValue))
                        .accessibilityIdentifier("chart.gallery.geometry")
                    Button("切换周期") { generation += 1; selection = nil; heatSelection = nil; heatID = "未选中" }
                        .frame(minHeight: 44).accessibilityIdentifier("chart.gallery.reset")
                    sample.id(generation)
                    HStack(spacing: 24) {
                        HoloProgress(value: nil, shape: .ring).frame(width: 48, height: 48)
                        HoloProgress(value: 0, shape: .ring).frame(width: 48, height: 48)
                        HoloProgress(value: 1.4, shape: .ring).frame(width: 48, height: 48)
                    }.padding(8)
                    Color.clear.frame(height: 420)
                    Text("页尾验证").accessibilityIdentifier("chart.gallery.footer")
                }.padding(20)
            }
            .background(Color.holoToolBackground)
            .navigationTitle("图表组件验收")
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-HoloChartGalleryDark") ? .dark : nil)
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("-HoloChartGalleryLargeType") ? .accessibility2 : .large)
            .onPreferenceChange(HoloChartPlotFrameKey.self) { plotFrame = $0 }
            .onChange(of: tab) { _, _ in selection = nil; heatSelection = nil; heatID = "未选中" }
        }
    }
    @ViewBuilder private var sample: some View {
        switch tab {
        case 0:
            HoloBarChart(buckets: buckets, series: series, selection: $selection)
        case 1:
            HoloLineChart(buckets: buckets, series: Array(series.prefix(1)), selection: $selection)
        case 2:
            HoloHeatmap(days: days, weekdayLabels: ["一", "", "三", "", "五", "", ""], selectedDate: heatSelection) { day in
                heatSelection = day.date
                heatID = "heat-\(calendar.dateComponents([.day], from: origin, to: day.date).day ?? -1)"
            }
        case 3:
            HoloDonutChart(segments: [
                .init(id: "large", name: "主要分类", weight: 999, valueText: "999", color: .holoChart1),
                .init(id: "tiny", name: "极小分类", weight: 1, valueText: "1", color: .holoChart2)
            ], selectedID: selection, centerText: "1000", onSelect: { selection = $0 })
        default:
            HoloBarChart(buckets: Array(buckets.prefix(4)), series: Array(series.prefix(1)), orientation: .horizontal, selection: $selection)
        }
    }
    private var series: [HoloChartSeries] {
        [.init(id: "first", title: "记录", color: .holoPrimary), .init(id: "second", title: "对照", color: .holoChart1)]
    }
}

#Preview("图表原生样板") { HoloChartGalleryView() }
