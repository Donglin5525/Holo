//
//  MacTaskDetailView.swift
//  HoloMac
//
//  任务右栏：就地编辑 inspector。iOS 的 sheet 套 sheet 在这里变成一栏看全、
//  点了就改——文字字段失焦保存，选择字段即选即存，全部走 TodoRepository
//  的 updateTask 意图枚举（set/clear 表达 nil 语义），无保存按钮。
//
//  IME 红线：标题/描述用稳定 TextField/TextEditor，选中任务切换时整体重建视图
//  （id 驱动），不做任何「外部状态变化回写正在编辑的文本」的路径。
//

import SwiftUI

struct MacTaskDetailView: View {

    /// 选中任务（nil = 引导位）
    var taskId: UUID?
    var onToggleCompletion: (TodoTask, (checkItemID: UUID, wasChecked: Bool)?) -> Void
    var onDelete: (TodoTask) -> Void
    /// 写操作后的刷新回调
    var onChanged: () -> Void

    private let repository = TodoRepository.shared

    var body: some View {
        Group {
            if let taskId, let task = repository.findTask(by: taskId) {
                MacTaskDetailContent(
                    task: task,
                    repository: repository,
                    onToggleCompletion: onToggleCompletion,
                    onDelete: onDelete,
                    onChanged: onChanged)
            } else {
                placeholderView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoToolBackground)
    }

    private var placeholderView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "checklist")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            Text(String(localized: "选择一条任务"))
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolTextSecondary)
            Text(String(localized: "在中间列表点按任务，在这里查看与编辑"))
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary.opacity(0.6))
        }
    }
}

// MARK: - 详情内容（选中态）

private struct MacTaskDetailContent: View {

    let task: TodoTask
    @ObservedObject var repository: TodoRepository
    var onToggleCompletion: (TodoTask, (checkItemID: UUID, wasChecked: Bool)?) -> Void
    var onDelete: (TodoTask) -> Void
    var onChanged: () -> Void

    // 文本编辑的本地状态（失焦才落库；IME 安全——外部刷新不触碰这两个字段）
    @State private var titleText: String = ""
    @State private var descText: String = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var descFocused: Bool

    /// 检查清单新增项输入
    @State private var newCheckItemTitle = ""

    @State private var showDeleteConfirm = false

    private var sortedCheckItems: [CheckItem] {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        return items.sorted { $0.order < $1.order }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                headerRow

                titleField
                descEditor

                checkListSection

                propertiesCard

                metaFooter
            }
            .padding(.horizontal, HoloSpacing.xl)
            .padding(.vertical, HoloSpacing.lg)
        }
        .onAppear {
            titleText = task.title
            descText = task.desc ?? ""
        }
        // 选中变化时同步本地编辑态（taskId 变化驱动的新内容实例，非编辑中回写）。
        // 切换前先提交在途草稿（2026-10-31 审计 M4）：macOS 不保证点击另一任务
        // 先触发编辑框失焦——直接重置会把未保存文字静默丢掉（iOS 首轮 B2 同病）。
        // 草稿属于旧任务，必须按旧 ID 重读旧对象比对提交；此刻 task 已是新任务。
        .onChange(of: task.id) { oldID, newID in
            if oldID != newID { commitDraft(to: oldID) }
            titleText = task.title
            descText = task.desc ?? ""
        }
        .confirmationDialog(
            String(localized: "删除这条任务？"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除"), role: .destructive) {
                onDelete(task)
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "删除后将进入回收站并保留 30 天，可在 iPhone 端的「最近删除」中恢复。"))
        }
    }

    // MARK: - 头部（完成圈 + 优先级胶囊 + ⋯ 菜单）

    private var headerRow: some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                onToggleCompletion(task, nil)
            } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28))
                    .foregroundColor(task.completed ? .holoSuccess : .holoToolTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.completed ? String(localized: "标记为未完成") : String(localized: "标记为完成"))
            .accessibilityIdentifier("mac.task.detail.toggleCompletion")

            if task.taskPriority == .urgent || task.taskPriority == .high {
                Text(task.taskPriority.displayTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(task.taskPriority == .urgent ? Color.holoError : Color.holoPrimaryDark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            (task.taskPriority == .urgent ? Color.holoError : Color.holoPrimary).opacity(0.1)))
            }

            Spacer()

            Menu {
                Button(String(localized: "归档")) {
                    try? repository.archiveTask(task)
                    onChanged()
                }
                Divider()
                Button(String(localized: "删除任务"), role: .destructive) {
                    showDeleteConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("mac.task.detail.moreMenu")
        }
    }

    // MARK: - 标题/描述（失焦保存）

    private var titleField: some View {
        TextField(String(localized: "标题"), text: $titleText, axis: .vertical)
            .font(.system(size: 17, weight: .semibold))
            .textFieldStyle(.plain)
            .foregroundColor(.holoToolText)
            .lineLimit(1...2)
            .fixedSize(horizontal: false, vertical: true)
            .focused($titleFocused)
            .onSubmit { saveTextsIfChanged() }
            .onChange(of: titleFocused) { _, focused in
                if !focused { saveTextsIfChanged() }
            }
    }

    private var descEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $descText)
                .font(.system(size: 15))
                .foregroundColor(.holoToolText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
                .focused($descFocused)
                .onChange(of: descFocused) { _, focused in
                    if !focused { saveTextsIfChanged() }
                }
                .overlay(alignment: .topLeading) {
                    if descText.isEmpty && !descFocused {
                        Text(String(localized: "描述（可选）"))
                            .font(.system(size: 15))
                            .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(Color.holoToolInset))
        }
    }

    private func saveTextsIfChanged() {
        commitDraftTexts(title: titleText, desc: descText, to: task, guardTitleEmpty: true)
    }

    /// 把在途草稿提交给指定任务（切换选中时草稿属于旧任务，见 onChange(of: task.id)）
    private func commitDraft(to taskID: UUID) {
        guard let owner = repository.findTask(by: taskID) else { return }
        commitDraftTexts(title: titleText, desc: descText, to: owner, guardTitleEmpty: false)
    }

    private func commitDraftTexts(title: String, desc: String, to target: TodoTask, guardTitleEmpty: Bool) {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDesc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newTitle != target.title || newDesc != (target.desc ?? "") else { return }
        guard !newTitle.isEmpty else {
            // 标题不允许清空：回填原标题（仅当前任务可回填；旧任务的空草稿直接放弃）
            if guardTitleEmpty { titleText = target.title }
            return
        }
        try? repository.updateTask(
            target,
            title: newTitle,
            description: newDesc.isEmpty ? nil : newDesc)
        onChanged()
    }

    // MARK: - 检查清单（勾选即存、回车添加、尾部删除）

    private var checkListSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(String(localized: "检查清单"))
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            ForEach(sortedCheckItems, id: \.id) { item in
                HStack(spacing: 8) {
                    Button {
                        try? repository.toggleCheckItem(item)
                        // 与 iOS 同一条双向联动（TaskDetailChecklistSection）：
                        // 子任务全勾 → 自动完成父任务；已完成任务出现未勾子任务 → 自动回未完成，
                        // 避免「父完成 + 子未完成」矛盾态（2026-10-31 审计 M1）
                        let allChecked = (item.task?.checkItems?.allObjects as? [CheckItem] ?? [])
                            .allSatisfy(\.isChecked)
                        if let parent = item.task, allChecked != parent.completed {
                            onChanged()
                            onToggleCompletion(parent, allChecked ? (checkItemID: item.id, wasChecked: !item.isChecked) : nil)
                        } else {
                            onChanged()
                        }
                    } label: {
                        Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16))
                            .foregroundColor(item.isChecked ? .holoSuccess : .holoToolTextSecondary)
                    }
                    .buttonStyle(.plain)

                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundColor(item.isChecked ? .holoToolTextSecondary : .holoToolText)
                        .strikethrough(item.isChecked)

                    Spacer()

                    Button {
                        try? repository.deleteCheckItem(item)
                        onChanged()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "删除这一项"))
                }
                .frame(height: 28)
            }

            // 常驻添加行：回车即落库
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                TextField(String(localized: "添加一项"), text: $newCheckItemTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addCheckItem)
            }
            .frame(height: 28)
        }
    }

    private func addCheckItem() {
        let title = newCheckItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let order = (sortedCheckItems.map(\.order).max() ?? -1) + 1
        do {
            _ = try repository.addCheckItem(title: title, to: task, order: order)
        } catch {
            // 失败保留输入文本不清空，用户可直接回车重试（2026-10-31 审计 M10）
            return
        }
        newCheckItemTitle = ""
        onChanged()
    }

    // MARK: - 属性卡

    private var propertiesCard: some View {
        VStack(spacing: 0) {
            listRow
            Divider().padding(.leading, HoloSpacing.md)
            dueDateRow
            Divider().padding(.leading, HoloSpacing.md)
            priorityRow
            Divider().padding(.leading, HoloSpacing.md)
            importanceRow
            Divider().padding(.leading, HoloSpacing.md)
            urgencyRow
            if let repeatRule = task.repeatRule {
                Divider().padding(.leading, HoloSpacing.md)
                readOnlyRow(icon: "arrow.triangle.2.circlepath", label: String(localized: "重复"), value: repeatRule.displayDescription)
            }
            if !task.remindersArray.isEmpty {
                Divider().padding(.leading, HoloSpacing.md)
                readOnlyRow(icon: "bell", label: String(localized: "提醒"),
                            value: task.remindersArray.map(\.displayTitle).joined(separator: "、"))
            }
        }
        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoToolInset))
    }

    /// 清单选择（收件箱 + 全部清单）
    private var listRow: some View {
        propertyRowLabel(
            icon: "tray.full",
            label: String(localized: "清单"),
            value: Menu {
                Button(String(localized: "收件箱")) {
                    try? repository.updateTask(task, list: .clear)
                    onChanged()
                }
                ForEach(repository.allActiveLists(), id: \.id) { list in
                    Button(list.name ?? "") {
                        try? repository.updateTask(task, list: .set(list))
                        onChanged()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if let list = task.list {
                        Circle()
                            .fill(Color(hex: list.color ?? "#007AFF"))
                            .frame(width: 8, height: 8)
                    }
                    Text(task.list?.name ?? String(localized: "收件箱"))
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize())
    }

    /// 截止时间（两行式：标签行 + 控件行右对齐；单行在 380pt 右栏会挤压标签）
    private var dueDateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 16)
                Text(String(localized: "截止时间"))
                    .font(.system(size: 15))
                    .foregroundColor(.holoToolTextSecondary)
            }
            HStack(spacing: 10) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { task.dueDate ?? Calendar.current.startOfDay(for: Date()) },
                        set: { newDate in
                            try? repository.updateTask(task, dueDate: .set(newDate))
                            onChanged()
                        }),
                    displayedComponents: task.isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()

                Toggle(String(localized: "全天"), isOn: Binding(
                    get: { task.isAllDay },
                    set: { allDay in
                        try? repository.updateTask(task, isAllDay: allDay)
                        onChanged()
                    }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                if task.dueDate != nil {
                    Button {
                        try? repository.updateTask(task, dueDate: .clear)
                        onChanged()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "清除截止时间"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 6)
    }

    private var priorityRow: some View {
        propertyRowLabel(
            icon: "flag",
            label: String(localized: "优先级"),
            value: Menu {
                ForEach(TaskPriority.allCases, id: \.self) { level in
                    Button(level.displayTitle) {
                        try? repository.updateTask(task, priority: level)
                        onChanged()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(task.taskPriority.displayTitle)
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize())
    }

    private var importanceRow: some View {
        propertyRowLabel(
            icon: "star",
            label: String(localized: "重要度"),
            value: Menu {
                ForEach(TaskImportance.allCases, id: \.self) { level in
                    Button(level.displayTitle) {
                        try? repository.updateTask(task, importance: level)
                        onChanged()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(task.importance.displayTitle)
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize())
    }

    private var urgencyRow: some View {
        propertyRowLabel(
            icon: "bolt",
            label: String(localized: "紧急度"),
            value: Menu {
                ForEach(TaskUrgencyMode.allCases, id: \.self) { mode in
                    Button(mode.displayTitle) {
                        try? repository.updateTask(task, urgencyMode: mode)
                        onChanged()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(task.urgencyMode.displayTitle)
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize())
    }

    private func propertyRowLabel(icon: String, label: String, value: some View) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(.holoToolTextSecondary)
            Spacer()
            value
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(height: 36)
    }

    private func readOnlyRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(.holoToolTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.holoToolText)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 36)
    }

    // MARK: - 元信息

    private var metaFooter: some View {
        let text = String(localized: "创建于 ") + formatDate(task.createdAt)
            + (task.postponedCount > 0 ? String(localized: " · 已延期 \(task.postponedCount) 次") : "")
        return Text(text)
            .font(.holoTinyLabel)
            .foregroundColor(.holoToolTextSecondary.opacity(0.6))
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("M月d日")
        return f.string(from: date)
    }
}
