//
//  MacTaskQuadrantBoardView.swift
//  HoloMac
//
//  四象限看板根视图（2026-10-30，挂载于 MacTasksWorkspaceView 的 content 列）：
//  头部（标题/计数 + 快速收集条）→ 教学一行 → 待确认横条 → 2×2 矩阵。
//  四格同屏全览、跨格拖拽（onDrag + dropDestination，payload 只放任务 UUID）、
//  落格写入唯一走 TaskPresentationActionCoordinator.commitQuadrantMove；
//  ⌘⌥1–4 把选中卡片送进对应格（⌘1/⌘2 已被模块切换占用，故加 Option）。
//  撤回 toast 由工作台根统一路由（观察 coordinator.$undoable）。
//

import SwiftUI
import OSLog

// MARK: - 动作上下文（看板各子视图回调一次性打包）

struct MacQuadrantBoardActions {
    let onToggleCompletion: (TodoTask, (checkItemID: UUID, wasChecked: Bool)?) -> Void
    let onPostpone: (TodoTask) -> Void
    let onMoveToList: (TodoTask) -> Void
    let onArchive: (TodoTask) -> Void
    let onCopyTitle: (TodoTask) -> Void
    let onDelete: (TodoTask) -> Void
    /// 右键「移到象限」
    let onMoveToQuadrant: (TodoTask, TaskQuadrant) -> Void
    /// 拖放/⌘⌥快捷键提交（按 UUID 重读，coordinator 唯一写入路径）
    let onCommitMove: (UUID, TaskQuadrant) -> Void
    /// 点卡片：选中 + 滑出详情 inspector
    let onSelect: (TodoTask) -> Void
}

// MARK: - 待确认行右键菜单（卡片菜单由 TaskCardView 内建，池行在此共享同语义）

enum MacQuadrantTaskMenu {
    @ViewBuilder
    static func menuContent(
        for task: TodoTask,
        currentQuadrant: TaskQuadrant?,
        actions: MacQuadrantBoardActions
    ) -> some View {
        Button {
            actions.onToggleCompletion(task, nil)
        } label: {
            Label(
                task.completed ? "标记为未完成" : "标记为完成",
                systemImage: task.completed ? "arrow.uturn.backward.circle" : "checkmark.circle")
        }
        if task.dueDate != nil && !task.completed && task.repeatRule == nil {
            Button {
                actions.onPostpone(task)
            } label: {
                Label("延期", systemImage: "calendar.badge.clock")
            }
        }
        Button {
            actions.onMoveToList(task)
        } label: {
            Label("移动到清单", systemImage: "tray.and.arrow.down")
        }
        if let currentQuadrant {
            Menu {
                ForEach(TaskQuadrant.overviewOrder, id: \.self) { target in
                    Button {
                        actions.onMoveToQuadrant(task, target)
                    } label: {
                        if target == currentQuadrant {
                            Label(target.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(target.displayTitle)
                        }
                    }
                    .disabled(target == currentQuadrant)
                }
            } label: {
                Label("移到象限", systemImage: "square.grid.2x2")
            }
        }
        Divider()
        Button {
            actions.onCopyTitle(task)
        } label: {
            Label("复制标题", systemImage: "doc.on.doc")
        }
        Button {
            actions.onArchive(task)
        } label: {
            Label("归档", systemImage: "archivebox")
        }
        Button(role: .destructive) {
            actions.onDelete(task)
        } label: {
            Label("删除任务", systemImage: "trash")
        }
    }
}

// MARK: - 看板根视图

struct MacTaskQuadrantBoardView: View {

    // MARK: 工作台转发回调

    let onToggleCompletion: (TodoTask, (checkItemID: UUID, wasChecked: Bool)?) -> Void
    let onPostpone: (TodoTask) -> Void
    let onMoveToList: (TodoTask) -> Void
    let onArchive: (TodoTask) -> Void
    let onCopyTitle: (TodoTask) -> Void
    let onDelete: (TodoTask) -> Void

    @Binding var selectedTaskId: UUID?
    /// 收集条聚焦脉冲（⌘N / ⌘F 触发）
    var captureFocusTrigger: Int
    /// 撤回 toast（宿主为工作台根，本视图只负责呈现）
    var toastMessage: String?
    var toastAction: (() -> Void)?
    /// 详情 inspector 开合（.inspector 挂在工作台根，状态由本视图驱动）
    @Binding var inspectorShown: Bool

    @StateObject private var model = MacQuadrantBoardModel()
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    var body: some View {
        VStack(spacing: HoloSpacing.sm) {
            header
            teachLine

            if !model.hasLoadedOnce {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                if !model.unclassified.isEmpty {
                    MacQuadrantPoolView(
                        tasks: model.unclassified,
                        pendingTaskID: pendingTaskID,
                        selectedTaskId: $selectedTaskId,
                        actions: actions)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                grid
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.holoToolBackground)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                undoToast(toastMessage)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.unclassified.map(\.id))
        .animation(.spring(response: 0.3), value: model.layoutSignature)
        .onAppear { model.setup() }
        .background(moveShortcuts)
    }

    private var pendingTaskID: UUID? {
        completionCoordinator.pending?.taskID
    }

    // MARK: - 头部与教学行

    private var header: some View {
        HStack(alignment: .center, spacing: HoloSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "四象限"))
                    .holoText(.sectionTitle)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                Text(String(localized: "\(model.activeCount) 项任务"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer(minLength: HoloSpacing.md)
            MacQuadrantCaptureBar(focusTrigger: captureFocusTrigger) { title, openDetail in
                captureCreate(title: title, openDetail: openDetail)
            }
        }
        .accessibilityIdentifier("mac.task.board.header")
    }

    private var teachLine: some View {
        Text(String(localized: "重要性决定取舍，紧急性决定先后。拖动任务可归类，点 ＋ 建进格子。"))
            .font(.holoCaption)
            .foregroundColor(.holoToolTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 2×2 矩阵（两行等高，格内独立滚动）

    private var grid: some View {
        let rows = stride(from: 0, to: model.groups.count, by: 2).map {
            Array(model.groups[$0..<min($0 + 2, model.groups.count)])
        }
        return VStack(spacing: HoloSpacing.md) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: HoloSpacing.md) {
                    ForEach(row) { group in
                        MacQuadrantCellView(
                            quadrant: group.quadrant,
                            tasks: group.tasks,
                            poolCount: model.unclassified.count,
                            pendingTaskID: pendingTaskID,
                            selectedTaskId: $selectedTaskId,
                            repository: model.repository,
                            actions: actions,
                            onCreate: { title, openDetail in
                                createInQuadrant(group.quadrant, title: title, openDetail: openDetail)
                            })
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - 建档（收集条 → 待确认；格内联 → 直接建入该格，与拖入同口径）

    private func captureCreate(title: String, openDetail: Bool) {
        // 全默认值（importance unknown / urgencyMode auto）→ 解析入待确认
        let task = try? model.repository.createTask(title: title)
        model.reloadNow()
        if openDetail, let task {
            selectedTaskId = task.id
            inspectorShown = true
        }
    }

    private func createInQuadrant(_ quadrant: TaskQuadrant, title: String, openDetail: Bool) {
        let task = try? model.repository.createTask(
            title: title,
            importance: quadrant.creationImportance,
            urgencyMode: quadrant.creationUrgencyMode)
        model.reloadNow()
        if openDetail, let task {
            selectedTaskId = task.id
            inspectorShown = true
        }
    }

    // MARK: - 动作集合（写入唯一走 coordinator）

    var actions: MacQuadrantBoardActions {
        MacQuadrantBoardActions(
            onToggleCompletion: { task, trigger in onToggleCompletion(task, trigger) },
            onPostpone: onPostpone,
            onMoveToList: onMoveToList,
            onArchive: onArchive,
            onCopyTitle: onCopyTitle,
            onDelete: onDelete,
            onMoveToQuadrant: { task, target in commitMove(taskID: task.id, target: target) },
            onCommitMove: { taskID, target in commitMove(taskID: taskID, target: target) },
            onSelect: { task in
                selectedTaskId = task.id
                inspectorShown = true
            })
    }

    private func commitMove(taskID: UUID, target: TaskQuadrant) {
        TaskPresentationActionCoordinator.shared.commitQuadrantMove(
            taskID: taskID,
            target: target,
            repository: model.repository,
            now: model.now,
            calendar: model.calendar)
        model.reloadNow()
    }

    // MARK: - ⌘⌥1–4 快捷移格（⌘1/⌘2 已被模块切换占用）

    @ViewBuilder
    private var moveShortcuts: some View {
        if selectedTaskId != nil {
            Group {
                ForEach(Array(TaskQuadrant.overviewOrder.enumerated()), id: \.element) { index, target in
                    Button("") {
                        if let taskID = selectedTaskId {
                            commitMove(taskID: taskID, target: target)
                        }
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: [.command, .option])
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - 撤回 toast（与中栏同形态）

    private func undoToast(_ message: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Text(message)
                .font(.holoLabel)
                .foregroundColor(.holoToolText)
            if let toastAction {
                Button(String(localized: "撤回")) {
                    toastAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoToolInset)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2))
        .padding(.bottom, HoloSpacing.lg)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
