import SwiftUI

/// 收支 / 余额 / 现金流三态独立图表（2026-11-26 原型 1:1 改版）：
/// - 一图只讲一件事：总览页提供「收支 | 余额 | 现金流」独立切换，告别同卡上下叠两张图占满首屏；
/// - 读数极简化：未选中时不复读顶部已展示的全月总额，仅在点按/横滑某天时浮出当天明细；
/// - 支持无卡纸本形态（isCardless = true）与紧凑形态（compactMode = true，给明细页用）。
struct TrendChartView: View {
    enum TrendPane: Hashable {
        case flow
        case balance
        case cashflow
    }

    let dataPoints: [ChartDataPoint]
    var showsBalanceLine: Bool = true
    var selectedDate: Date? = nil
    var onScrubDate: ((Date) -> Void)? = nil
    /// 收支卡「现金流」档（收支 ⇄ 余额 ⇄ 现金流）；nil = 无现金流可讲，不显示该分段
    var waterfallItems: [HoloWaterfallItem]? = nil
    /// 横轴刻度走月界锚定（首刻度/跨月显「M/d」，其余只显日数）
    var usesDayTickAnchors = false
    /// 无卡纸本形态：直接落在纸底上，不套白卡外壳
    var isCardless = false
    /// 紧凑形态（明细页顶部）：104pt 高度，去掉标题栏，单行极简读数
    var compactMode = false
    /// 紧凑形态下的默认读数汇总（支/收金额）
    var compactSummary: (expense: String, income: String)? = nil

    @State private var selection: String?
    @State private var activePane: TrendPane = .flow

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

    private func point(ofBucketID id: String?) -> ChartDataPoint? {
        guard let id else { return nil }
        return dataPoints.first { String($0.date.timeIntervalSince1970) == id }
    }

    private var hasCashflow: Bool {
        guard let waterfallItems else { return false }
        return waterfallItems.count > 2
    }

    private var availableModes: [TrendPane] {
        var result: [TrendPane] = [.flow]
        if showsBalanceLine { result.append(.balance) }
        if hasCashflow { result.append(.cashflow) }
        return result
    }

    private var sectionTitle: String {
        switch activePane {
        case .flow: return String(localized: "收支走势")
        case .balance: return String(localized: "余额走势")
        case .cashflow: return String(localized: "现金流 · 去向")
        }
    }

    var body: some View {
        let content = Group {
            if dataPoints.allSatisfy({ !$0.hasTransactions }) {
                emptyBody
            } else {
                activeBody
            }
        }
        if isCardless {
            content
                .onChange(of: selectedDate) { _, date in syncSelection(with: date) }
                .onChange(of: availableModes) { _, modes in
                    if !modes.contains(activePane) { activePane = .flow }
                }
        } else {
            HoloChartFrame(title: "", independent: true) {
                content
            }
            .onChange(of: selectedDate) { _, date in syncSelection(with: date) }
            .onChange(of: availableModes) { _, modes in
                if !modes.contains(activePane) { activePane = .flow }
            }
        }
    }

    private func syncSelection(with date: Date?) {
        if let date, let point = dataPoints.last(where: { $0.date <= date }) {
            selection = String(point.date.timeIntervalSince1970)
        } else {
            selection = nil
        }
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            if !compactMode {
                Text(sectionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
            }
            VStack(spacing: 6) {
                Text("这个期间还没有收支记录")
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Text("记一笔，下次打开就能看到收支走势。")
                    .font(.caption)
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .frame(height: compactMode ? 84 : 120)
        }
    }

    private var activeBody: some View {
        VStack(alignment: .leading, spacing: compactMode ? 8 : 12) {
            if !compactMode {
                HStack(alignment: .center) {
                    Text(sectionTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                    Spacer(minLength: 8)
                    if availableModes.count > 1 {
                        modeSwitch
                    }
                }
            }

            switch activePane {
            case .flow:
                flowReadoutRow
                HoloBarChart(
                    buckets: flowBuckets,
                    series: [
                        .init(id: "expense", title: "支出", color: .holoChartOutflow),
                        .init(id: "income", title: "收入", color: .holoChartInflow)
                    ],
                    selection: $selection,
                    height: compactMode ? 104 : 142,
                    dualValueAxes: true,
                    valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" },
                    showsReadout: false,
                    xAxisTickStyle: usesDayTickAnchors ? .dayWithMonthAnchor : .bucketLabel,
                    onInspect: { bucket in
                        if let pt = point(ofBucketID: bucket.id) { onScrubDate?(pt.date) }
                    }
                )
            case .balance:
                balanceReadoutRow
                HoloLineChart(
                    buckets: balanceBuckets,
                    series: [.init(id: "balance", title: "余额", color: .holoChartInk)],
                    selection: $selection,
                    height: 142,
                    valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" },
                    showsReadout: false
                )
            case .cashflow:
                HoloWaterfallChart(
                    items: waterfallItems ?? [],
                    valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" }
                )
            }
        }
    }

    // MARK: - 极简单行读数

    private var flowReadoutRow: some View {
        let selectedPoint = point(ofBucketID: selection)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let pt = selectedPoint {
                Text(ChartTooltipDateLabel.string(for: pt, points: dataPoints))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer(minLength: 6)
                HStack(spacing: 12) {
                    legendDotValue(color: .holoChartOutflow, value: formattedAmount(pt.expense))
                    if pt.income > 0 {
                        legendDotValue(color: .holoChartInflow, value: formattedAmount(pt.income))
                    }
                }
            } else if compactMode, let summary = compactSummary {
                HStack(spacing: 8) {
                    (Text("支 ") + Text(summary.expense).foregroundColor(.holoError).fontWeight(.semibold))
                    Text("·")
                    (Text("收 ") + Text(summary.income).foregroundColor(.holoChartInflow).fontWeight(.semibold))
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text("点柱定位")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
            } else {
                Text(endCaptionText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer(minLength: 6)
                HStack(spacing: 12) {
                    legendDotTitle(color: .holoChartOutflow, title: "支出")
                    legendDotTitle(color: .holoChartInflow, title: "收入")
                }
            }
        }
        .frame(minHeight: 20)
    }

    private var balanceReadoutRow: some View {
        let selectedPoint = point(ofBucketID: selection)
        let first = dataPoints.first
        let last = dataPoints.last
        let opening = first.map { $0.balance - $0.income + $0.expense } ?? 0
        let closing = last?.balance ?? 0
        let net = closing - opening

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let pt = selectedPoint {
                Text(ChartTooltipDateLabel.string(for: pt, points: dataPoints))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer(minLength: 6)
                Text("余额 \(formattedAmount(pt.balance))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.holoChartInk)
            } else {
                Text("期初 \(NumberFormatter.compactCurrency(opening)) → 期末 \(NumberFormatter.compactCurrency(closing))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                Text("净变动 \(net >= 0 ? "+" : "−")\(NumberFormatter.compactCurrency(abs(net)))")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.holoChartInk)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 20)
    }

    private var endCaptionText: String {
        guard let last = dataPoints.last else { return "" }
        if Calendar.current.isDateInToday(last.date) {
            return "截止今日（\(HoloChartFormat.date(last.date))）"
        }
        return "截止 \(HoloChartFormat.date(last.date))"
    }

    private func legendDotTitle(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11.5)).foregroundStyle(Color.holoToolTextSecondary)
        }
    }

    private func legendDotValue(color: Color, value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
        }
    }

    private func formattedAmount(_ value: Decimal) -> String {
        NumberFormatter.currency.string(from: value as NSDecimalNumber) ?? "¥0.00"
    }

    // MARK: - 轻量分段切换（灰轨白块 + 0.5pt 描边，无裸阴影）

    private var modeSwitch: some View {
        HStack(spacing: 1) {
            ForEach(availableModes, id: \.self) { item in
                modeSegment(title(for: item), active: activePane == item) {
                    if activePane == item { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = nil
                        activePane = item
                    }
                }
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.holoToolInset))
    }

    private func title(for item: TrendPane) -> String {
        switch item {
        case .flow: return String(localized: "收支")
        case .balance: return String(localized: "余额")
        case .cashflow: return String(localized: "现金流")
        }
    }

    private func modeSegment(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .holoToolText : .holoToolTextSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.holoToolSurface : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(active ? Color.holoToolBorder : .clear, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}
