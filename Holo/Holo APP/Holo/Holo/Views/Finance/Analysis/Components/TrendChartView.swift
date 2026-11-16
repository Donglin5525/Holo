import SwiftUI

/// 收支与余额共用时间桶；余额独立分区保持真实数值轴。
/// 收支柱量级悬殊（最大值差三倍以上）时支出/收入各立数值轴（2026-11-01 东林实报
/// 「收入被支出压成矮柱」），量级接近时仍共轴直接可比；读数区恒显真实金额。
/// 下钻页复用同一张卡做联动：selectedDate 把列表侧选中日同步到图上，
/// onScrubDate 把图上点选/滑动回传定位列表（选日即定位，实时生效）。
/// 不传（总览/项目/账户页签）时行为与之前完全一致。
/// 卡头不挂「查看明细」：选日瞬间列表已定位，按钮再点必是空动作，
/// 2026-10-30 东林实报「点击没反应」后移除（套件能力保留，任务统计页仍在用）。
struct TrendChartView: View {
    let dataPoints: [ChartDataPoint]
    var showsBalanceLine: Bool = true
    var selectedDate: Date? = nil
    var onScrubDate: ((Date) -> Void)? = nil
    /// 收支卡「现金流」档（趋势 ⇄ 现金流分段切换）；nil = 无现金流可讲，不显示切换
    var waterfallItems: [HoloWaterfallItem]? = nil
    /// 横轴刻度走月界锚定（首刻度/跨月显「M.d」，其余只显日数）；明细页联动视图开启，
    /// 其余使用方默认关闭零变化（2026-11-16 东林拍板「趋势图时间再缩短」）
    var usesDayTickAnchors = false
    @State private var selection: String?
    @State private var showsCashflow = false

    private var flowBuckets: [HoloChartBucket] {
        dataPoints.map { point in
            HoloChartBucket(id: String(point.date.timeIntervalSince1970), label: point.label,
                            detail: ChartTooltipDateLabel.string(for: point, points: dataPoints),
                            values: [Double(truncating: point.expense as NSDecimalNumber),
                                     Double(truncating: point.income as NSDecimalNumber)],
                            isFuture: point.date > Date() && !point.hasTransactions,
                            date: point.date)
        }
    }
    private var balanceBuckets: [HoloChartBucket] {
        zip(flowBuckets, dataPoints).map { bucket, point in
            var result = bucket
            result.values = [Double(truncating: point.balance as NSDecimalNumber)]
            return result
        }
    }

    private func date(ofBucketID id: String) -> Date? {
        dataPoints.first { String($0.date.timeIntervalSince1970) == id }?.date
    }

    private var hasCashflow: Bool {
        guard let waterfallItems else { return false }
        return waterfallItems.count > 2   // 只有期初/期末两根锚柱时没有故事，不切
    }

    private var cardTitle: String {
        if hasCashflow, showsCashflow { return String(localized: "现金流 · 去向") }
        return showsBalanceLine ? String(localized: "收支与余额") : String(localized: "收支趋势")
    }

    var body: some View {
        // 零数据空态：不画 0-1 假坐标轴加零柱平线，占位无信息量还像渲染残缺
        //（11-05 挑刺专项E）；2026-11-15 空态引导：文案指路，不硬塞按钮（记一笔入口在财务模块本身）
        if dataPoints.allSatisfy({ !$0.hasTransactions }) {
            HoloChartFrame(title: showsBalanceLine ? "收支与余额" : "收支趋势", independent: true) {
                VStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.holoTextPlaceholder)
                        .accessibilityHidden(true)
                    Text("这个期间还没有收支记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text("记一笔，下次打开就能看到收支走势。")
                        .font(.caption)
                        .foregroundColor(.holoTextSecondary.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            }
        } else {
            HoloChartFrame(title: hasCashflow ? "" : cardTitle, independent: true) {
                if hasCashflow {
                    HStack {
                        Text(cardTitle)
                            .font(.headline)
                            .foregroundStyle(Color.holoToolText)
                        Spacer()
                        cashflowSwitch
                    }
                }
                if hasCashflow, showsCashflow {
                    HoloWaterfallChart(items: waterfallItems ?? [],
                                       valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" })
                } else {
                    HoloBarChart(buckets: flowBuckets,
                                 series: [.init(id: "expense", title: "支出", color: .holoError),
                                          .init(id: "income", title: "收入", color: .holoSuccess)],
                                 selection: $selection, height: 160, dualValueAxes: true,
                                 valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" },
                                 xAxisTickStyle: usesDayTickAnchors ? .dayWithMonthAnchor : .bucketLabel,
                                 onInspect: { bucket in
                                     if let date = date(ofBucketID: bucket.id) { onScrubDate?(date) }
                                 })
                    if showsBalanceLine {
                        HoloLineChart(buckets: balanceBuckets, series: [.init(id: "balance", title: "余额", color: .holoChartInk)],
                                      selection: $selection, height: 80,
                                      valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" })
                    }
                }
            }
            .onChange(of: selectedDate) { _, date in
                if let date, let point = dataPoints.last(where: { $0.date <= date }) {
                    selection = String(point.date.timeIntervalSince1970)
                } else { selection = nil }
            }
        }
    }

    /// 趋势 ⇄ 现金流分段切换（灰轨白块，与类别卡/习惯回顾同一语言）
    private var cashflowSwitch: some View {
        HStack(spacing: 0) {
            cashflowSegment(String(localized: "趋势"), active: !showsCashflow) {
                if !showsCashflow { return }
                showsCashflow = false
            }
            cashflowSegment(String(localized: "现金流"), active: showsCashflow) {
                if showsCashflow { return }
                showsCashflow = true
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.holoToolInset))
    }

    private func cashflowSegment(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .holoToolText : .holoToolTextSecondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.holoToolSurface : .clear)
                        .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1.5, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}
