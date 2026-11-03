//
//  MacQuadrantCellView.swift
//  HoloMac
//
//  四象限单格：象限色头（标题/计数/副标题/＋）+ 复用 TaskCardView 的卡片流
//  + 格内就地新建（回车建入本格，与拖入同口径）+ dropDestination 落格高亮。
//  格内独立滚动、内容顶对齐；空格按「待整理有货/无货」切换引导文案。
//

import SwiftUI

struct MacQuadrantCellView: View {

    let quadrant: TaskQuadrant
    let tasks: [TodoTask]
    /// 待整理池数量（空格引导切换依据）
    let poolCount: Int
    /// 完成撤回窗口中的任务（卡片投影态）
    let pendingTaskID: UUID?
    @Binding var selectedTaskId: UUID?
    let repository: TodoRepository
    let actions: MacQuadrantBoardActions
    /// 就地建档回调：(标题, 是否选中新卡并滑出详情)
    let onCreate: (String, _ openDetail: Bool) -> Void

    @State private var dropHovering = false
    @State private var inlineVisible = false
    @State private var inlineText = ""
    @FocusState private var inlineFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 8) {
                    if inlineVisible {
                        inlineField
                    }
                    ForEach(tasks, id: \.id) { task in
                        card(task)
                    }
                    if tasks.isEmpty && !inlineVisible {
                        emptyGuidanceView
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .strokeBorder(
                    dropHovering ? quadrant.tintColor : Color.clear,
                    lineWidth: 2)
                .background(
                    // 悬停着色铺在格底上（border 只描边不填充）
                    RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                        .fill(dropHovering ? quadrant.tintColor.opacity(0.06) : Color.clear))
        )
        .dropDestination(for: String.self) { items, _ in
            dropHovering = false
            guard let payload = items.first,
                  let taskID = UUID(uuidString: payload) else { return false }
            actions.onCommitMove(taskID, quadrant)
            return true
        } isTargeted: { hovering in
            dropHovering = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(quadrant.displayTitle)，\(tasks.count)项"))
        .accessibilityIdentifier("mac.task.board.cell.\(String(describing: quadrant))")
    }

    // MARK: - 格头

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(quadrant.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(quadrant.tintColor)
                        .lineLimit(1)
                    Text(verbatim: "\(tasks.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(quadrant.tintColor.opacity(0.75))
                }
                Text(quadrant.subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(quadrant.tintColor.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { inlineVisible = true }
                inlineFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(quadrant.tintColor)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "在\(quadrant.displayTitle)中新增任务"))
            .accessibilityIdentifier("mac.task.board.plus.\(String(describing: quadrant))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(quadrant.backgroundColor)
    }

    // MARK: - 卡片（复用 TaskCardView + 选中描边 + 拖拽源）

    private func card(_ task: TodoTask) -> some View {
        let isSelected = selectedTaskId == task.id
        let isCompleting = pendingTaskID == task.id
        return TaskCardView(
            task: task,
            repository: repository,
            onNavigate: { actions.onSelect(task) },
            isCompleting: isCompleting,
            onToggleCompletion: { trigger in actions.onToggleCompletion(task, trigger) },
            onNavigateToAnniversary: nil,
            onPostpone: canPostpone(task) ? { actions.onPostpone(task) } : nil,
            onMoveToList: { actions.onMoveToList(task) },
            onArchive: { actions.onArchive(task) },
            onCopyTitle: { actions.onCopyTitle(task) },
            onDelete: { actions.onDelete(task) },
            currentQuadrant: quadrant,
            onMoveToQuadrant: { target in actions.onMoveToQuadrant(task, target) })
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .strokeBorder(isSelected ? Color.holoPrimary : Color.clear, lineWidth: 1.5))
            .onDrag {
                NSItemProvider(object: task.id.uuidString as NSString)
            } preview: {
                MacQuadrantDragPreview(title: task.title, sourceTint: quadrant.tintColor)
            }
    }

    /// 延期条件与中栏口径一致：有日期且未完成（重复任务不提供延期）
    private func canPostpone(_ task: TodoTask) -> Bool {
        task.dueDate != nil && !task.completed && task.repeatRule == nil
    }

    // MARK: - 格内联输入

    private var inlineField: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "新建到「\(quadrant.displayTitle)」…"), text: $inlineText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.holoToolText)
                .focused($inlineFocused)
                .onSubmit { create(openDetail: false) }
                .onKeyPress(.tab) {
                    create(openDetail: true)
                    closeInline()
                    return .handled
                }
                .onKeyPress(.escape) {
                    inlineText = ""
                    closeInline()
                    return .handled
                }

            Button {
                inlineText = ""
                closeInline()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "收起输入框"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(Color.holoToolInset))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .strokeBorder(Color.holoPrimary.opacity(0.5), lineWidth: 1))
        .accessibilityIdentifier("mac.task.board.inlineField.\(String(describing: quadrant))")
    }

    /// 回车建入本格、清空续输；Tab 建档选中并滑出详情
    private func create(openDetail: Bool) {
        let title = inlineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        inlineText = ""
        onCreate(title, openDetail)
    }

    private func closeInline() {
        withAnimation(.easeOut(duration: 0.15)) { inlineVisible = false }
    }

    // MARK: - 空格引导（待整理有货 → 归位引导；无货 → 各自文案）

    private var emptyGuidanceText: String {
        guard poolCount > 0 else { return quadrant.emptyGuidance }
        if quadrant == .doFirst {
            return String(localized: "有 \(poolCount) 件事等着归位\n从待整理拖一件进来")
        }
        return String(localized: "从待整理拖一件进来\n或点 ＋ 添加任务")
    }

    private var emptyGuidanceView: some View {
        Text(emptyGuidanceText)
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .top)
            .padding(.top, 14)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
