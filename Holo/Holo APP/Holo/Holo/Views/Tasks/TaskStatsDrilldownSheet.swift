//
//  TaskStatsDrilldownSheet.swift
//  Holo
//
//  统计明细弹层（方案 §7.10）：数字、柱子、清单的明细从同一聚合结果生成；
//  按时率明细带按时/延迟/未完成标识；含双系列趋势图。
//

import SwiftUI

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
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
    enum Mode: Hashable { case counts, dueCompletionRate }
    let buckets: [TaskAnalyticsBucketStat]
    var mode: Mode = .counts
    let onTapBucket: (TaskAnalyticsBucketStat) -> Void
    @State private var selection: String?
    private var visible: [TaskAnalyticsBucketStat] { buckets.filter { !$0.isFuture } }
    private var chartBuckets: [HoloChartBucket] {
        visible.map { bucket in
            HoloChartBucket(id: String(bucket.start.timeIntervalSince1970),
                            label: HoloChartFormat.date(bucket.start),
                            detail: HoloChartFormat.date(bucket.start, template: "yMMMd"),
                            values: mode == .counts
                                ? [Double(bucket.createdIDs.count), Double(bucket.completedIDs.count)]
                                : [bucket.dueCompletionRate.map { $0 * 100 }])
        }
    }
    var body: some View {
        Group {
            if mode == .counts {
                HoloBarChart(buckets: chartBuckets,
                             series: [.init(id: "created", title: "新增", color: .holoPrimary),
                                      .init(id: "completed", title: "完成", color: .holoSuccess)],
                             selection: $selection, height: 160, valueText: { "\(Int($0)) 件" }, onOpenDetail: open)
            } else {
                HoloLineChart(buckets: chartBuckets,
                              series: [.init(id: "rate", title: "到期完成率", color: .holoPrimary)],
                              selection: $selection, height: 160, yDomain: 0...100,
                              valueText: { "\(HoloChartFormat.number($0))%" }, onOpenDetail: open)
            }
        }
        .onChange(of: mode) { _, _ in selection = nil }
    }
    private func open(_ bucket: HoloChartBucket) {
        if let original = visible.first(where: { String($0.start.timeIntervalSince1970) == bucket.id }) { onTapBucket(original) }
    }
}

// MARK: - 完成时刻分布柱状图（P2；同图表规范画法：索引域全槽 + X 刻度自绘 + 柱宽 pt 封顶 + 手势仲裁）

struct TaskHourlyDistributionChart: View {
    let counts: [Int]
    @State private var selection: String?
    var body: some View {
        HoloBarChart(buckets: counts.enumerated().map { hour, count in
            HoloChartBucket(id: String(hour), label: "\(hour)时", values: [Double(count)])
        }, series: [.init(id: "count", title: "完成", color: .holoPrimary)],
           selection: $selection, height: 120, valueText: { "\(Int($0)) 件" })
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
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
