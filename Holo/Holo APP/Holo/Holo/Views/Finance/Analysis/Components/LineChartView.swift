import SwiftUI

/// 财务适配器只负责口径和列表联动；绘制、空桶与命中全部交给共享图表。
struct LineChartView: View {
    let dataPoints: [ChartDataPoint]
    let selectedDate: Date?
    var displayedType: TransactionType = .expense
    var displayedTypeSelection: Binding<TransactionType>? = nil
    /// 旧副标题「横向滑动，明细实时定位」与图表 idle 态提示「左右滑动查看每日金额」语义重复，默认不再显示
    var subtitle: String = ""
    var onScrubDate: ((Date) -> Void)? = nil
    let onSelectDate: (Date?) -> Void
    @State private var selection: String?

    private var buckets: [HoloChartBucket] {
        dataPoints.map { point in
            HoloChartBucket(id: String(point.date.timeIntervalSince1970), label: point.label,
                            detail: ChartTooltipDateLabel.string(for: point, points: dataPoints),
                            values: [Double(truncating: (displayedType == .expense ? point.expense : point.income) as NSDecimalNumber)],
                            isFuture: point.date > Date() && !point.hasTransactions)
        }
    }

    var body: some View {
        HoloChartFrame(title: "收支趋势", subtitle: subtitle, independent: true) {
            if let displayedTypeSelection {
                Picker("趋势类型", selection: displayedTypeSelection) {
                    Text("支出").tag(TransactionType.expense)
                    Text("收入").tag(TransactionType.income)
                }.pickerStyle(.segmented)
            }
            HoloLineChart(buckets: buckets,
                          series: [.init(id: displayedType.rawValue, title: displayedType.displayName,
                                         color: displayedType == .expense ? .holoError : .holoSuccess)],
                          selection: $selection, height: 150,
                          yDomain: HoloChartGeometry.niceDomain(values: buckets.flatMap(\.values).compactMap { $0 }, includesZero: true),
                          // 未选中日的 idle 读数取末桶值（无交易日即 ¥0.00），与曲线矛盾；
                          // 改为灰色提示文案，选中后才显示所指日期数值（2026-10-17 设计审查 C1）
                          summary: String(localized: "左右滑动查看每日金额"),
                          valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" },
                          hidesIdleValues: true,
                          onInspect: { bucket in
                              guard let point = dataPoints.first(where: { String($0.date.timeIntervalSince1970) == bucket.id }) else { return }
                              onScrubDate?(point.date)
                          },
                          onOpenDetail: { bucket in
                              onSelectDate(dataPoints.first { String($0.date.timeIntervalSince1970) == bucket.id }?.date)
                          })
        }
        .onChange(of: displayedType) { _, _ in selection = nil }
        .onChange(of: selectedDate) { _, date in
            if let date, let point = dataPoints.last(where: { $0.date <= date }) {
                selection = String(point.date.timeIntervalSince1970)
            } else { selection = nil }
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(Color.holoToolTextSecondary)
        }
    }
}
