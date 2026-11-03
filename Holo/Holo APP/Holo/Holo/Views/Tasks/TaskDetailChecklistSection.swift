//
//  TaskDetailChecklistSection.swift
//  Holo
//
//  任务详情子任务区（列表 / 添加行 / 勾选联动 / 拆解入口 / 庆祝动效）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskDetailView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI
import OSLog

// MARK: - 新建模式暂存子任务

struct PendingCheckItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
}

// MARK: - 子任务区

struct TaskDetailChecklistSection: View {

    @ObservedObject var repository: TodoRepository
    let existingTask: TodoTask?
    @Binding var checkItems: [CheckItem]
    @Binding var pendingCheckItems: [PendingCheckItem]
    @Binding var displayedChecklistProgress: Double
    @Binding var showSaveErrorAlert: Bool
    @Binding var showTaskSplitSheet: Bool
    @Binding var waitingCheckItem: CheckItem?
    @Binding var newCheckItemTitle: String
    @Binding var showChecklistCompletionCelebration: Bool
    @Binding var checklistCompletionCelebrationID: UUID

    let addCheckItem: () -> Void
    let resumeWaiting: (CheckItem) -> Void
    let toggleCompletion: ((checkItemID: UUID, wasChecked: Bool)?) -> Void
    let checklistProgress: () -> Double
    let applyChecklistProgressChange: (Double?, Double) -> Void

    @State private var editingCheckItemId: UUID?
    @State private var editingCheckItemTitle = ""
    @FocusState private var isCheckItemEditing: Bool
    @FocusState private var isAddingCheckItemFocused: Bool

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行：子任务 + 说明 + 计数
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("子任务")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Text("把大任务拆成小步骤")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))

                Spacer()

                if totalCheckItemCount > 0 {
                    if existingTask == nil {
                        // 新建模式：只报步骤数；编辑模式的进度由下方
                        // 「已完成 n/m 项」文字承载，标题行不再重复计数（动效融合定稿 §5）
                        Text("\(pendingCheckItems.count)")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 子任务计数文字（编辑模式，基于本地数组实时计算）：
            // 用户视角报「还剩几步」——剩下多少比已完成多少更常被关心
            if existingTask != nil, !checkItems.isEmpty {
                let remainingCount = checkItems.filter { !$0.isChecked }.count
                let isComplete = remainingCount == 0

                HStack {
                    Spacer()
                    Text(isComplete ? String(localized: "全部完成") : String(localized: "还剩 \(remainingCount) 步"))
                        .font(.holoCaption)
                        .foregroundColor(isComplete ? .holoSuccess : .holoTextSecondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .overlay {
                    if showChecklistCompletionCelebration {
                        TaskChecklistCelebrationView {
                            showChecklistCompletionCelebration = false
                        }
                        .id(checklistCompletionCelebrationID)
                        .frame(height: 90)
                        .offset(y: -28)
                        .allowsHitTesting(false)
                    }
                }
            }

            // 拆成几步（2026-10-11 拆开瘦身）：行式入口落在子任务卡头部，
            // 整条链路只在点它时调一次 AI
            if let task = existingTask, !task.completed {
                TaskSplitEntryRow(existingStepCount: checkItems.count) {
                    showTaskSplitSheet = true
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            // 子任务列表
            if existingTask != nil {
                ForEach(checkItems, id: \.id) { item in
                    checkItemRow(item)
                    if item.id != checkItems.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            } else {
                ForEach(pendingCheckItems) { item in
                    HStack(alignment: .top, spacing: HoloSpacing.sm) {
                        Image(systemName: "circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.holoTextSecondary.opacity(0.5))

                        Text(item.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineSpacing(2)

                        Spacer()

                        Button {
                            withAnimation(HoloAnimation.standard) {
                                pendingCheckItems.removeAll { $0.id == item.id }
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.holoTextSecondary.opacity(0.55))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, -3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    if item.id != pendingCheckItems.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }

            addCheckItemRow
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    /// 当前子任务总数（编辑=库内，新建=暂存）
    private var totalCheckItemCount: Int {
        existingTask != nil ? checkItems.count : pendingCheckItems.count
    }

    /// 编辑模式的子任务行：序号 + 圈勾选 + 文字改名 + 等待徽章 + ⋯ 菜单
    private func checkItemRow(_ item: CheckItem) -> some View {
        let rowNumber = checkItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? 0
        return HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Text(verbatim: "\(rowNumber)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 3)

            Button {
                toggleCheckItem(item)
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
                    .symbolEffect(.bounce, value: item.isChecked)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                if editingCheckItemId == item.id {
                    TextField("子任务内容", text: $editingCheckItemTitle, axis: .vertical)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineSpacing(2)
                        .focused($isCheckItemEditing)
                        .submitLabel(.done)
                        .onSubmit {
                            commitCheckItemEdit(item)
                        }
                        .onChange(of: isCheckItemEditing) { _, focused in
                            if !focused {
                                commitCheckItemEdit(item)
                            }
                        }
                } else {
                    Text(item.title)
                        .font(.holoBody)
                        .foregroundColor(item.isChecked || item.isWaiting ? .holoTextSecondary : .holoTextPrimary)
                        .strikethrough(item.isChecked, color: .holoTextSecondary)
                        .lineSpacing(2)
                        .onTapGesture {
                            startCheckItemEdit(item)
                        }
                }

                // 等待徽章 + 提醒标记（2026-10-11 拆开瘦身）；备注为用户输入不限长，锁单行截断防chip错位
                if item.isWaiting && !item.isChecked {
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(item.waitNote.map { String(localized: "等待中 · \($0)") } ?? String(localized: "等待中"))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.holoTinyLabel)
                        .foregroundColor(.orange)
                        if let remindAt = item.reviewRemindAt {
                            HStack(spacing: 3) {
                                Image(systemName: "bell")
                                    .font(.system(size: 10))
                                Text(verbatim: "\(remindAt.formatted(.dateTime.month().day().hour().minute())) 提醒")
                            }
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }

            Spacer()

            Menu {
                Button(item.isChecked ? String(localized: "还没做完") : String(localized: "做完了")) {
                    toggleCheckItem(item)
                }
                if item.isWaiting {
                    Button(String(localized: "等到了，接着做")) {
                        resumeWaiting(item)
                    }
                } else {
                    Button(String(localized: "先等等…")) {
                        waitingCheckItem = item
                    }
                }
                Button(String(localized: "改一下")) {
                    startCheckItemEdit(item)
                }
                Button(role: .destructive) {
                    deleteCheckItem(item)
                } label: {
                    Text("删除")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("checkItemMenuButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 底部常驻添加行：唯一提交动作 = 回车或行尾「＋」；提交后保持聚焦连续录入
    private var addCheckItemRow: some View {
        let hasText = !newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty

        return HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoPrimary)

            TextField("添加子任务，输入后按回车", text: $newCheckItemTitle)
                .accessibilityIdentifier("task.detail.addStep")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(2)
                .focused($isAddingCheckItemFocused)
                .submitLabel(.done)
                .onSubmit {
                    // 有内容：入列并保持聚焦，连续录下一条；
                    // 空内容：收起键盘，停止录入（原型的「想停就停」）
                    let hadText = !newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty
                    addCheckItem()
                    isAddingCheckItemFocused = hadText
                }
                .onChange(of: isAddingCheckItemFocused) { _, focused in
                    // 失焦时若框内仍有未提交内容，自动入列，避免切走丢字
                    if !focused && !showSaveErrorAlert {
                        addCheckItem()
                    }
                }

            Button {
                addCheckItem()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(hasText ? .white : .holoPrimary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(hasText ? Color.holoPrimary : Color.holoPrimary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .accessibilityIdentifier("task.detail.addStep.confirm")
            .animation(HoloAnimation.quick, value: hasText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggleCheckItem(_ item: CheckItem) {
        let progressBeforeChange = checklistProgress()
        displayedChecklistProgress = progressBeforeChange

        do {
            // 勾选前先取旧值：作为「触发父任务完成」的撤回恢复依据（与任务卡同一契约）
            let wasChecked = item.isChecked
            try repository.toggleCheckItem(item)
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }

                // 与任务卡同一条联动规则：子任务全勾 → 自动完成主任务；
                // 已完成任务出现未勾子任务 → 自动回未完成，避免「父完成 + 子未完成」矛盾状态
                // （2026-10-11 拆开瘦身：等待项 = 未勾，天然不触发完成，无需特判）
                let allChecked = !items.isEmpty && items.allSatisfy(\.isChecked)
                if allChecked != task.completed {
                    toggleCompletion(allChecked ? (checkItemID: item.id, wasChecked: wasChecked) : nil)
                }
            }
            applyChecklistProgressChange(progressBeforeChange, checklistProgress())
        } catch {
            Self.logger.error("切换子任务失败：\(error.localizedDescription)")
        }
    }

    private func deleteCheckItem(_ item: CheckItem) {
        let itemID = item.id
        if editingCheckItemId == itemID {
            editingCheckItemId = nil
            editingCheckItemTitle = ""
            isCheckItemEditing = false
        }
        let progressBeforeChange = checklistProgress()
        displayedChecklistProgress = progressBeforeChange

        do {
            // 先移出本地数组再删除：仓库 save 后被删对象即刻失效，
            // 此后任何属性访问（包括 removeAll 闭包里的 .id）都会触发 fault 闪退
            checkItems.removeAll { $0.id == itemID }
            try repository.deleteCheckItem(item)
            applyChecklistProgressChange(progressBeforeChange, checklistProgress())
        } catch {
            Self.logger.error("删除子任务失败：\(error.localizedDescription)")
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }
            }
            applyChecklistProgressChange(nil, checklistProgress())
        }
    }

    private func startCheckItemEdit(_ item: CheckItem) {
        // 切换目标前先提交在途草稿：共享草稿串即将被覆盖，旧条目的失焦提交
        // 又被 id 守卫拦下，两条路都会丢字——先落盘再切换（对齐添加行的失焦保护）
        if let editingID = editingCheckItemId, editingID != item.id,
           let editingItem = checkItems.first(where: { $0.id == editingID }) {
            commitCheckItemEdit(editingItem)
        }
        editingCheckItemId = item.id
        editingCheckItemTitle = item.title
        isCheckItemEditing = true
    }

    private func commitCheckItemEdit(_ item: CheckItem) {
        guard editingCheckItemId == item.id else { return }
        let trimmed = editingCheckItemTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != item.title {
            do {
                try repository.updateCheckItemTitle(item, newTitle: trimmed)
            } catch {
                Self.logger.error("更新子任务标题失败：\(error.localizedDescription)")
            }
        }
        editingCheckItemId = nil
        editingCheckItemTitle = ""
    }
}

// MARK: - TaskChecklistCelebrationView

private struct TaskChecklistCelebrationView: View {
    let onComplete: () -> Void

    @State private var isActive = false
    @State private var ribbons: [Ribbon] = []

    private struct Ribbon: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
        let color: Color
        let width: CGFloat
        let height: CGFloat
        let delay: Double
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(ribbons) { ribbon in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ribbon.color)
                        .frame(width: ribbon.width, height: ribbon.height)
                        .rotationEffect(.degrees(isActive ? ribbon.rotation : 0))
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 8)
                        .offset(x: isActive ? ribbon.x : 0, y: isActive ? ribbon.y : 0)
                        .opacity(isActive ? 0 : 1)
                        .animation(.easeOut(duration: 1.05).delay(ribbon.delay), value: isActive)
                }

                Circle()
                    .stroke(Color.holoSuccess.opacity(isActive ? 0 : 0.28), lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(isActive ? 1.7 : 0.45)
                    .opacity(isActive ? 0 : 1)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 10)
                    .animation(.easeOut(duration: 0.5), value: isActive)
            }
        }
        .onAppear {
            generate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                isActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                onComplete()
            }
        }
    }

    private func generate() {
        guard ribbons.isEmpty else { return }
        let palette: [Color] = [
            .holoPrimary,
            .holoSuccess,
            Color(red: 1.0, green: 0.68, blue: 0.38),
            Color(red: 0.42, green: 0.68, blue: 1.0),
        ]

        ribbons = (0..<24).map { index in
            let side = index.isMultiple(of: 2) ? -1.0 : 1.0
            return Ribbon(
                x: CGFloat(side * Double.random(in: 24...118)),
                y: CGFloat.random(in: -74...(-18)),
                rotation: Double.random(in: -170...170),
                color: palette[index % palette.count],
                width: CGFloat.random(in: 5...8),
                height: CGFloat.random(in: 12...22),
                delay: Double.random(in: 0...0.08)
            )
        }
    }
}
