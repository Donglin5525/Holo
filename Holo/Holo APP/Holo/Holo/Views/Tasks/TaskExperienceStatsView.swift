//
//  TaskExperienceStatsView.swift
//  Holo
//
//  统计页 V2（2026-10-06 任务重构方案 §7）：期间选择（真实期间）→ 新增/完成/按时率 →
//  双系列趋势 → 清单分布 → 可核对观察 → 当前待处理（截至现在）→ 全部明细。
//  统计覆盖全部未删除任务，不跟随首页筛选。
//

import SwiftUI
import Charts

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
                        listBreakdownCard(analytics)
                        observationCard(analytics)
                        attentionCard(analytics)
                        footnotes(analytics)
                    } else if model.isLoading {
                        loadingView
                    } else {
                        failView
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .background(Color.holoBackground)
        .task {
            await CoreDataStack.shared.waitUntilReady()
            model.reload()
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
    }

    // MARK: - 头部

    private var headerView: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }
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
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, HoloSpacing.md)
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
                        Text(model.kind.title)
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

            // 具体日期范围始终可见（§7.1）
            Text(model.rangeTitle)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
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
                    .foregroundColor(.holoError)
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

            HStack(spacing: HoloSpacing.md) {
                statBlock(
                    title: String(localized: "新增"),
                    value: "\(analytics.createdCount)",
                    sub: model.deltaText(analytics.comparison.createdDelta)
                ) {
                    drilldown = .created
                }
                statBlock(
                    title: String(localized: "完成"),
                    value: "\(analytics.completedCount)",
                    sub: model.deltaText(analytics.comparison.completedDelta)
                ) {
                    drilldown = .completed
                }
                statBlock(
                    title: String(localized: "按时完成"),
                    value: onTimeText(analytics),
                    sub: onTimeSub(analytics)
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

    private func onTimeText(_ analytics: TaskAnalyticsSnapshot) -> String {
        guard let rate = analytics.onTime.rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    private func onTimeSub(_ analytics: TaskAnalyticsSnapshot) -> String {
        guard analytics.onTime.denominatorCount > 0 else {
            return String(localized: "本期无已到期任务")
        }
        return String(localized: "\(analytics.onTime.onTimeCount) / \(analytics.onTime.denominatorCount) 项按时完成")
    }

    private func statBlock(title: String, value: String, sub: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Text(title)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextPlaceholder)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 双系列趋势柱状图（§7.7）

    private func trendCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("新增与完成趋势")
                    .font(.holoBody.bold())
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                trendLegend
            }

            TaskStatsTrendChart(buckets: analytics.buckets) { bucket in
                bucketDrilldown = bucket
            }

            Button {
                showTrendDrilldown = true
            } label: {
                Label(String(localized: "查看趋势明细"), systemImage: "list.bullet")
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
            }
            .buttonStyle(.plain)
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

    // MARK: - 清单分布（§7.8）

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
                let maxCount = analytics.listBreakdown.map(\.count).max() ?? 1
                ForEach(analytics.listBreakdown) { stat in
                    Button {
                        listDrilldown = stat
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Text(stat.name + (stat.listIsArchived ? String(localized: "（清单已归档）") : ""))
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(stat.count) · \(percentage(stat.count, of: analytics.completedCount))%")
                                    .font(.holoCaption.weight(.semibold))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.holoBorder)
                                    Capsule()
                                        .fill(Color.holoPrimary.opacity(0.55))
                                        .frame(width: geo.size.width * CGFloat(stat.count) / CGFloat(max(maxCount, 1)))
                                }
                            }
                            .frame(height: 6)
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

    // MARK: - 观察（§7.9）

    private func observationCard(_ analytics: TaskAnalyticsSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 13))
                .foregroundColor(.holoPrimary)
            Text(analytics.observation)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - 当前待处理（截至现在，§7.9）

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
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
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
                    Text(String(localized: "有 \(analytics.missingCompletedAtIDs.count) 项已完成任务缺少完成时间，未计入期间完成统计。无法归属具体期间，点击查看。"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .multilineTextAlignment(.leading)
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
                .foregroundColor(.holoError)
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
