//
//  TodayAgendaSection.swift
//  Holo
//
//  今天的安排：日程+任务统一时间序列（今日看板 Matter 化方案 §5.3/§9.1）
//
//  未启用显式日计划：顺序 进行中日程 → 即将开始 → 逾期任务 → 今日任务 → 加入今日 → 近期待推进。
//  显式计划生效（「今天减负」§4.4）：同一任务只出现一行，分三组——
//  今天选择推进 / 固定安排与截止 / 今天先放下（可展开）；
//  已选任务携带截止标签，不重复复制到截止列表；步骤目标完成≠根任务完成。
//

import SwiftUI

struct TodayAgendaSection: View {

    let items: [HoloTodayAgendaItem]
    let sectionState: HoloTodaySectionState?
    let maxVisible: Int
    let onItem: (HoloTodayAgendaItem) -> Void
    let onComplete: (HoloTodayAgendaItem) -> Void
    /// 正在撤回窗口内的任务 ID（完成反馈短暂保留后收起）。
    var pendingUndoTaskID: UUID?
    /// 「今天减负」日计划投影；nil 或 inheritBase 走旧基础渲染。
    var plan: HoloTodayPlanProjection? = nil
    /// 分叉解决出口（两台设备安排不同时选择一份）。
    var onResolveConflict: ((HoloTodayPlanConflictCandidate) -> Void)? = nil

    @State private var showAll = false
    @State private var showDeferred = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "今天的安排"))

            if isExplicitPlanActive {
                planBody
            } else {
                legacyBody
            }
        }
    }

    private var isExplicitPlanActive: Bool {
        if case .explicit = plan?.state { return true }
        return false
    }

    // MARK: - 显式计划渲染（§4.4）

    @ViewBuilder
    private var planBody: some View {
        VStack(spacing: 12) {
            // 状态横幅（分叉/同步/不可用）：不回退假空态，约束事实继续展示
            if let plan {
                switch plan.state {
                case .conflict(let candidates):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "两台设备的今日安排不同，选择一次："))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        ForEach(candidates, id: \.revisionID) { candidate in
                            Button {
                                onResolveConflict?(candidate)
                            } label: {
                                HStack {
                                    Text(resolveCandidateLabel(candidate))
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "checkmark.circle")
                                        .font(.caption)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.holoPrimary.opacity(0.08)))
                                .foregroundStyle(Color.holoPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .syncing:
                    Label(String(localized: "今天的安排正在同步……"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unavailable:
                    Label(String(localized: "今天的安排暂时读不到，稍后自动重试。"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            }

            // 1) 今天选择推进
            if let rows = plan?.selectionRows, !rows.isEmpty {
                planGroup(title: String(localized: "今天选择推进")) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        selectionRow(row)
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            } else if isExplicitPlanActive {
                planGroup(title: String(localized: "今天选择推进")) {
                    Text(String(localized: "今天不主动推进任何任务，按固定安排走。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }

            // 2) 固定安排与截止
            if let rows = plan?.constraintRows, !rows.isEmpty {
                planGroup(title: String(localized: "固定安排与截止")) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        constraintRow(row)
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }

            // 3) 今天先放下（可展开）
            if let rows = plan?.deferredRows, !rows.isEmpty {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(HoloAnimation.snappy) { showDeferred.toggle() }
                    } label: {
                        HStack {
                            Text(String(localized: "今天先放下 · \(rows.count) 件"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: showDeferred ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("todayDeferredGroupToggle")

                    if showDeferred {
                        Divider().padding(.leading, 12)
                        ForEach(rows) { row in
                            deferredRow(row)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color(.secondarySystemGroupedBackground)))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
        }
    }

    private func planGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color(.secondarySystemGroupedBackground)))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// 选择行：步骤目标行不冒充根任务完成（§4.4）。
    private func selectionRow(_ row: HoloTodayPlanSelectionRow) -> some View {
        Button {
            onItem(HoloTodayAgendaItem(
                id: "plan:\(row.taskID.uuidString)",
                kind: .taskPlannedToday,
                title: row.title,
                timeAt: row.dueAt,
                isCompleted: false,
                matterTitle: row.matterTitle,
                action: .openTask(row.taskID)
            ))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.holoPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if case .existingStep = row.goal {
                            Text(String(localized: "今天只推进：\(row.stepActionText ?? "")"))
                                .font(.caption2)
                                .foregroundStyle(Color.holoPrimary)
                                .lineLimit(1)
                        }
                        if let dueTag = deadlineTag(row.dueAt, isAllDay: row.isAllDay) {
                            Text(dueTag)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                        if let matter = row.matterTitle {
                            Text(matter)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                .foregroundStyle(Color.holoPrimary)
                        }
                    }
                    if case .goalReached = row.goalState {
                        Text(goalReachedText(row))
                            .font(.caption2)
                            .foregroundStyle(Color.holoSuccess)
                    } else if case .needsRecheck = row.goalState {
                        Text(String(localized: "步骤有变化，重新选一下"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// 步骤目标达到：根未完成的准确表述（R12：不伪造完成）。
    private func goalReachedText(_ row: HoloTodayPlanSelectionRow) -> String {
        switch row.goal {
        case .existingStep:
            return String(localized: "今天已推进一步 · 整件事还没完成")
        case .taskResult:
            return String(localized: "今天要做的已完成")
        }
    }

    private func constraintRow(_ row: HoloTodayPlanConstraintRow) -> some View {
        Button {
            if let taskID = row.taskID {
                onItem(HoloTodayAgendaItem(
                    id: row.id,
                    kind: .taskDueToday,
                    title: row.title,
                    timeAt: nil,
                    isCompleted: false,
                    matterTitle: nil,
                    action: .openTask(taskID)
                ))
            } else {
                onItem(HoloTodayAgendaItem(
                    id: row.id,
                    kind: .scheduleUpcoming,
                    title: row.title,
                    timeAt: nil,
                    isCompleted: false,
                    matterTitle: nil,
                    action: .openSchedule(row.id.replacingOccurrences(of: "schedule:", with: ""))
                ))
            }
        } label: {
            HStack(spacing: 10) {
                constraintIcon(row.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(constraintText(row.kind))
                        .font(.caption2)
                        .foregroundStyle(constraintColor(row.kind))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func deferredRow(_ row: HoloTodayPlanDeferredRow) -> some View {
        Button {
            onItem(HoloTodayAgendaItem(
                id: "deferred:\(row.taskID.uuidString)",
                kind: .taskRecent,
                title: row.title,
                timeAt: row.dueAt,
                isCompleted: false,
                matterTitle: nil,
                action: .openTask(row.taskID)
            ))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let dueTag = deadlineTag(row.dueAt, isAllDay: row.isAllDay) {
                            Text(dueTag)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                        if !row.acknowledgementValid {
                            Text(String(localized: "期限已改，下次整理时重新确认"))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func constraintIcon(_ kind: HoloTodayPlanConstraintRow.Kind) -> some View {
        switch kind {
        case .schedule:
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(Color.holoPrimary)
        case .plannedSegment:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(Color.holoPurple)
        case .deadline(_, _, let isOverdue):
            Image(systemName: isOverdue ? "exclamationmark.circle" : "flag")
                .font(.caption)
                .foregroundStyle(isOverdue ? Color.holoError : Color.secondary)
        }
    }

    private func constraintText(_ kind: HoloTodayPlanConstraintRow.Kind) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        switch kind {
        case .schedule(let start, let end, let isAllDay):
            if isAllDay { return String(localized: "全天日程") }
            formatter.dateFormat = "HH:mm"
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        case .plannedSegment(let start, let end):
            formatter.dateFormat = "HH:mm"
            return "\(formatter.string(from: start))–\(formatter.string(from: end)) \(String(localized: "已安排时段"))"
        case .deadline(let dueAt, let isAllDay, let isOverdue):
            if isAllDay {
                formatter.dateFormat = "M/d"
                return isOverdue
                    ? String(localized: "已过期 · \(formatter.string(from: dueAt))")
                    : String(localized: "今天截止")
            }
            formatter.dateFormat = "M/d HH:mm"
            return isOverdue
                ? String(localized: "已过截止 · \(formatter.string(from: dueAt))")
                : String(localized: "今天 \(formatter.string(from: dueAt)) 截止")
        }
    }

    private func constraintColor(_ kind: HoloTodayPlanConstraintRow.Kind) -> Color {
        switch kind {
        case .deadline(_, _, true): return .holoError
        default: return .secondary
        }
    }

    private func deadlineTag(_ dueAt: Date?, isAllDay: Bool) -> String? {
        guard let dueAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = isAllDay ? "M/d" : "M/d HH:mm"
        return String(localized: "截止 \(formatter.string(from: dueAt))")
    }

    private func resolveCandidateLabel(_ candidate: HoloTodayPlanConflictCandidate) -> String {
        let count = candidate.payload.entries.count
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.dateFormat = "HH:mm"
        return String(localized: "保留 \(count) 件事的安排（\(timeFormatter.string(from: candidate.createdAt))）")
    }

    // MARK: - 旧基础渲染（未启用显式计划）

    @ViewBuilder
    private var legacyBody: some View {
        switch sectionState {
        case .loading:
            Capsule().fill(Color.secondary.opacity(0.1)).frame(height: 64).accessibilityHidden(true)
        case .empty:
            Text(String(localized: "今天没有日程和到期任务。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            if items.isEmpty {
                Text(String(localized: "今天没有日程和到期任务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let visible = showAll ? items : Array(items.prefix(maxVisible))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        row(item)
                        if index < visible.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

                if items.count > maxVisible {
                    Button {
                        showAll.toggle()
                    } label: {
                        Text(showAll
                             ? String(localized: "收起")
                             : String(localized: "查看全部 \(items.count) 项"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.holoPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ item: HoloTodayAgendaItem) -> some View {
        Button {
            onItem(item)
        } label: {
            HStack(spacing: 10) {
                leadingAccessory(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(item.kind == .scheduleOngoing ? .semibold : .regular))
                        .foregroundStyle(item.isCompleted ? Color.secondary : Color.primary)
                        .strikethrough(item.isCompleted)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let time = timeText(item) {
                            Text(time)
                                .font(.caption2)
                                .foregroundStyle(item.kind == .taskOverdue ? Color.holoError : Color.secondary)
                        }
                        if let matter = item.matterTitle {
                            Text(matter)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                .foregroundStyle(Color.holoPrimary)
                        }
                    }
                }
                Spacer(minLength: 0)
                trailingAccessory(item)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func leadingAccessory(_ item: HoloTodayAgendaItem) -> some View {
        switch item.kind {
        case .scheduleOngoing:
            Image(systemName: "record.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.holoSuccess)
        case .scheduleUpcoming:
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(Color.holoPrimary)
        case .taskOverdue:
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(Color.holoError)
        default:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.4)
                .frame(width: 14, height: 14)
        }
    }

    /// 任务行完成勾选（日程只读不可勾；已完成显示勾）。
    @ViewBuilder
    private func trailingAccessory(_ item: HoloTodayAgendaItem) -> some View {
        if case .openTask(let taskID) = item.action {
            if item.isCompleted || pendingUndoTaskID == taskID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.holoSuccess)
            } else {
                Button {
                    onComplete(item)
                } label: {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.holoPrimary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("完成 \(item.title)"))
            }
        }
    }

    private func timeText(_ item: HoloTodayAgendaItem) -> String? {
        guard let date = item.timeAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        switch item.kind {
        case .scheduleOngoing, .scheduleUpcoming:
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        case .taskOverdue:
            formatter.dateFormat = "M/d"
            return String(localized: "逾期 · \(formatter.string(from: date))")
        case .taskDueToday:
            return String(localized: "今天")
        case .taskPlannedToday:
            return nil
        case .taskRecent:
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}
