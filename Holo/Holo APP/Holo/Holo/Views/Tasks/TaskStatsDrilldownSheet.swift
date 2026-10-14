//
//  TaskStatsDrilldownSheet.swift
//  Holo
//
//  统计明细弹层（方案 §7.10）：数字、柱子、清单的明细从同一聚合结果生成；
//  按时率明细带按时/延迟/未完成标识；含双系列趋势图。
//

import SwiftUI
import Charts

extension TaskAnalyticsBucketStat: Identifiable {
    var id: Date { start }
}

// MARK: - 通用明细弹层（指标 / 按时分母 / 缺失时间 / 当前待处理）

struct TaskStatsDrilldownSheet: View {
    @ObservedObject var model: TaskStatsViewModel
    let kind: TaskExperienceStatsView.DrilldownKind
    /// 完成动作与详情打开需要仓库与协调器（统计明细可操作：完成/撤回/打开，§7.9/R34）
    let repository: TodoRepository

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared
    @State private var detailSelection: UUID? = nil

    private struct Row: Identifiable {
        let id: UUID
        let snapshot: TaskRecordSnapshot
        let badge: String
        let badgeColor: Color
        let detail: String
    }

    private var title: String {
        switch kind {
        case .created: return String(localized: "本期新增")
        case .completed: return String(localized: "本期完成")
        case .onTimeDenominator: return String(localized: "按时完成明细")
        case .missingTime: return String(localized: "缺少完成时间的任务")
        case .attentionOverdue: return String(localized: "当前逾期")
        case .attentionUnscheduled: return String(localized: "重要但未安排时段")
        case .attentionUnclassified: return String(localized: "待整理")
        }
    }

    private var inclusionNote: String {
        switch kind {
        case .created:
            return String(localized: "纳入依据：创建时间在本期间内")
        case .completed:
            return String(localized: "纳入依据：完成时间在本期间内")
        case .onTimeDenominator:
            return String(localized: "纳入依据：本期已到期任务（排除缺完成时间）")
        case .missingTime:
            return String(localized: "全部未删除、已完成但缺少完成时间的记录；无法归属到具体期间")
        case .attentionOverdue:
            return String(localized: "未完成、未归档、未删除，截止时刻早于现在")
        case .attentionUnscheduled:
            return String(localized: "活动任务中重要性为「重要」且没有合法成对时段")
        case .attentionUnclassified:
            return String(localized: "活动任务中重要性尚未判断")
        }
    }

    /// 完成按钮只对「未完成且可见」的任务开放（历史集合只读）
    private var allowsCompletion: Bool {
        switch kind {
        case .created, .attentionOverdue, .attentionUnscheduled, .attentionUnclassified, .onTimeDenominator:
            return true
        case .completed, .missingTime:
            return false
        }
    }

    private var rows: [Row] {
        guard let analytics = model.analytics else { return [] }
        let ids: [UUID]
        switch kind {
        case .created: ids = analytics.createdIDs
        case .completed: ids = analytics.completedIDs
        case .onTimeDenominator: ids = analytics.onTime.denominatorIDs
        case .missingTime: ids = analytics.missingCompletedAtIDs
        case .attentionOverdue: ids = analytics.attention.overdueIDs
        case .attentionUnscheduled: ids = analytics.attention.importantUnscheduledIDs
        case .attentionUnclassified: ids = analytics.attention.unclassifiedIDs
        }
        return ids.compactMap { id in
            guard let record = model.record(for: id) else { return nil }
            switch kind {
            case .onTimeDenominator:
                if analytics.onTime.onTimeIDs.contains(id) {
                    return Row(id: id, snapshot: record, badge: String(localized: "按时"), badgeColor: .holoSuccess, detail: onTimeDetail(record))
                }
                if analytics.onTime.lateIDs.contains(id) {
                    return Row(id: id, snapshot: record, badge: String(localized: "延迟"), badgeColor: .holoError, detail: onTimeDetail(record))
                }
                return Row(id: id, snapshot: record, badge: String(localized: "未完成"), badgeColor: .holoTextSecondary, detail: onTimeDetail(record))
            default:
                return Row(id: id, snapshot: record, badge: "", badgeColor: .clear, detail: "")
            }
        }
    }

    private func onTimeDetail(_ record: TaskRecordSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日 HH:mm")
        var parts: [String] = []
        if let due = record.effectiveDue(calendar: model.calendar) {
            parts.append(String(localized: "截止 ") + formatter.string(from: due))
        }
        if let completedAt = record.completedAt {
            parts.append(String(localized: "完成 ") + formatter.string(from: completedAt))
        } else {
            parts.append(String(localized: "完成时间未记录"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                // 完成按钮与行主体平级（按钮嵌按钮会被外层吞掉触摸与无障碍）
                HStack(spacing: 10) {
                    if allowsCompletion, !row.snapshot.completed {
                        Button {
                            if completionCoordinator.pending?.taskID == row.snapshot.id {
                                completionCoordinator.undo(in: repository)
                                HapticManager.light()
                            } else {
                                completionCoordinator.requestCompletion(
                                    taskID: row.snapshot.id, source: .taskList, in: repository
                                )
                                HapticManager.taskCompletion()
                            }
                        } label: {
                            Image(systemName: completionCoordinator.pending?.taskID == row.snapshot.id
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(completionCoordinator.pending?.taskID == row.snapshot.id
                                                 ? .holoSuccess : .holoTextPlaceholder)
                                .frame(width: 30, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "完成\(row.snapshot.title)"))
                    }

                    // 行主体：点开任务即得全部行动（改期/完成/安排/归档，§7.9）
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.snapshot.title)
                                .font(.holoBody)
                                .foregroundColor(row.snapshot.completed ? .holoTextSecondary : .holoTextPrimary)
                                .lineLimit(2)
                                .strikethrough(row.snapshot.completed, color: .holoTextPlaceholder)
                            Spacer()
                            if !row.badge.isEmpty {
                                Text(row.badge)
                                    .font(.holoTinyLabel)
                                    .foregroundColor(row.badgeColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(row.badgeColor.opacity(0.12)))
                            }
                        }
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        detailSelection = row.snapshot.id
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(String(localized: "打开任务详情"))
                }
            }
            .overlay(alignment: .bottom) {
                if rows.isEmpty {
                    Text("暂无记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(inclusionNote)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text("\(model.rangeTitle) · 共 \(rows.count) 项")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, 6)
                .background(Color.holoCardBackground)
            }
            .onAppear { model.clearUpdatedFlag() }
            // 撤回条位于当前可见弹层内（R34：跨页面只呈现一个有效撤回动作）
            .safeAreaInset(edge: .bottom) {
                if completionCoordinator.pending != nil {
                    HoloUndoToast(
                        message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                        onUndo: {
                            completionCoordinator.undo(in: repository)
                            HapticManager.light()
                        }
                    )
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, 6)
                }
            }
            .sheet(item: $detailSelection, onDismiss: { model.reload(markUpdated: true) }) { taskID in
                if let task = repository.findTask(by: taskID) {
                    TaskDetailView(task: task, repository: repository)
                } else {
                    Text("该任务已被删除")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .padding()
                }
            }
        }
    }
}

// MARK: - 趋势桶明细（点柱：该桶新增/完成两数及对应任务，§7.7）

struct TaskStatsBucketDrilldownSheet: View {
    @ObservedObject var model: TaskStatsViewModel
    let bucket: TaskAnalyticsBucketStat

    @Environment(\.dismiss) private var dismiss
    @State private var showsCreated = true

    private var bucketTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter.string(from: bucket.start)
    }

    private var ids: [UUID] {
        Array(Set(bucket.createdIDs).union(Set(bucket.completedIDs)))
            .sorted { $0.uuidString < $1.uuidString }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 同一 UUID 仅一行，可同时带两种标识（§7.7）
                HStack(spacing: 8) {
                    Text("新增 \(bucket.createdIDs.count)")
                        .font(.holoCaption.weight(.semibold))
                        .foregroundColor(showsCreated ? .holoPrimary : .holoTextSecondary)
                    Text("完成 \(bucket.completedIDs.count)")
                        .font(.holoCaption.weight(.semibold))
                        .foregroundColor(!showsCreated ? .holoSuccess : .holoTextSecondary)
                    Spacer()
                    if bucket.isFuture {
                        Text("未到来")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextPlaceholder)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.holoBorder))
                    } else if bucket.isPartialToday {
                        Text("截至现在")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, 8)

                List(ids) { id in
                    if let record = model.record(for: id) {
                        HStack {
                            Text(record.title)
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(1)
                            Spacer()
                            HStack(spacing: 4) {
                                if bucket.createdIDs.contains(id) {
                                    Text("新增")
                                        .font(.holoTinyLabel)
                                        .foregroundColor(.holoPrimary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                }
                                if bucket.completedIDs.contains(id) {
                                    Text("完成")
                                        .font(.holoTinyLabel)
                                        .foregroundColor(.holoSuccess)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.holoSuccess.opacity(0.1)))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(bucketTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 全期趋势明细（「查看趋势明细」按钮：按桶分组核对全期，§7.7）
//
// 按钮语义是「核对整段趋势」，不是「看最后一天」：按桶倒序列出每个时段的
// 新增与完成任务，只列有记录的桶（没记录的时段趋势图上已显示为 0）。

struct TaskStatsTrendDrilldownSheet: View {
    @ObservedObject var model: TaskStatsViewModel
    let analytics: TaskAnalyticsSnapshot

    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let at: Date
        let timeText: String
        let showsCreated: Bool
        let showsCompleted: Bool
    }

    /// 有记录的桶，最近的在上
    private var sections: [TaskAnalyticsBucketStat] {
        analytics.buckets
            .filter { !$0.createdIDs.isEmpty || !$0.completedIDs.isEmpty }
            .reversed()
    }

    /// 桶是单日（周/月/短自定义按日分桶）还是跨日（年/长自定义按月分桶）
    private func bucketIsSingleDay(_ bucket: TaskAnalyticsBucketStat) -> Bool {
        Calendar.current.isDate(bucket.start, equalTo: bucket.endExclusive.addingTimeInterval(-1), toGranularity: .day)
    }

    private func bucketTitle(_ bucket: TaskAnalyticsBucketStat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate(bucketIsSingleDay(bucket) ? "M月d日 EEEE" : "yyyy年M月")
        return formatter.string(from: bucket.start)
    }

    private func rows(in bucket: TaskAnalyticsBucketStat) -> [Row] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate(bucketIsSingleDay(bucket) ? "HH:mm" : "d日 HH:mm")
        return Array(Set(bucket.createdIDs).union(Set(bucket.completedIDs)))
            .compactMap { id -> Row? in
                guard let record = model.record(for: id) else { return nil }
                let showsCompleted = bucket.completedIDs.contains(id)
                // 完成行以完成时刻为核对锚点，仅新增行退回创建时刻
                let at = (showsCompleted ? record.completedAt : nil) ?? record.createdAt
                return Row(
                    id: id,
                    title: record.title,
                    at: at,
                    timeText: formatter.string(from: at),
                    showsCreated: bucket.createdIDs.contains(id),
                    showsCompleted: showsCompleted
                )
            }
            .sorted { $0.at > $1.at }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 28))
                            .foregroundColor(.holoTextPlaceholder)
                        Text("本期间还没有新增或完成记录")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sections) { bucket in
                            Section {
                                ForEach(rows(in: bucket)) { row in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(row.title)
                                                .font(.holoBody)
                                                .foregroundColor(.holoTextPrimary)
                                                .lineLimit(1)
                                            Text(row.timeText)
                                                .font(.holoCaption)
                                                .foregroundColor(.holoTextSecondary)
                                        }
                                        Spacer()
                                        HStack(spacing: 4) {
                                            if row.showsCreated {
                                                Text("新增")
                                                    .font(.holoTinyLabel)
                                                    .foregroundColor(.holoPrimary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                            }
                                            if row.showsCompleted {
                                                Text("完成")
                                                    .font(.holoTinyLabel)
                                                    .foregroundColor(.holoSuccess)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.holoSuccess.opacity(0.1)))
                                            }
                                        }
                                    }
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(bucketTitle(bucket))
                                        .font(.holoCaption.weight(.semibold))
                                        .foregroundColor(.holoTextPrimary)
                                    Text(String(localized: "新增 \(bucket.createdIDs.count) · 完成 \(bucket.completedIDs.count)"))
                                        .font(.holoTinyLabel)
                                        .foregroundColor(.holoTextSecondary)
                                    Spacer()
                                    if bucket.isPartialToday {
                                        Text("截至现在")
                                            .font(.holoTinyLabel)
                                            .foregroundColor(.holoPrimary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                    }
                                }
                                .textCase(nil)
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按 \(bucketGranularityText) 列出每个时段的新增与完成任务，最近的在上")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text("\(model.rangeTitle) · 共 \(analytics.createdCount) 新增 / \(analytics.completedCount) 完成")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, 6)
                .background(Color.holoCardBackground)
            }
            .navigationTitle(String(localized: "趋势明细"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var bucketGranularityText: String {
        let granularity = TaskAnalyticsPeriodResolver.bucketGranularity(
            of: TaskAnalyticsPeriodBounds(
                period: analytics.period,
                start: analytics.start,
                endExclusive: analytics.endExclusive,
                isOngoing: analytics.isOngoing
            ),
            calendar: model.calendar
        )
        return granularity == .day ? String(localized: "日") : String(localized: "月")
    }
}

// MARK: - 清单完成明细（点清单行，§7.8）

struct TaskStatsListDrilldownSheet: View {
    @ObservedObject var model: TaskStatsViewModel
    let stat: TaskListBreakdownStat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(stat.completedIDs) { id in
                if let record = model.record(for: id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        if let completedAt = record.completedAt {
                            Text(completedAt, format: .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "\(stat.name) · \(stat.count) 项完成"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 双系列趋势图（§7.7；2026-10-11 按图表规范重画）
//
// 图表规范 2026-10-07 硬规则逐条落实：
// 1. X 轴刻度一律 chartOverlay 自绘，与柱子共用 position(forX:) 坐标系（禁 AxisValueLabel）
// 2. 柱宽按 pt 封顶（ChartBarPairLayout.barWidth），绝不按槽宽比例撑满
// 3. 索引域画法：未来桶不占槽，域铺满已发生范围
// 4. position(forX/Y:) 补 plotFrame 偏移，高亮带/气泡不错位
// 双模式：数量（新增/完成双柱）⇄ 完成率（到期完成率折线，0–100%）

struct TaskStatsTrendChart: View {
    enum Mode: Hashable {
        /// 新增/完成双柱
        case counts
        /// 到期完成率折线（（按时+迟到）÷ 到期分母）
        case dueCompletionRate
    }

    let buckets: [TaskAnalyticsBucketStat]
    var mode: Mode = .counts
    let onTapBucket: (TaskAnalyticsBucketStat) -> Void

    @State private var hoveredIndex: Int?

    private struct Point: Identifiable {
        let id: Int
        /// 紧凑槽位（未来桶剔除后重排）
        let index: Int
        let label: String
        let created: Int
        let completed: Int
        let rate: Double?
        let isPartialToday: Bool
        let bucket: TaskAnalyticsBucketStat
    }

    private var points: [Point] {
        var result: [Point] = []
        for (offset, bucket) in buckets.enumerated() where !bucket.isFuture {
            result.append(Point(
                id: offset,
                index: result.count,
                label: bucketLabel(bucket),
                created: bucket.createdIDs.count,
                completed: bucket.completedIDs.count,
                rate: bucket.dueCompletionRate,
                isPartialToday: bucket.isPartialToday,
                bucket: bucket
            ))
        }
        return result
    }

    /// 完成率模式是否有可画数据（无到期桶时给占位说明，不出空图）
    private var hasRatedPoints: Bool {
        points.contains { $0.rate != nil }
    }

    private func bucketLabel(_ bucket: TaskAnalyticsBucketStat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        // 日桶「d日」；月桶「M月」
        if Calendar.current.isDate(bucket.start, equalTo: bucket.endExclusive.addingTimeInterval(-1), toGranularity: .day) {
            formatter.setLocalizedDateFormatFromTemplate("d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("M月")
        }
        return formatter.string(from: bucket.start)
    }

    var body: some View {
        if mode == .dueCompletionRate && !hasRatedPoints {
            VStack(spacing: HoloSpacing.sm) {
                Text("本期暂无已到期任务，可切回「数量」查看新增与完成")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
        } else {
            GeometryReader { geometry in
                let slotWidthPt = ChartBarPairLayout.estimatedSlotWidthPt(
                    containerWidthPt: geometry.size.width,
                    pointCount: points.count
                )
                chart(slotWidthPt: slotWidthPt)
            }
            .frame(height: 180)
            .accessibilityElement()
            .accessibilityLabel(chartAccessibilitySummary)
        }
    }

    // MARK: 图表组装

    private func chart(slotWidthPt: CGFloat) -> some View {
        Chart {
            if mode == .counts {
                ForEach(points) { point in
                    barPair(point, slotWidthPt: slotWidthPt)
                }
            } else {
                rateMarks
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...yDomainMax)
        // X 刻度已由 chartOverlay 自绘（规范硬规则 1），必须显式隐藏默认轴
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: yTickValues) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.32))
                AxisValueLabel {
                    if let axisValue = value.as(Double.self) {
                        Text(yAxisLabel(axisValue))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let overlayFrame = geometry.frame(in: .local)
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                // —— X 轴刻度自绘（含末位）：与柱子同一 position(forX:) 坐标系 ——
                if let plotFrame {
                    ForEach(axisTicks, id: \.index) { tick in
                        if let xPos = proxy.position(forX: Double(tick.index)) {
                            Text(tick.label)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .position(x: plotFrame.minX + xPos, y: plotFrame.maxY + 10)
                        }
                    }
                }

                // —— 触摸桶高亮带 + tooltip（position(forX:) 补 plotFrame 偏移，硬规则 4）——
                if let hoveredIndex,
                   let point = points.first(where: { $0.index == hoveredIndex }),
                   let slotXPos = proxy.position(forX: Double(hoveredIndex)), let plotFrame {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.holoToolText.opacity(0.05))
                        .frame(
                            width: plotFrame.width / CGFloat(max(points.count, 1)),
                            height: plotFrame.height
                        )
                        .position(x: plotFrame.minX + slotXPos, y: plotFrame.midY)
                    tooltip(
                        point: point,
                        x: min(max(plotFrame.minX + slotXPos, 60), overlayFrame.width - 60),
                        y: min(max(plotFrame.minY + plotFrame.height * 0.14, 16), overlayFrame.height - 16)
                    )
                }

                // —— 手势仲裁：横滑选桶、纵滑交还页面滚动、点按下钻 ——
                DirectionalChartGestureOverlay(
                    onChanged: { location in
                        hoveredIndex = touchedIndex(location, proxy: proxy, plotFrame: plotFrame) ?? hoveredIndex
                    },
                    onEnded: { _ in
                        hoveredIndex = nil
                    },
                    onCancelled: {
                        hoveredIndex = nil
                    },
                    onTap: { location in
                        guard let touched = touchedIndex(location, proxy: proxy, plotFrame: plotFrame),
                              let point = points.first(where: { $0.index == touched }) else { return }
                        onTapBucket(point.bucket)
                    }
                )
            }
        }
    }

    // MARK: 图形本体

    /// 新增/完成双柱（新增低饱和暖橙、完成低饱和绿，§7.7；柱宽 pt 封顶，硬规则 2）
    @ChartContentBuilder
    private func barPair(_ point: Point, slotWidthPt: CGFloat) -> some ChartContent {
        let offset = ChartBarPairLayout.barOffsetUnits(pointCount: points.count, slotWidthPt: slotWidthPt)
        if point.created > 0 {
            BarMark(
                x: .value("槽位", Double(point.index) - offset),
                yStart: .value("起点", 0.0),
                yEnd: .value("新增", Double(point.created)),
                width: .fixed(barWidthPt)
            )
            .cornerRadius(3)
            .foregroundStyle(Color.holoPrimary.opacity(0.75))
        }
        if point.completed > 0 {
            BarMark(
                x: .value("槽位", Double(point.index) + offset),
                yStart: .value("起点", 0.0),
                yEnd: .value("完成", Double(point.completed)),
                width: .fixed(barWidthPt)
            )
            .cornerRadius(3)
            .foregroundStyle(Color.holoSuccess.opacity(0.75))
        }
    }

    /// 到期完成率折线 + 面积（仅画有到期数据的桶；同 series 连成一条线）
    @ChartContentBuilder
    private var rateMarks: some ChartContent {
        let rated = points.filter { $0.rate != nil }
        ForEach(rated) { point in
            AreaMark(
                x: .value("槽位", Double(point.index)),
                yStart: .value("起点", 0.0),
                yEnd: .value("完成率", (point.rate ?? 0) * 100),
                series: .value("完成率", "完成率")
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.holoSuccess.opacity(0.14), Color.holoSuccess.opacity(0.005)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        ForEach(rated) { point in
            LineMark(
                x: .value("槽位", Double(point.index)),
                y: .value("完成率", (point.rate ?? 0) * 100),
                series: .value("完成率", "完成率")
            )
            .foregroundStyle(Color.holoSuccess)
            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
    }

    // MARK: 几何与刻度

    private var barWidthPt: CGFloat {
        ChartBarPairLayout.barWidth(pointCount: points.count)
    }

    /// 索引域：槽位 0…count-1 各占一槽，两侧各留半槽（硬规则 3）
    private var xDomain: ClosedRange<Double> {
        let upper = Double(max(points.count - 1, 0)) + 0.5
        return -0.5...upper
    }

    /// Y 轴上限：数量模式小值保底 4（单根 1~2 的柱子不该顶满整格，10-7 反馈），
    /// 其余按数据最大值向上取第一个严格更大的整齐步进（1.5/2/3/4/5/6/8/10 ×10ᵏ）；
    /// 完成率模式恒 0–100%
    private var yDomainMax: Double {
        guard mode == .counts else { return 100 }
        let maxValue = points.reduce(0.0) { max($0, Double(max($1.created, $1.completed))) }
        let magnitude = pow(10, floor(log10(max(maxValue, 1))))
        for step in [1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] where step * magnitude > maxValue {
            return max(step * magnitude, 4)
        }
        return 10 * magnitude
    }

    private var yTickValues: [Double] {
        mode == .counts
            ? [0, (yDomainMax / 2).rounded(), yDomainMax]
            : [0, 50, 100]
    }

    private func yAxisLabel(_ value: Double) -> String {
        mode == .counts ? "\(Int(value))" : "\(Int(value))%"
    }

    /// X 刻度稀疏：≤10 桶全画，>10 桶按约 8 格稀疏
    private var axisTicks: [(index: Int, label: String)] {
        let count = points.count
        guard count > 1 else { return [] }
        guard count > 10 else { return (0..<count).map { ($0, points[$0].label) } }
        let step = Int((Double(count) / 8).rounded(.up))
        return stride(from: 0, to: count, by: step).map { ($0, points[$0].label) }
    }

    private func touchedIndex(_ location: CGPoint, proxy: ChartProxy, plotFrame: CGRect?) -> Int? {
        guard !points.isEmpty, let plotFrame else { return nil }
        let touchXInPlot = location.x - plotFrame.minX
        let pointPositions = points.compactMap { proxy.position(forX: Double($0.index)) }
        guard pointPositions.count == points.count else { return nil }
        return ChartTouchSelection.nearestPointIndex(
            touchXInPlot: touchXInPlot,
            plotWidth: plotFrame.width,
            pointXPositions: pointPositions
        )
    }

    // MARK: Tooltip（规范 §6：圆角 4 + 卡面底色 + 轻阴影 + clamp 防溢出）

    private func tooltip(point: Point, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(point.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
            if mode == .counts {
                HStack(spacing: 6) {
                    Text(String(localized: "新增 \(point.created)"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoPrimary)
                    Text(String(localized: "完成 \(point.completed)"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoSuccess)
                }
            } else if let rate = point.rate {
                Text(String(localized: "完成率 \(Int((rate * 100).rounded()))%"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.holoSuccess)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.holoToolSurface)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .fixedSize()
        .position(x: x, y: y)
    }

    private var chartAccessibilitySummary: String {
        let created = buckets.reduce(0) { $0 + $1.createdIDs.count }
        let completed = buckets.reduce(0) { $0 + $1.completedIDs.count }
        return String(localized: "趋势图：新增 \(created) 项，完成 \(completed) 项，可通过「查看趋势明细」逐日核对")
    }
}

// MARK: - 完成时刻分布柱状图（P2；同图表规范画法：索引域全槽 + X 刻度自绘 + 柱宽 pt 封顶 + 手势仲裁）

struct TaskHourlyDistributionChart: View {
    /// 0–23 时完成计数（24 桶，空桶如实留白）
    let counts: [Int]

    @State private var hoveredIndex: Int?

    private var barWidthPt: CGFloat {
        ChartBarPairLayout.barWidth(pointCount: max(counts.count, 24))
    }

    private var xDomain: ClosedRange<Double> { -0.5...23.5 }

    /// 小值保底 4，与趋势图同款整齐步进取整
    private var yDomainMax: Double {
        let maxValue = Double(counts.max() ?? 0)
        let magnitude = pow(10, floor(log10(max(maxValue, 1))))
        for step in [1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] where step * magnitude > maxValue {
            return max(step * magnitude, 4)
        }
        return 10 * magnitude
    }

    /// 稀疏时刻刻度：0/6/12/18/23 时
    private var tickHours: [Int] { [0, 6, 12, 18, 23] }

    var body: some View {
        Chart {
            ForEach(Array(counts.enumerated()), id: \.offset) { hour, count in
                if count > 0 {
                    BarMark(
                        x: .value("时刻", Double(hour)),
                        yStart: .value("起点", 0.0),
                        yEnd: .value("完成数", Double(count)),
                        width: .fixed(barWidthPt)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(Color.holoPrimary.opacity(0.8))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...yDomainMax)
        // X 刻度自绘（规范硬规则 1），默认轴显式隐藏
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0.0, (yDomainMax / 2).rounded(), yDomainMax]) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.32))
                AxisValueLabel {
                    if let axisValue = value.as(Double.self) {
                        Text("\(Int(axisValue))")
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let overlayFrame = geometry.frame(in: .local)
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                // —— X 轴刻度自绘：与柱子同一 position(forX:) 坐标系 ——
                if let plotFrame {
                    ForEach(tickHours, id: \.self) { hour in
                        if let xPos = proxy.position(forX: Double(hour)) {
                            Text("\(hour)时")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .position(x: plotFrame.minX + xPos, y: plotFrame.maxY + 10)
                        }
                    }
                }

                // —— 触摸高亮 + tooltip（硬规则 4：补 plotFrame 偏移）——
                if let hoveredIndex,
                   let slotXPos = proxy.position(forX: Double(hoveredIndex)), let plotFrame {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.holoToolText.opacity(0.05))
                        .frame(width: plotFrame.width / 24, height: plotFrame.height)
                        .position(x: plotFrame.minX + slotXPos, y: plotFrame.midY)
                    tooltip(
                        hour: hoveredIndex,
                        count: counts.indices.contains(hoveredIndex) ? counts[hoveredIndex] : 0,
                        x: min(max(plotFrame.minX + slotXPos, 70), overlayFrame.width - 70),
                        y: min(max(plotFrame.minY + plotFrame.height * 0.12, 14), overlayFrame.height - 14)
                    )
                }

                // —— 手势仲裁：横滑选时、纵滑交还页面滚动 ——
                DirectionalChartGestureOverlay(
                    onChanged: { location in
                        hoveredIndex = touchedIndex(location, proxy: proxy, plotFrame: plotFrame) ?? hoveredIndex
                    },
                    onEnded: { _ in
                        hoveredIndex = nil
                    },
                    onCancelled: {
                        hoveredIndex = nil
                    }
                )
            }
        }
        .frame(height: 120)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "完成时刻分布图：横滑查看各小时完成数"))
    }

    private func touchedIndex(_ location: CGPoint, proxy: ChartProxy, plotFrame: CGRect?) -> Int? {
        guard counts.count == 24, let plotFrame else { return nil }
        let touchXInPlot = location.x - plotFrame.minX
        let positions = (0..<24).compactMap { proxy.position(forX: Double($0)) }
        guard positions.count == 24 else { return nil }
        return ChartTouchSelection.nearestPointIndex(
            touchXInPlot: touchXInPlot,
            plotWidth: plotFrame.width,
            pointXPositions: positions
        )
    }

    private func tooltip(hour: Int, count: Int, x: CGFloat, y: CGFloat) -> some View {
        Text(String(localized: "\(hour)时 · 完成 \(count) 件"))
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.holoToolSurface)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            )
            .fixedSize()
            .position(x: x, y: y)
    }
}

// MARK: - 事项完成明细（点事项行，P2）

struct TaskStatsMatterDrilldownSheet: View {
    @ObservedObject var model: TaskStatsViewModel
    let stat: TaskMatterBreakdownStat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(stat.completedIDs) { id in
                if let record = model.record(for: id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        if let completedAt = record.completedAt {
                            Text(completedAt, format: .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("一个任务链接多个事项会在多个事项下重复计入")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, 6)
                    .background(Color.holoCardBackground)
            }
            .navigationTitle(String(localized: "\(stat.title) · \(stat.count) 项完成"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
