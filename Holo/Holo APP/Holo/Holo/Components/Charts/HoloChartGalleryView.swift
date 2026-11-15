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
    /// 走查启动参数：-HoloChartGalleryTab=N 直接落在第 N 个样板（验收工具走启动参数，不进 App 界面）
    private static let initialTab: Int = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-HoloChartGalleryTab=") }),
              let value = arg.split(separator: "=").last, let n = Int(value) else { return 0 }
        return min(max(n, 0), 8)
    }()
    @State private var tab = HoloChartGalleryView.initialTab
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
    /// 双轴样板：支出与收入量级悬殊（约 8 倍），右轴=支出、左轴=收入各自刻度。
    private var dualBuckets: [HoloChartBucket] {
        let expense = [1800, 2600, 1500, 3200, 900, 2400]
        let income = [120, 260, 90, 420, 60, 300]
        return (0..<6).map { index in
            HoloChartBucket(id: "dual-\(index)", label: "\(index + 1)日",
                            detail: "第\(index + 1)天", values: [Double(expense[index]), Double(income[index])])
        }
    }
    private var days: [HoloHeatmapDay] {
        (0..<84).map { index in
            HoloHeatmapDay(date: calendar.date(byAdding: .day, value: index, to: origin) ?? origin,
                           count: index % 12, isFuture: index >= 82)
        }
    }
    /// 构成趋势样板：三层、六桶，末桶「其他」增厚
    private var stackBuckets: [HoloStackedAreaBucket] {
        (1...6).map { HoloStackedAreaBucket(id: "m\($0)", label: "\($0)月", detail: "2026 年 \($0) 月") }
    }
    private var stackSeries: [HoloStackedAreaSeries] {
        [
            .init(id: "base", title: "居住", color: .holoChart1, values: [220, 220, 220, 220, 220, 220]),
            .init(id: "mid", title: "餐饮", color: .holoChart2, values: [118, 124, 109, 128, 115, 128]),
            .init(id: "top", title: "其他", color: .holoChart5, values: [202, 132, 134, 142, 147, 178])
        ]
    }
    /// 瀑布样板（真实极端量级回归：存量 7.4 万 vs 流水千元级，验证横向瀑布零线定标不挤压）：
    /// 74660.68 + 6150 + 3400 − 5426.22 − 2208.30 − 1074.90 − 1526.53 = 73974.73
    private var waterfallItems: [HoloWaterfallItem] {
        [
            .init(id: "open", label: "期初", total: 74_660.68),
            .init(id: "inc-top", label: "投资理财", delta: 6_150),
            .init(id: "inc-rest", label: "其他收入", delta: 3_400),
            .init(id: "exp-1", label: "居住", delta: -5_426.22),
            .init(id: "exp-2", label: "餐饮", delta: -2_208.30),
            .init(id: "exp-3", label: "其他", delta: -1_074.90),
            .init(id: "exp-rest", label: "其余 3 类", delta: -1_526.53),
            .init(id: "close", label: "期末", total: 73_974.73)
        ]
    }
    /// 增强折线样板：峰 41 / 谷 30，区间带 20–40
    private var measureBuckets: [HoloChartBucket] {
        let values: [Double] = [36, 39, 35, 41, 34, 38, 33, 40, 32, 37, 30, 35]
        return values.indices.map {
            HoloChartBucket(id: "m-\($0)", label: "\($0 + 1)日", values: [values[$0]])
        }
    }
    private var miniPoints: [HoloMiniTrendChart.Point] {
        let offsets = [0, 2, 5, 9, 14, 20, 27]
        let values = [38.5, 38.1, 37.6, 37.9, 37.2, 36.8, 36.4]
        return offsets.indices.map {
            .init(date: calendar.date(byAdding: .day, value: offsets[$0], to: origin) ?? origin, value: values[$0])
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
                        Text("双轴").tag(5)
                        Text("构成").tag(6)
                        Text("瀑布").tag(7)
                        Text("增强").tag(8)
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
            VStack(spacing: 24) {
                HoloDonutChart(segments: [
                    .init(id: "large", name: "主要分类", weight: 999, valueText: "999", color: .holoChart1),
                    .init(id: "tiny", name: "极小分类", weight: 1, valueText: "1", color: .holoChart2)
                ], selectedID: selection, centerText: "1000", onSelect: { selection = $0 })
                // 回归场景 2026-11-08：50/50 双清单长名（任务统计实录）——
                // 长名塞不进环带，须整体挪行末且不与引导线/占比叠字；短名走环带内。
                // 横向内边距补齐任务统计卡片的卡内边距，宽度与实页一致（窄宽下长名走截断）
                HoloDonutChart(segments: [
                    .init(id: "task-long", name: "Holo 开发任务", weight: 1, valueText: "1 件", color: .holoChart1),
                    .init(id: "task-inbox", name: "收件箱", weight: 1, valueText: "1 件", color: .holoChart2)
                ], selectedID: selection, centerText: "2 件", onSelect: { selection = $0 })
                .padding(.horizontal, HoloSpacing.md)
            }
        case 5:
            HoloBarChart(buckets: dualBuckets,
                         series: [.init(id: "expense", title: "支出", color: .holoChartOutflow),
                                  .init(id: "income", title: "收入", color: .holoChartInflow)],
                         selection: $selection, dualValueAxes: true)
        case 6:
            HoloStackedAreaChart(buckets: stackBuckets, series: stackSeries,
                                 selection: $selection, summary: "近 6 月")
        case 7:
            HoloWaterfallChart(items: waterfallItems)
        case 8:
            VStack(alignment: .leading, spacing: 20) {
                HoloBarChart(buckets: (0..<6).map {
                        HoloChartBucket(id: "r-\($0)", label: "\($0 + 1)日",
                                        values: [Double($0 * 10 + 15)])
                    },
                    series: [.init(id: "only", title: "支出", color: .holoChart2)],
                    selection: $selection,
                    rules: [HoloChartRule(value: 55, label: "月预算 55", color: .holoPrimary)],
                    comparison: HoloChartComparison(ghostValues: [8, 18, 28, 38, 48, 58]))
                HoloLineChart(buckets: measureBuckets,
                              series: [.init(id: "measure", title: "测量", color: .holoChart6)],
                              selection: $selection,
                              annotateExtrema: true, extremaUnit: " 单位",
                              band: 20...40)
                HoloBarChart(buckets: buckets, series: series, selection: $selection, legendToggle: true)
                HoloMiniTrendChart(points: miniPoints, color: .holoChart6, title: "样例测量")
            }
        default:
            HoloBarChart(buckets: Array(buckets.prefix(4)), series: Array(series.prefix(1)), orientation: .horizontal, selection: $selection)
        }
    }
    private var series: [HoloChartSeries] {
        [.init(id: "first", title: "记录", color: .holoPrimary), .init(id: "second", title: "对照", color: .holoChart1)]
    }
}

#Preview("图表原生样板") { HoloChartGalleryView() }
