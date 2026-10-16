//
//  TaskQuadrantBoardView.swift
//  Holo
//
//  四象限矩阵（多视图方案 §6）：固定 2×2 格、每格前 2 条预览 + 查看全部、
//  每格新增、跨格拖动（onDrag + dropDestination，payload 只放任务 UUID）、
//  待整理独立入口与规则说明。格内不滚动，四格同在一个竖向内容滚动区；
//  大字号/窄内容宽降级单列。写入统一走 TaskPresentationActionCoordinator。
//

import SwiftUI

// MARK: - 象限展示扩展（副标题与空格引导，多视图 §6.1 表）

extension TaskQuadrant {
    /// 格副标题（两轴语义）
    var subtitleText: String {
        switch self {
        case .doFirst: return String(localized: "重要且紧急")
        case .scheduleTime: return String(localized: "重要不紧急")
        case .batchHandle: return String(localized: "非重要且紧急")
        case .reviewLater: return String(localized: "非重要不紧急")
        case .unclassified: return String(localized: "重要性未判断")
        }
    }

    /// 空格保留位置时的简短引导（不重复整页教学）
    var emptyGuidance: String {
        switch self {
        case .doFirst: return String(localized: "眼前没有急事\n点 ＋ 添加任务")
        case .scheduleTime: return String(localized: "给重要的事留一点时间\n点 ＋ 添加任务")
        case .batchHandle: return String(localized: "把零碎小事集中处理\n点 ＋ 添加任务")
        case .reviewLater: return String(localized: "暂时没有这类任务\n点 ＋ 添加任务")
        case .unclassified: return String(localized: "没有待整理任务")
        }
    }
}

// MARK: - 矩阵主视图

struct TaskQuadrantBoardView: View {

    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject var session: TaskPresentationSession
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    let repository: TodoRepository
    let onOpenDetail: (UUID) -> Void
    let onCreateInQuadrant: (TaskQuadrant) -> Void
    let onOpenTriage: () -> Void

    @State private var dropTargetQuadrant: TaskQuadrant?
    @State private var showRulesSheet = false
    @State private var expandedQuadrant: TaskQuadrant?
    @State private var moveSheetTask: TaskRecordSnapshot?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.holoContentWidth) private var contentWidth

    /// §9.4：375pt 默认字体仍 2×2；字号达 accessibility 或有效内容宽 <350 才单列
    private var usesSingleColumn: Bool {
        dynamicTypeSize.isAccessibilitySize || (contentWidth ?? 430) < 350
    }

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            introText
            quadrantGrid
            triageTray
            rulesButton
        }
        .sheet(item: Binding(
            get: { expandedQuadrant.map { QuadrantItem(quadrant: $0) } },
            set: { expandedQuadrant = $0?.quadrant }
        )) { item in
            TaskQuadrantExpandedSheet(
                quadrant: item.quadrant,
                model: model,
                repository: repository,
                onOpenDetail: onOpenDetail,
                onCreateInQuadrant: onCreateInQuadrant
            )
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
        .sheet(isPresented: $showRulesSheet) {
            TaskQuadrantRulesSheet()
        }
    }

    /// 轻教学一行（不重复整页教学，§6.1）
    private var introText: some View {
        Text("重要性决定取舍，紧急性决定先后。按住任务可拖动归类，也可以在详情中移动。")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, HoloSpacing.xs)
    }

    private var quadrantGrid: some View {
        let groups = model.groupedMembers
        return Group {
            if usesSingleColumn {
                VStack(spacing: HoloSpacing.md) {
                    Text("已按大字号展开")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                        quadrantCell(quadrant, members: members(of: quadrant, in: groups))
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: HoloSpacing.md), GridItem(.flexible())], spacing: HoloSpacing.md) {
                    ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                        quadrantCell(quadrant, members: members(of: quadrant, in: groups))
                    }
                }
            }
        }
    }

    private func members(of quadrant: TaskQuadrant, in groups: [(quadrant: TaskQuadrant, members: [TaskRecordSnapshot])]) -> [TaskRecordSnapshot] {
        groups.first { $0.quadrant == quadrant }?.members ?? []
    }

    // MARK: - 单格

    private func quadrantCell(_ quadrant: TaskQuadrant, members: [TaskRecordSnapshot]) -> some View {
        VStack(spacing: 0) {
            // 淡底标题区：上色线 + 标题/总数/副标题 + 44pt 新增热区（§9.2）
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button {
                        expandedQuadrant = quadrant
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(quadrant.displayTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(quadrant.tintColor)
                                Text(verbatim: "\(members.count)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(quadrant.tintColor.opacity(0.75))
                            }
                            Text(quadrant.subtitleText)
                                .font(.system(size: 11))
                                .foregroundColor(quadrant.tintColor.opacity(0.8))
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(quadrant.displayTitle)，\(quadrant.subtitleText)，\(members.count)项"))

                    Spacer(minLength: 0)
                    Button {
                        onCreateInQuadrant(quadrant)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(quadrant.tintColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "在\(quadrant.displayTitle)中新增任务"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(quadrant.backgroundColor)

            // 前 2 条预览 / 空态引导
            if members.isEmpty {
                Text(quadrant.emptyGuidance)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(members.prefix(2)) { member in
                        previewRow(member, quadrant: quadrant)
                    }
                }
                if members.count > 2 {
                    Button {
                        expandedQuadrant = quadrant
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看全部 \(members.count) 项")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "查看\(quadrant.displayTitle)全部\(members.count)项"))
                }
            }
        }
        .frame(minHeight: usesSingleColumn ? 0 : 244, alignment: .top)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    dropTargetQuadrant == quadrant ? quadrant.tintColor : Color.clear,
                    lineWidth: 2
                )
        )
        .dropDestination(for: String.self) { items, _ in
            defer { dropTargetQuadrant = nil }
            guard let payload = items.first,
                  let taskID = UUID(uuidString: payload) else { return false }
            TaskPresentationActionCoordinator.shared.commitQuadrantMove(
                taskID: taskID,
                target: quadrant,
                repository: repository,
                now: model.now,
                calendar: model.calendar
            )
            return true
        } isTargeted: { hovering in
            dropTargetQuadrant = hovering ? quadrant : nil
        }
    }

    // MARK: - 预览行（完成圆圈 + 两行标题 + 一行清单/截止；长按正文拖动）

    private func previewRow(_ member: TaskRecordSnapshot, quadrant: TaskQuadrant) -> some View {
        let isPending = model.pendingCompletionTaskID == member.id
        return HStack(alignment: .top, spacing: 4) {
            Button {
                if isPending {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                } else {
                    completionCoordinator.requestCompletion(taskID: member.id, source: .taskMatrix, in: repository)
                    HapticManager.taskCompletion()
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.holoToolTextSecondary.opacity(0.5), lineWidth: 1.5)
                    if isPending || member.completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
                .frame(width: 20, height: 20)
                .frame(minWidth: 44, minHeight: 44, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPending || member.completed
                ? String(localized: "恢复\(member.title)")
                : String(localized: "完成\(member.title)"))

            Button {
                onOpenDetail(member.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isPending || member.completed ? .holoToolTextSecondary : .holoTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .strikethrough(isPending || member.completed, color: .holoTextPlaceholder)
                    Text(previewMeta(member))
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("移动到象限")) {
                moveSheetTask = member
            }
            .onDrag {
                // 拖动影像显示标题与原格色线（不是截图形式的新任务，§6.3-2）
                HapticManager.light()
                return NSItemProvider(object: member.id.uuidString as NSString)
            } preview: {
                TaskQuadrantDragPreview(member: member, quadrant: quadrant)
            }
        }
        .padding(.horizontal, 6)
        .opacity(isPending ? 0.55 : 1)
    }

    private func previewMeta(_ member: TaskRecordSnapshot) -> String {
        var parts = [TaskExperienceRow.listLabel(for: member)]
        if let due = member.effectiveDue(calendar: model.calendar) {
            parts.append(TaskExperienceRow.formatNatural(due, member: member, calendar: model.calendar) + String(localized: "截止"))
        } else {
            parts.append(String(localized: "未设截止"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 待整理与规则

    private var triageTray: some View {
        Button {
            onOpenTriage()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("待整理")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextPrimary)
                        HoloCountBadge(count: model.unclassifiedCount)
                    }
                    Text("先判断重要性，再决定放在哪里")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "待整理，\(model.unclassifiedCount)项"))
    }

    private var rulesButton: some View {
        Button {
            showRulesSheet = true
        } label: {
            Text("了解象限规则")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 拖动影像（标题 + 原格色线）

private struct TaskQuadrantDragPreview: View {
    let member: TaskRecordSnapshot
    let quadrant: TaskQuadrant

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(quadrant.tintColor)
                .frame(width: 3, height: 28)
            Text(member.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)
        }
        .padding(10)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }
}

// MARK: - item 包装

struct QuadrantItem: Identifiable {
    let quadrant: TaskQuadrant
    var id: String { String(describing: quadrant) }
}

/// 快照 sheet item 包装（多视图各弹层共用）
struct SnapshotItem: Identifiable {
    let snapshot: TaskRecordSnapshot
    var id: UUID { snapshot.id }
}

// MARK: - 象限规则说明（§6.1 末段）

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
            }
            .navigationTitle(String(localized: "象限规则"))
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
