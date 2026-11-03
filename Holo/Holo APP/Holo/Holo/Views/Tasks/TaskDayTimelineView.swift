//
//  TaskDayTimelineView.swift
//  Holo
//
//  单日 24 小时时间轴（多视图方案 §5.2）：截止事项区不占轴高；计划块按
//  TaskTimelineLayout 分列/聚合；点击块进详情、点空白整点按该点预填新建；
//  现在线仅真实今天显示并每分钟刷新。时间轴在外层页面滚动流内
//  （同会话返回保持滚动位置，§5.2-4）。
//

import SwiftUI

struct TaskDayTimelineView: View {

    let projection: TaskCalendarProjection.DayProjection
    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject var session: TaskPresentationSession

    let calendar: Calendar
    let actions: TaskRowActionHandlers
    let repository: TodoRepository
    let onOpenDetail: (UUID) -> Void
    let onCreateAtHour: (Int) -> Void

    @State private var conflictGroup: [TaskRecordSnapshot]?
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    private let hourHeight: CGFloat = 64
    private let timeColumnWidth: CGFloat = 40
    private let leadingInset: CGFloat = 44
    private let minBlockHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if !projection.dueOnlyMembers.isEmpty {
                deadlineRibbon
            }
            timeline
        }
        .sheet(item: Binding(
            get: { conflictGroup.map { ConflictGroupItem(members: $0) } },
            set: { conflictGroup = $0?.members }
        )) { item in
            TaskPresentationListSheet(
                title: String(localized: "重叠安排"),
                members: item.members,
                model: model,
                actions: actions,
                onUndoCompletion: {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                },
                footnote: String(localized: "同一时间安排了多项任务，点击查看各自详情。")
            )
        }
    }

    // MARK: - 截止事项区（当天到期但没有当天计划块，§5.2-3）

    private var deadlineRibbon: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("截止事项 · 未占用时间段")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
                .padding(.bottom, 4)
            ForEach(projection.dueOnlyMembers) { member in
                Button {
                    onOpenDetail(member.id)
                } label: {
                    HStack {
                        Text(member.title)
                            .font(.system(size: 14))
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(dueText(member))
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        .padding(.vertical, 8)
    }

    private func dueText(_ member: TaskRecordSnapshot) -> String {
        member.isAllDay
            ? String(localized: "全天截止")
            : String(localized: "\(Self.timeFormatter.string(from: member.dueDate ?? member.createdAt))截止")
    }

    // MARK: - 时间轴

    private var timelineBlocks: [TaskTimelineLayout.Block] {
        projection.plannedMembers.compactMap { member -> TaskTimelineLayout.Block? in
            guard let start = member.plannedStart, let end = member.plannedEnd else { return nil }
            return TaskTimelineLayout.Block(id: member.id, start: start, end: end)
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            let width = max(200, geo.size.width)
            let output = TaskTimelineLayout.layout(timelineBlocks, metrics: TaskTimelineLayout.Metrics(
                hourHeight: hourHeight,
                minBlockHeight: minBlockHeight,
                minUsableBlockWidth: 88,
                availableWidth: width - leadingInset - 4
            ))
            ZStack(alignment: .topLeading) {
                hourColumn
                ForEach(Array(output.groups.enumerated()), id: \.offset) { _, group in
                    groupView(group, availableWidth: width)
                }
                if session.isTodaySelected {
                    nowLine
                }
            }
            .frame(width: geo.size.width, height: 24 * hourHeight, alignment: .topLeading)
        }
        .frame(height: 24 * hourHeight)
    }

    private var hourColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: 0) {
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: timeColumnWidth, alignment: .leading)
                        .padding(.top, 1)
                    // 点击空白整点：以该点起一小时预填新建（§5.2-10）
                    Button {
                        onCreateAtHour(hour)
                    } label: {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "在\(hour)点创建任务"))
                }
                .frame(height: hourHeight)
                .id("hour-\(hour)")
            }
        }
    }

    // MARK: - 事件块

    @ViewBuilder
    private func groupView(_ group: TaskTimelineLayout.GroupLayout, availableWidth: CGFloat) -> some View {
        switch group {
        case .placements(let placements):
            ForEach(placements, id: \.block.id) { placement in
                eventBlock(placement, availableWidth: availableWidth)
            }
        case .merged(let merged):
            mergedBlock(merged, availableWidth: availableWidth)
        }
    }

    private func eventBlock(_ placement: TaskTimelineLayout.Placement, availableWidth: CGFloat) -> some View {
        let member = projection.plannedMembers.first { $0.id == placement.block.id }
        let block = placement.block
        let y = TaskTimelineMath.yOffset(
            minutes: TaskTimelineMath.minutesSinceMidnight(block.start, calendar: calendar),
            hourHeight: hourHeight
        )
        let height = TaskTimelineMath.blockHeight(
            start: block.start, end: block.end,
            hourHeight: hourHeight, minBlockHeight: minBlockHeight, calendar: calendar
        )
        let contentWidth = availableWidth - leadingInset - 4
        let laneFraction = CGFloat(placement.lane) / CGFloat(max(placement.laneCount, 1))
        let laneWidth = contentWidth / CGFloat(max(placement.laneCount, 1)) - 3
        let isDone = member?.completed == true || model.pendingCompletionTaskID == member?.id

        return Button {
            if let member { onOpenDetail(member.id) }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Rectangle()
                    .fill(blockColor(member))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member?.title ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isDone ? .holoToolTextSecondary : .holoTextPrimary)
                        .lineLimit(height < 65 ? 1 : 2)
                        .strikethrough(isDone, color: .holoTextPlaceholder)
                        .multilineTextAlignment(.leading)
                    Text(blockMeta(block: block, member: member, placement: placement))
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.vertical, 6)
                // 完成块显完成标识，不仅靠透明度（§5.2-9）
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 6)
            .frame(width: max(56, laneWidth), height: height, alignment: .topLeading)
            .background(blockBackground(member))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(member?.title ?? "")，\(blockMeta(block: block, member: member, placement: placement))"))
        .offset(
            x: leadingInset + laneFraction * contentWidth,
            y: y
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func mergedBlock(_ merged: TaskTimelineLayout.MergedGroup, availableWidth: CGFloat) -> some View {
        let y = TaskTimelineMath.yOffset(
            minutes: TaskTimelineMath.minutesSinceMidnight(merged.start, calendar: calendar),
            hourHeight: hourHeight
        )
        let durationMinutes = CGFloat(calendar.dateComponents([.minute], from: merged.start, to: merged.visualEnd).minute ?? 60)
        let height = max(60, durationMinutes / 60 * hourHeight)
        let members = projection.plannedMembers.filter { m in merged.blocks.contains { $0.id == m.id } }
        return Button {
            conflictGroup = members
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(merged.blocks.count)项重叠安排")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                Text("点击查看全部时间与任务")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(6)
            .frame(width: availableWidth - leadingInset - 8, height: height, alignment: .topLeading)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.holoDivider, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: leadingInset, y: y)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func blockColor(_ member: TaskRecordSnapshot?) -> Color {
        guard let member, member.importance != .unknown else { return .holoTextSecondary }
        return member.quadrant(now: model.now, calendar: calendar).tintColor
    }

    private func blockBackground(_ member: TaskRecordSnapshot?) -> Color {
        guard let member, member.importance != .unknown else { return Color.primary.opacity(0.04) }
        return member.quadrant(now: model.now, calendar: calendar).backgroundColor
    }

    private func blockMeta(block: TaskTimelineLayout.Block, member: TaskRecordSnapshot?, placement: TaskTimelineLayout.Placement) -> String {
        var parts = [Self.timeFormatter.string(from: block.start) + "–" + Self.timeFormatter.string(from: block.end)]
        if placement.overlapsAnother { parts.append(String(localized: "时间重叠")) }
        if member?.importance == .unknown { parts.append(String(localized: "待整理")) }
        // 同日已有计划块的截止改附在块内（§5.2-3）
        if let member,
           let dueDay = TaskCalendarProjection.dueDay(of: member, calendar: calendar),
           calendar.isDate(dueDay, inSameDayAs: session.selectedDay) {
            parts.append(member.isAllDay ? String(localized: "全天截止") : dueText(member))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 现在线（仅真实今天，每分钟刷新）

    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let minutes = TaskTimelineMath.minutesSinceMidnight(context.date, calendar: calendar)
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.holoPrimary)
                    .frame(width: 6, height: 6)
                Rectangle()
                    .fill(Color.holoPrimary.opacity(0.8))
                    .frame(height: 1)
            }
            .offset(y: TaskTimelineMath.yOffset(minutes: minutes, hourHeight: hourHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 冲突组 sheet item

private struct ConflictGroupItem: Identifiable {
    let id = UUID()
    let members: [TaskRecordSnapshot]
}
