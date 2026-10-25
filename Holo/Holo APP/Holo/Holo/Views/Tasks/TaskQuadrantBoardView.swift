//
//  TaskQuadrantBoardView.swift
//  Holo
//
//  四象限平铺版（2026-10-25 东林拍板）：单列五段依次铺开——四象限 + 待整理，
//  每段彩色段头（名 + 数量 + 新增），段内任务全宽完整展示；空段只剩段头一行。
//  格子只是数字牌，永不塞任务名。跨格拖动退役：归类走行内菜单
//  「移动到象限」（TaskQuadrantMoveSheet）。规则说明收进任务页「···」菜单。
//  写入统一走 TaskPresentationActionCoordinator。
//

import SwiftUI

// MARK: - 象限展示扩展（规则页语义副标题）

extension TaskQuadrant {
    /// 两轴语义（象限规则页用；平铺页不再展示）
    var subtitleText: String {
        switch self {
        case .doFirst: return String(localized: "重要且紧急")
        case .scheduleTime: return String(localized: "重要不紧急")
        case .batchHandle: return String(localized: "非重要且紧急")
        case .reviewLater: return String(localized: "非重要不紧急")
        case .unclassified: return String(localized: "重要性未判断")
        }
    }
}

// MARK: - 矩阵主视图

struct TaskQuadrantBoardView: View {

    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    let repository: TodoRepository
    let onOpenDetail: (UUID) -> Void
    let onCreateInQuadrant: (TaskQuadrant) -> Void

    @State private var moveSheetTask: TaskRecordSnapshot?

    /// 任务行字号（随动态字号缩放）：标题基准 14 / subheadline，槽位 11、图标 9 / caption2
    @ScaledMetric(relativeTo: .subheadline) private var previewTitleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var previewSlotTextSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var previewSlotIconSize: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                quadrantSection(quadrant)
            }
            unclassifiedSection
        }
        .sheet(item: Binding(
            get: { moveSheetTask.map { SnapshotItem(snapshot: $0) } },
            set: { moveSheetTask = $0?.snapshot }
        )) { item in
            TaskQuadrantMoveSheet(
                snapshot: item.snapshot,
                repository: repository,
                now: model.now,
                calendar: model.calendar
            )
        }
    }

    private func members(of quadrant: TaskQuadrant) -> [TaskRecordSnapshot] {
        model.groupedMembers.first { $0.quadrant == quadrant }?.members ?? []
    }

    // MARK: - 单段（段头 + 全量任务；空段只剩段头）

    private func quadrantSection(_ quadrant: TaskQuadrant) -> some View {
        let members = members(of: quadrant)
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: quadrant.displayTitle,
                count: members.count,
                tint: quadrant.tintColor
            ) {
                onCreateInQuadrant(quadrant)
            }
            if !members.isEmpty {
                taskListCard(members, quadrant: quadrant)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(quadrant.displayTitle)，\(members.count)项"))
    }

    /// 待整理段：托盘图标 + 数量徽章；无新增钮（新建任务默认落这里）
    private var unclassifiedSection: some View {
        let members = model.unclassifiedMembers
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "tray")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                Text("待整理")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .opacity(members.isEmpty ? 0.55 : 1)
                HoloCountBadge(count: model.unclassifiedCount)
                Spacer()
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "待整理，\(model.unclassifiedCount)项"))
            if !members.isEmpty {
                taskListCard(members, quadrant: .unclassified)
            }
        }
    }

    /// 段头：色题 + 数量 + 44pt 新增热区；零值色题降透明度（空段安静）
    private func sectionHeader(
        title: String,
        count: Int,
        tint: Color,
        onCreate: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .opacity(count == 0 ? 0.55 : 1)
            Text(verbatim: "\(count)")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(tint.opacity(0.75))
            Spacer()
            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(tint.opacity(count == 0 ? 0.55 : 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "在\(title)中新增任务"))
        }
        .frame(minHeight: 44)
    }

    /// 段内任务卡：全宽行依次铺开，最后一条移走后整卡消失（无空态文案）
    private func taskListCard(_ members: [TaskRecordSnapshot], quadrant: TaskQuadrant) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                if index > 0 {
                    Rectangle()
                        .fill(Color.holoDivider.opacity(0.5))
                        .frame(height: 0.5)
                        .padding(.leading, 54)
                }
                previewRow(member, quadrant: quadrant)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 任务行（迷你进度环 + 标题 + 截止/计划两行槽位；长按菜单移动归类）

    private func previewRow(_ member: TaskRecordSnapshot, quadrant: TaskQuadrant) -> some View {
        let isPending = model.pendingCompletionTaskID == member.id
        let isDone = isPending || member.completed
        let due = dueFact(member)
        let plan = planText(member)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                if isPending {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                } else {
                    completionCoordinator.requestCompletion(taskID: member.id, source: .taskMatrix, in: repository)
                    HapticManager.taskCompletion()
                }
            } label: {
                miniProgressRing(member, isDone: isDone)
                    .frame(width: 32, height: 44, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone
                ? String(localized: "恢复\(member.title)")
                : String(localized: "完成\(member.title)"))

            Button {
                onOpenDetail(member.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.title)
                        .font(.system(size: previewTitleSize, weight: .medium, design: .default))
                        .foregroundColor(isDone ? .holoToolTextSecondary : .holoTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .strikethrough(isDone, color: .holoTextPlaceholder)
                    VStack(alignment: .leading, spacing: 2) {
                        // 槽1 时间事实：有截止 → calendar + 三态色；无截止但有计划 → clock + 计划时段上移
                        if let due {
                            previewSlot(text: due.text, icon: "calendar", color: due.color)
                        } else if let plan {
                            previewSlot(text: plan, icon: "clock", color: .holoTextSecondary)
                        }
                        // 槽2 执行事实：计划未占槽1时放计划，否则清单名兜底（无图标）
                        if let plan, due != nil {
                            previewSlot(text: plan, icon: "clock", color: .holoTextSecondary)
                        } else {
                            previewSlot(text: TaskExperienceRow.listLabel(for: member), icon: nil, color: .holoTextSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(previewVoiceOverLabel(member))
        }
        .contextMenu {
            Button {
                moveSheetTask = member
            } label: {
                Label(String(localized: "移动到象限"), systemImage: "square.grid.2x2")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .opacity(isDone ? 0.55 : 1)
    }

    /// 迷你进度环（口径同 TaskExperienceRow.progressRing，缩到 20pt）：
    /// 无子任务是 1.5pt 细空环（极浅描边）；有子任务画 2pt 进度弧；
    /// 完成/待确认叠对勾。点击行为仍是完成/撤回。
    private func miniProgressRing(_ member: TaskRecordSnapshot, isDone: Bool) -> some View {
        let items = member.checkItems
        let fraction = items.isEmpty ? 0 : Double(items.filter(\.isChecked).count) / Double(items.count)
        return ZStack {
            Circle()
                .stroke(Color.holoToolTextSecondary.opacity(0.3), lineWidth: 1.5)
            if !items.isEmpty {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.05))
                    .stroke(Color.holoTextPrimary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(HoloAnimation.snappy, value: fraction)
            }
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }
        }
        .frame(width: 20, height: 20)
    }

    /// 图标槽位行：图标与文字同色、单行尾截断（每槽只放一个字段，永不拼接）
    private func previewSlot(text: String, icon: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: previewSlotIconSize))
                    .foregroundColor(color)
            }
            Text(text)
                .font(.system(size: previewSlotTextSize))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 槽1 截止文案与三态色：逾期红 / 今天主色 / 其他次级。
    /// 逾期非今天「M月d日 · 已逾期」；逾期且今天「今天 HH:mm · 已逾期」；
    /// 未逾期复用 formatNatural 口径 +「截止」后缀（全天不含时刻）。
    private func dueFact(_ member: TaskRecordSnapshot) -> (text: String, color: Color)? {
        guard let due = member.effectiveDue(calendar: model.calendar) else { return nil }
        if member.isOverdue(asOf: model.now, calendar: model.calendar) {
            if model.calendar.isDateInToday(due) {
                let time = member.isAllDay ? "" : " " + Self.slotTimeFormatter.string(from: due)
                return (String(localized: "今天") + time + String(localized: " · 已逾期"), .holoToolError)
            }
            return (Self.slotDateFormatter.string(from: due) + String(localized: " · 已逾期"), .holoToolError)
        }
        let text = TaskExperienceRow.formatNatural(due, member: member, calendar: model.calendar) + String(localized: " 截止")
        if model.calendar.isDateInToday(due) { return (text, .holoPrimary) }
        return (text, .holoTextSecondary)
    }

    /// 计划时段文案：今天「HH:mm–HH:mm」；明天「明天 HH:mm–HH:mm」；更远「M月d日 HH:mm」（舍结束时刻）
    private func planText(_ member: TaskRecordSnapshot) -> String? {
        guard member.hasValidPlannedRange,
              let start = member.plannedStart,
              let end = member.plannedEnd else { return nil }
        let range = "\(Self.slotTimeFormatter.string(from: start))–\(Self.slotTimeFormatter.string(from: end))"
        if model.calendar.isDateInToday(start) { return range }
        if model.calendar.isDateInTomorrow(start) { return String(localized: "明天") + " " + range }
        return Self.slotDateFormatter.string(from: start) + " " + Self.slotTimeFormatter.string(from: start)
    }

    /// VoiceOver 合并朗读：标题 + 截止状态 + 计划时段 + 子任务 x/y
    private func previewVoiceOverLabel(_ member: TaskRecordSnapshot) -> String {
        var parts = [member.title]
        if let due = dueFact(member) {
            parts.append(due.text)
        }
        if let plan = planText(member) {
            parts.append(String(localized: "计划 \(plan)"))
        }
        if !member.checkItems.isEmpty {
            let done = member.checkItems.filter(\.isChecked).count
            parts.append(String(localized: "子任务 \(done)/\(member.checkItems.count)"))
        }
        return parts.joined(separator: "，")
    }

    /// 槽位格式化器（与 TaskExperienceRow.formatNatural 同口径）
    private static let slotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter
    }()

    private static let slotTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - item 包装

/// 快照 sheet item 包装（多视图各弹层共用）
struct SnapshotItem: Identifiable {
    let snapshot: TaskRecordSnapshot
    var id: UUID { snapshot.id }
}

// MARK: - 象限规则说明（入口在任务页「···」菜单）

struct TaskQuadrantRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text("四象限沿用 Holo 现有判断，不修改旧任务分类。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                        HStack {
                            Text(quadrant.displayTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(quadrant.tintColor)
                            Spacer()
                            Text(quadrant.subtitleText)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                        .padding(.vertical, 10)
                    }
                    Divider()
                    Text("重要性 P1 在重要侧，P2 / P3 在非重要侧。\n紧急性 P1 为紧急，P2 / P3 为非紧急。\n自动：逾期、今天 / 明天 / 后天截止 → P1；3–7 天 → P2；更远或无截止 → P3。\n重要性未判断的任务在待整理，仍保留逾期提示。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("移动象限后紧急性变为手动判断。可在任务详情「轻重缓急」里恢复「按截止日期自动判断」。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                // 半屏 detent 装不下全部内容：底部让位让末段能完整滚出（8 处贴底联动之一）
                .padding(.bottom, HoloSpacing.xl)
            }
            .navigationTitle(String(localized: "象限规则"))
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
