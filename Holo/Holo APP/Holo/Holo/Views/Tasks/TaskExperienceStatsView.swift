//
//  TaskExperienceStatsView.swift
//  Holo
//
//  统计页 V2（2026-10-06 任务重构方案 §7）：期间选择（真实期间）→ 新增/完成/按时率 →
//  双系列趋势 → 清单分布 → 可核对观察 → 当前待处理（截至现在）→ 全部明细。
//  统计覆盖全部未删除任务，不跟随首页筛选。
//

import SwiftUI

struct TaskExperienceStatsView: View {

    @ObservedObject var repository: TodoRepository
    let onBack: () -> Void

    @StateObject private var model = TaskStatsViewModel()

    /// 明细弹层状态
    @State private var drilldown: DrilldownKind? = nil
    @State private var bucketDrilldown: TaskAnalyticsBucketStat? = nil
    @State private var listDrilldown: TaskListBreakdownStat? = nil
    /// 全期趋势明细（「查看趋势明细」按钮）
    @State private var showTrendDrilldown = false
    /// 趋势卡视角：数量双柱 ⇄ 到期完成率折线
    @State private var trendMode: TaskStatsTrendChart.Mode = .counts
    /// 事项完成明细弹层（P2）
    @State private var matterDrilldown: TaskMatterBreakdownStat? = nil
    /// 热力图选中日（P2；nil=未选）
    @State private var selectedListSegmentID: String?
    @State private var selectedHeatDay: CalendarHeatmapGridView.Day? = nil

    @Environment(\.colorScheme) private var colorScheme

    enum DrilldownKind: String, Identifiable {
        case created
        case completed
        case onTimeDenominator
        case missingTime
        case attentionOverdue
        case attentionUnscheduled
        case attentionUnclassified

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    if model.loadFailed && model.analytics != nil {
                        staleDataBanner
                    }
                    if model.dataUpdatedWhileViewing {
                        dataUpdatedBanner
                    }
                    if let analytics = model.analytics {
                        periodBar(analytics)
                        overviewCard(analytics)
                        trendCard(analytics)
                        heatCard(analytics)
                        if analytics.completedCount == 0 {
                            // 时刻/清单/事项三卡同空：合并成一张空态卡，不再三张同句空卡
                            completedEmptyCard
                        } else {
                            hourCard(analytics)
                            listBreakdownCard(analytics)
                            matterCard(analytics)
                        }
                        todayPlanCard()
                        attentionCard(analytics)
                        footnotes(analytics)
                    } else if model.isLoading {
                        loadingView
                    } else {
                        failView
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)

                // 右下浮动「新增」让位：expanded 宽无底部栏时浮钮整体更高，末卡需额外 96pt 才不被压住
                Color.clear.frame(height: 96)
            }
        }
        .background(Color.holoBackground)
        .task {
            await CoreDataStack.shared.waitUntilReady()
            model.reload()
        }
        .onChange(of: model.period) { _, _ in
            selectedListSegmentID = nil
            selectedHeatDay = nil
        }
        .sheet(item: $drilldown) { kind in
            TaskStatsDrilldownSheet(model: model, kind: kind, repository: repository)
        }
        .sheet(item: $bucketDrilldown) { bucket in
            TaskStatsBucketDrilldownSheet(model: model, bucket: bucket)
        }
        .sheet(isPresented: $showTrendDrilldown) {
            if let analytics = model.analytics {
                TaskStatsTrendDrilldownSheet(model: model, analytics: analytics)
            }
        }
        .sheet(item: $listDrilldown) { stat in
            TaskStatsListDrilldownSheet(model: model, stat: stat)
        }
        .sheet(item: $matterDrilldown) { stat in
            TaskStatsMatterDrilldownSheet(model: model, stat: stat)
        }
    }

    // MARK: - 头部

    private var headerView: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.holoNestedCardBackground))
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text("返回"))
            Spacer()
            VStack(spacing: 1) {
                Text("统计")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                Text("全部任务")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer()
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, HoloSpacing.page)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 期间条（档位 + 箭头 + 完整日期）

    private func periodBar(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(TaskStatsViewModel.PeriodKind.allCases, id: \.self) { kind in
                        Button {
                            model.kind = kind
                        } label: {
                            if model.kind == kind {
                                Label(kind.title, systemImage: "checkmark")
                            } else {
                                Text(kind.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.periodBadgeTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.holoPrimary))
                }

                Spacer()

                periodArrow(direction: .previous)
                periodArrow(direction: .next)
            }

            // 具体日期范围始终可见（§7.1）；进行中期的「截至」次信息独立成行，长串混排会折出孤行
            VStack(alignment: .leading, spacing: 2) {
                Text(model.rangeTitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                if let asOf = model.asOfTitle {
                    Text(asOf)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.kind == .custom {
                customPickers
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    private enum PeriodDirection {
        case previous, next
    }

    private func periodArrow(direction: PeriodDirection) -> some View {
        let enabled = direction == .previous ? model.canGoPrevious : model.canGoNext
        return Button {
            if direction == .previous { model.goPrevious() } else { model.goNext() }
        } label: {
            Image(systemName: direction == .previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(enabled ? .holoTextPrimary : .holoTextPlaceholder)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.holoBackground))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(direction == .previous ? String(localized: "上一周期") : String(localized: "下一周期"))
    }

    /// 自定义起止（含首尾自然日；错误就地说明，§7.2）
    @ViewBuilder
    private var customPickers: some View {
        VStack(spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.sm) {
                DatePicker(String(localized: "开始"), selection: $model.customStart, displayedComponents: [.date])
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                DatePicker(String(localized: "结束"), selection: $model.customEnd, displayedComponents: [.date])
                    .environment(\.locale, Locale(identifier: "zh_CN"))
            }
            if let message = model.customValidationMessage {
                Text(message)
                    .font(.holoCaption)
                    .foregroundColor(.holoToolError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 指标卡（这段时间推进了多少）

    private func overviewCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Text("这段时间推进了多少")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: HoloSpacing.sm) {
                statBlock(
                    title: String(localized: "完成"),
                    value: "\(analytics.completedCount)",
                    sub: model.deltaText(analytics.comparison.completedDelta)
                ) {
                    drilldown = .completed
                }
                statBlock(
                    title: String(localized: "完成率"),
                    value: rateText(analytics.onTime.completionRate),
                    sub: dueCompletionSubText(analytics),
                    delta: rateDeltaText(
                        analytics.onTime.completionRate,
                        analytics.comparison.previousDueCompletionRate
                    )
                ) {
                    drilldown = .onTimeDenominator
                }
                statBlock(
                    title: String(localized: "新增"),
                    value: "\(analytics.createdCount)",
                    sub: model.deltaText(analytics.comparison.createdDelta)
                ) {
                    drilldown = .created
                }
                statBlock(
                    title: String(localized: "按时率"),
                    value: rateText(analytics.onTime.rate),
                    sub: onTimeSub(analytics),
                    delta: rateDeltaText(
                        analytics.onTime.rate,
                        analytics.comparison.previousOnTimeRate
                    )
                ) {
                    drilldown = .onTimeDenominator
                }
            }

            if analytics.comparison.truncatedToPreviousEnd {
                Text("上期较短，对比至上期结束")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    /// 比率文案：无数值（零分母）显示「—」
    private func rateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    /// 率差文案：上期基线为 0（或无数据）、或本期值本身就是 0 时，涨跌百分比无意义
    ///（0 完成的一周渲染「-100%」纯属红警噪音，下滑信号已由「较上期少 N 项」承担），
    /// 改显示中性「—」；基线与本期都有效才显示百分点差
    private func rateDeltaText(_ current: Double?, _ previous: Double?) -> (text: String, positive: Bool?)? {
        guard let current else { return nil }
        guard (previous ?? 0) > 0 else { return ("—", nil) }
        guard current > 0 else { return ("—", nil) }
        guard let delta = model.rateDeltaPercentage(current, previous) else { return nil }
        return (delta.text, delta.positive)
    }

    /// 率差颜色：positive 为 nil 时是基线无效的中性「—」，不染红绿
    private func deltaTextColor(_ positive: Bool?) -> Color {
        if positive == true { return .holoSuccess }
        if positive == false { return .holoError }
        return .holoTextPlaceholder
    }

    /// 完成率副文案：到期的事里完成了几成（按时 + 迟到）；窄列文案锁 6-8 字宽，长版会折出「任务」孤字
    private func dueCompletionSubText(_ analytics: TaskAnalyticsSnapshot) -> String {
        guard analytics.onTime.denominatorCount > 0 else {
            return String(localized: "暂无到期任务")
        }
        let dueDone = analytics.onTime.onTimeCount + analytics.onTime.lateCount
        return String(localized: "\(dueDone)/\(analytics.onTime.denominatorCount) 到期完成")
    }

    private func onTimeSub(_ analytics: TaskAnalyticsSnapshot) -> String {
        guard analytics.onTime.denominatorCount > 0 else {
            return String(localized: "暂无到期任务")
        }
        return String(localized: "\(analytics.onTime.onTimeCount)/\(analytics.onTime.denominatorCount) 按时完成")
    }

    private func statBlock(
        title: String,
        value: String,
        sub: String,
        delta: (text: String, positive: Bool?)? = nil,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                VStack(spacing: 2) {
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                    if let delta {
                        Text(delta.text)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(deltaTextColor(delta.positive))
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 30, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 双系列趋势图（§7.7；数量 ⇄ 完成率双视角）

    private func trendCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("新增与完成趋势")
                    .font(.holoBody.bold())
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Picker(String(localized: "趋势视角"), selection: $trendMode) {
                    Text("数量").tag(TaskStatsTrendChart.Mode.counts)
                    Text("完成率").tag(TaskStatsTrendChart.Mode.dueCompletionRate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 136)
            }

            if isTrendEmpty(analytics) {
                trendEmptyState
            } else {
                if trendMode == .counts {
                    trendLegend
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TaskStatsTrendChart(buckets: analytics.buckets, mode: trendMode) { bucket in
                    bucketDrilldown = bucket
                }
            }

            if !isTrendEmpty(analytics) {
                Button {
                    showTrendDrilldown = true
                } label: {
                    Label(String(localized: "查看趋势明细"), systemImage: "list.bullet")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    private var trendLegend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().fill(Color.holoPrimary.opacity(0.75)).frame(width: 7, height: 7)
                Text("新增").font(.holoTinyLabel).foregroundColor(.holoTextSecondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.holoSuccess.opacity(0.75)).frame(width: 7, height: 7)
                Text("完成").font(.holoTinyLabel).foregroundColor(.holoTextSecondary)
            }
        }
    }

    /// 趋势是否全空（无桶，或所有桶新增/完成均为 0）：空图不绘坐标轴，避免孤立刻度标签（如「1」）
    private func isTrendEmpty(_ analytics: TaskAnalyticsSnapshot) -> Bool {
        analytics.buckets.allSatisfy { $0.createdIDs.isEmpty && $0.completedIDs.isEmpty }
    }

    /// 趋势空态：整块绘图区换成居中提示（占位高度对齐图表 160pt，数据出现/消失时卡片不跳动）
    private var trendEmptyState: some View {
        VStack(spacing: 6) {
            Text(String(localized: "本期还没有完成记录"))
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text(String(localized: "完成的任务会画成趋势图"))
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: - 完成节奏热力图（P2：固定近 12 个自然周，不随档位）

    private func heatCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("完成节奏 · 近 12 周")
                    .font(.holoBody.bold())
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                heatLegend
            }

            CalendarHeatmapGridView(
                days: heatDays(analytics),
                weekdayLabels: [String(localized: "一"), "", String(localized: "三"), "", String(localized: "五"), "", ""],
                showsMonthAxis: true,
                palette: .mist,
                selectedDate: selectedHeatDay?.date
            ) { day in
                selectedHeatDay = day
            }

            if let selected = selectedHeatDay {
                Text(heatSelectionText(selected))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    private var heatLegend: some View {
        HStack(spacing: 3) {
            Text("少")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
            ForEach(0...5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.holoHeatmapColor(level: level, palette: .mist, colorScheme: colorScheme))
                    .frame(width: 10, height: 10)
            }
            Text("多")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
        }
    }

    private func heatDays(_ analytics: TaskAnalyticsSnapshot) -> [CalendarHeatmapGridView.Day] {
        let todayStart = model.calendar.startOfDay(for: Date())
        return analytics.heatDays.map { day in
            CalendarHeatmapGridView.Day(
                date: day.start,
                count: day.completedCount,
                isFuture: day.start > todayStart
            )
        }
    }

    private func heatSelectionText(_ day: CalendarHeatmapGridView.Day) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        var text = formatter.string(from: day.date) + " · " + String(localized: "完成 \(day.count) 件")
        if day.isFuture {
            text += String(localized: "（未到来）")
        }
        return text
    }

    // MARK: - 完成时刻分布（P2：本期完成按 0–23 时落桶）

    @ViewBuilder
    private func hourCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Text("完成时刻分布")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if analytics.completedCount == 0 {
                Text("本期内还没有完成的任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TaskHourlyDistributionChart(counts: analytics.hourlyCompletedCounts)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - 清单占比（§7.8；环形图 + 图例下钻）

    @ViewBuilder
    private func listBreakdownCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Text("本期完成来自哪些清单")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if analytics.completedCount == 0 {
                Text("本期内还没有完成的任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let colors = Color.holoChartColors(count: analytics.listBreakdown.count)
                let segments = analytics.listBreakdown.map { stat in
                    PieChartSegment(
                        id: stat.id,
                        name: stat.name + (stat.listIsArchived ? String(localized: "（清单已归档）") : ""),
                        weight: Double(stat.count),
                        valueText: String(localized: "\(stat.count) 件")
                    )
                }
                PieChartView(
                    segments: segments,
                    selectedSegmentID: selectedListSegmentID,
                    colors: colors,
                    centerIdleText: String(localized: "\(analytics.completedCount) 件")
                ) { segment in
                    selectedListSegmentID = segment?.id
                }

                ForEach(Array(analytics.listBreakdown.enumerated()), id: \.element.id) { index, stat in
                    Button {
                        listDrilldown = stat
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(index < colors.count ? colors[index] : Color.holoBorder)
                                .frame(width: 8, height: 8)
                            Text(stat.name + (stat.listIsArchived ? String(localized: "（清单已归档）") : ""))
                                .font(.holoCaption)
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(stat.count) · \(percentage(stat.count, of: analytics.completedCount))%")
                                .font(.holoCaption.weight(.semibold))
                                .foregroundColor(.holoTextSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    private func percentage(_ value: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(value) / Double(total) * 100).rounded())
    }

    // MARK: - 按事项分组（P2：一任务多事项重复计入，视图注明）

    @ViewBuilder
    private func matterCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Text("本期完成推进了哪些事项")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if analytics.completedCount == 0 {
                Text("本期内还没有完成的任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if analytics.matterBreakdown.isEmpty {
                Text("本期内完成的任务还没有链接到事项")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let totalMatterCounts = analytics.matterBreakdown.reduce(0) { $0 + $1.count }
                let maxCount = analytics.matterBreakdown.map(\.count).max() ?? 1
                ForEach(Array(analytics.matterBreakdown.prefix(6))) { stat in
                    Button {
                        matterDrilldown = stat
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Text(stat.title)
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(stat.count) · \(percentage(stat.count, of: totalMatterCounts))%")
                                    .font(.holoCaption.weight(.semibold))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            HoloProgress(value: Double(stat.count) / Double(max(maxCount, 1)), color: .holoPrimary, lineWidth: 6)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if analytics.matterBreakdown.count > 6 {
                    Text(String(localized: "还有 \(analytics.matterBreakdown.count - 6) 个事项未展示"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if totalMatterCounts > analytics.completedCount {
                    Text("一个任务链接多个事项会在多个事项下重复计入")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - 合并空态（时刻/清单/事项三卡同空时替三张同句空卡）

    private var completedEmptyCard: some View {
        Text(String(localized: "本期还没有完成记录，完成后这里会显示时刻分布、清单与事项"))
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - Today 计划达成（P2：仅周档，逐日计划 vs 完成）

    @ViewBuilder
    private func todayPlanCard() -> some View {
        if let week = model.todayPlanWeek, week.plannedTotal > 0 {
            VStack(spacing: HoloSpacing.md) {
                Text("Today 计划达成")
                    .font(.holoBody.bold())
                    .foregroundColor(.holoTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                let rate = Int((Double(week.doneTotal) / Double(week.plannedTotal) * 100).rounded())
                Text(String(localized: "本周共定计划 \(week.plannedTotal) 件 · 已完成 \(week.doneTotal) 件 · 达成 \(rate)%"))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { index, day in
                        todayPlanDayCell(weekdayIndex: index, day: day)
                    }
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
    }

    private func todayPlanDayCell(weekdayIndex: Int, day: TaskStatsViewModel.TodayPlanDay?) -> some View {
        VStack(spacing: 4) {
            Text(todayWeekdayLabel(weekdayIndex))
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
            if let day {
                HoloProgress(value: Double(day.done) / Double(max(day.planned, 1)), color: .holoSuccess, lineWidth: 5)
                Text("\(day.done)/\(day.planned)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(.holoTextSecondary)
            } else {
                Capsule().fill(Color.holoBorder.opacity(0.5))
                    .frame(height: 5)
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func todayWeekdayLabel(_ index: Int) -> String {
        let labels = [
            String(localized: "一"), String(localized: "二"), String(localized: "三"),
            String(localized: "四"), String(localized: "五"), String(localized: "六"),
            String(localized: "日")
        ]
        return labels.indices.contains(index) ? labels[index] : ""
    }

    // MARK: - 观察 + 当前待处理（截至现在，§7.9）

    /// 按时率分段条 + 三行待处理 + 一句观察（合并原独立观察卡）
    private func attentionCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("现在需要处理")
                    .font(.holoBody.bold())
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("截至现在")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            if analytics.onTime.denominatorCount > 0 {
                onTimeBand(analytics)
            }

            attentionRow(
                title: String(localized: "当前逾期"),
                count: analytics.attention.overdueIDs.count,
                action: String(localized: "打开逾期任务")
            ) {
                drilldown = .attentionOverdue
            }
            attentionRow(
                title: String(localized: "重要未安排时段"),
                count: analytics.attention.importantUnscheduledIDs.count,
                action: String(localized: "直接安排时段")
            ) {
                drilldown = .attentionUnscheduled
            }
            attentionRow(
                title: String(localized: "待整理"),
                count: analytics.attention.unclassifiedIDs.count,
                action: String(localized: "查看列表")
            ) {
                drilldown = .attentionUnclassified
            }

            Text("三组之间可能有重叠，不能相加为任务总数")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 13))
                    .foregroundColor(.holoPrimary)
                Text(analytics.observation)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(HoloSpacing.sm)
            .background(Color.holoPrimary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    /// 按时率分段条：按时（绿）/ 迟到（橙）/ 未完成（底色留白）+ 图例行
    private func onTimeBand(_ analytics: TaskAnalyticsSnapshot) -> some View {
        let onTime = analytics.onTime
        return VStack(spacing: HoloSpacing.xs) {
            HStack {
                Text("按时率")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(rateText(onTime.rate))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
            }
            HoloProportionBar(segments: [
                .init(id: "on-time", label: "按时", weight: Double(onTime.onTimeCount), color: .holoSuccess),
                .init(id: "late", label: "迟到", weight: Double(onTime.lateCount), color: .holoPrimary),
                .init(id: "unfinished", label: "未完成", weight: Double(onTime.unfinishedCount), color: .holoToolBorder)
            ], height: 8)
            HStack(spacing: 12) {
                onTimeLegendDot(color: .holoSuccess.opacity(0.85), label: String(localized: "按时"), count: onTime.onTimeCount)
                onTimeLegendDot(color: .holoPrimary.opacity(0.85), label: String(localized: "迟到"), count: onTime.lateCount)
                onTimeLegendDot(color: Color.holoBorder, label: String(localized: "未完成"), count: onTime.unfinishedCount)
                Spacer()
            }
        }
        .padding(.bottom, HoloSpacing.xs)
    }

    private func onTimeLegendDot(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(count)")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func attentionRow(title: String, count: Int, action: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(count > 0 ? .holoError : .holoTextSecondary)
                Text(action)
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
                    .padding(.leading, 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextPlaceholder)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 口径脚注（§7.4/§7.5）

    @ViewBuilder
    private func footnotes(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !analytics.missingCompletedAtIDs.isEmpty {
                Button {
                    drilldown = .missingTime
                } label: {
                    Text(String(localized: "有 \(analytics.missingCompletedAtIDs.count) 项已完成任务缺少完成时间，未计入统计，点击查看"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if !analytics.onTime.excludedMissingTimeIDs.isEmpty {
                Text(String(localized: "按时率分母已排除 \(analytics.onTime.excludedMissingTimeIDs.count) 项缺少完成时间的已到期任务。"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }
            if !analytics.futureCompletedAtIDs.isEmpty {
                Text(String(localized: "检测到 \(analytics.futureCompletedAtIDs.count) 项完成时间晚于现在的异常记录，未计入已发生事件。"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }
            Text("按时率依据当前保存的截止日期计算，修改截止日期可能影响历史结果。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 横幅（§7.10/§9.4）

    private var staleDataBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundColor(.holoToolError)
            Text("更新失败，以下为上次数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Button(String(localized: "重试")) { model.reload() }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 8)
        .background(Color.holoError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
    }

    private var dataUpdatedBanner: some View {
        Button {
            model.clearUpdatedFlag()
            model.reload()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.holoPrimary)
                Text("数据已更新")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text("点击刷新查看")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 8)
            .background(Color.holoPrimary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态视图

    private var loadingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
            Text("正在统计…")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var failView: some View {
        VStack(spacing: HoloSpacing.md) {
            Text("统计读取失败")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Button(String(localized: "重试")) {
                model.reload()
            }
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}
