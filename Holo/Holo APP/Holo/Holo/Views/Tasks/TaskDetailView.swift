//
//  TaskDetailView.swift
//  Holo
//
//  任务详情视图
//  统一 Holo 设计风格：卡片布局、中文日期、Holo 颜色系统
//  支持直接编辑：点击各字段即可修改，无需切换编辑模式
//

import SwiftUI
import CoreData
import OSLog

struct TaskDetailView: View {
    @ObservedObject var repository: TodoRepository
    @State var task: TodoTask
    @Environment(\.dismiss) var dismiss

    @State private var showingChecklist = false
    @State private var showingDeleteAlert = false
    @State private var showingTagPicker = false
    @State private var showingDatePicker = false
    @State private var showAddTagSheet = false
    @State private var showReminderSheet = false
    @State private var newTagName = ""
    @State private var newTagColor = "#4A90D9"
    @State private var selectedDate = Date()
    @State private var selectedHasTime = false
    @State private var selectedReminders: Set<TaskReminder> = []
    @State private var isChecklistExpanded = false
    @State private var editedTitle = ""
    @State private var editedDescription = ""

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 任务信息卡片
                    taskInfoCard

                    // 状态与优先级卡片
                    statusCard

                    // 时间卡片
                    timeCard

                    // 检查清单卡片
                    checklistCard

                    // 标签卡片
                    tagCard

                    // 删除操作
                    deleteButton
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        saveTitleAndDescription()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .sheet(isPresented: $showingChecklist) {
                ChecklistView(repository: repository, task: task)
            }
            .sheet(isPresented: $showingTagPicker) {
                tagPickerSheet
            }
            .sheet(isPresented: $showingDatePicker) {
                datePickerSheet
            }
            .alert("删除任务", isPresented: $showingDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteTask()
                }
            } message: {
                Text("确定要删除此任务吗？任务将进入回收站，30 天后可恢复。")
            }
            .swipeBackToDismiss {
                saveTitleAndDescription()
                dismiss()
            }
        }
        .onAppear {
            // 初始化日期选择器状态
            selectedDate = task.dueDate ?? Date()
            selectedHasTime = !task.isAllDay
            selectedReminders = task.remindersSet
            // 初始化编辑状态
            editedTitle = task.title
            editedDescription = task.desc ?? ""
        }
        .onDisappear {
            saveTitleAndDescription()
        }
    }

    // MARK: - 任务信息卡片

    private var taskInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 完成状态切换 + 标题编辑
            HStack(spacing: 12) {
                Button {
                    toggleCompletion()
                } label: {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(task.completed ? .holoSuccess : .holoTextSecondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("任务标题", text: $editedTitle)
                        .font(.holoHeading)
                        .foregroundColor(task.completed ? .holoTextSecondary : .holoTextPrimary)
                        .strikethrough(task.completed)
                        .submitLabel(.done)
                        .onSubmit {
                            saveTitleAndDescription()
                        }

                    // 重复任务提示
                    if let repeatRule = task.repeatRule, !task.completed {
                        HStack(spacing: 4) {
                            Image(systemName: "repeat")
                                .font(.system(size: 10, weight: .medium))
                            Text("重复任务")
                                .font(.holoTinyLabel)
                        }
                        .foregroundColor(.holoPrimary)
                    }
                }

                Spacer()
            }

            // 描述（可编辑）
            VStack(alignment: .leading, spacing: 6) {
                Text("描述")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)

                TextEditor(text: $editedDescription)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(minHeight: editedDescription.isEmpty ? 30 : 60)
                    .scrollContentBackground(.hidden)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 状态与优先级卡片

    private var statusCard: some View {
        VStack(spacing: 0) {
            // 状态选择
            HStack {
                Text("状态")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button {
                            updateStatus(status)
                        } label: {
                            HStack {
                                Text(status.displayTitle)
                                if task.taskStatus == status {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(task.taskStatus.color)
                            .frame(width: 8, height: 8)
                        Text(task.taskStatus.displayTitle)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding()

            Divider()
                .padding(.horizontal)

            // 优先级选择（点击直接调整）
            HStack {
                Text("优先级")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Menu {
                    ForEach([TaskPriority.urgent, .high, .medium, .low], id: \.self) { p in
                        Button {
                            updatePriority(p)
                        } label: {
                            HStack {
                                Image(systemName: p.iconName)
                                    .foregroundColor(p.color)
                                Text(p.displayTitle)
                                if task.taskPriority == p {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: task.taskPriority.iconName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(task.taskPriority.color)
                        Text(task.taskPriority.displayTitle)
                            .font(.holoBody)
                            .foregroundColor(task.taskPriority.color)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding()
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 时间卡片

    private var timeCard: some View {
        VStack(spacing: 0) {
            // 截止时间（点击直接调整）
            Button {
                selectedDate = task.dueDate ?? Date()
                selectedHasTime = !task.isAllDay
                selectedReminders = task.remindersSet
                showingDatePicker = true
            } label: {
                HStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("截止时间")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text(formattedDueDate)
                        .font(.holoBody)
                        .foregroundColor(task.dueDate != nil ? .holoTextPrimary : .holoTextSecondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding()
                .background(Color.holoCardBackground)
            }
            .buttonStyle(PlainButtonStyle())

            if task.dueDate != nil {
                // 提醒显示
                if task.hasReminders {
                    Divider()
                        .padding(.horizontal)

                    HStack {
                        Image(systemName: "bell")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)

                        Text("提醒")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        Text(formattedReminders)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding()
                }

                // 重复显示
                if let repeatRule = task.repeatRule {
                    Divider()
                        .padding(.horizontal)

                    HStack {
                        Image(systemName: "repeat")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)

                        Text("重复")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        Text(repeatRule.displayDescription)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding()
                }
            }
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 检查清单卡片

    private var checklistCard: some View {
        Button {
            showingChecklist = true
        } label: {
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("检查清单")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(task.checkItemProgress)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding()
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 标签卡片

    private var tagCard: some View {
        Button {
            showingTagPicker = true
        } label: {
            HStack {
                Image(systemName: "tag")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("标签")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                if let tags = task.tags?.allObjects as? [TodoTag], !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.id) { tag in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(hex: tag.color))
                                    .frame(width: 8, height: 8)
                                Text(tag.name)
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextPrimary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(hex: tag.color).opacity(0.1))
                            .clipShape(Capsule())
                        }
                    }
                } else {
                    Text("点击设置")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPlaceholder)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding()
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 删除按钮

    private var deleteButton: some View {
        Button {
            showingDeleteAlert = true
        } label: {
            HStack {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoError)

                Text("删除任务")
                    .font(.holoBody)
                    .foregroundColor(.holoError)

                Spacer()
            }
            .padding()
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.lg)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 格式化方法

    /// 格式化截止日期（中文格式）
    private var formattedDueDate: String {
        guard let dueDate = task.dueDate else {
            return "未设置"
        }

        let calendar = Calendar.current

        if task.isAllDay {
            if calendar.isDateInToday(dueDate) { return "今天" }
            if calendar.isDateInTomorrow(dueDate) { return "明天" }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 E"
            return formatter.string(from: dueDate)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")

            if calendar.isDateInToday(dueDate) {
                formatter.dateFormat = "HH:mm"
                return "今天 " + formatter.string(from: dueDate)
            }

            formatter.dateFormat = "M月d日 HH:mm"
            return formatter.string(from: dueDate)
        }
    }

    /// 格式化提醒列表
    private var formattedReminders: String {
        let reminders = task.remindersArray
        if reminders.isEmpty { return "" }
        return reminders.map { $0.displayTitle }.joined(separator: "、")
    }

    // MARK: - 操作方法

    private func updateStatus(_ status: TaskStatus) {
        do {
            try repository.updateTask(task, status: status)
        } catch {
            Self.logger.error("更新状态失败: \(error.localizedDescription)")
        }
    }

    private func saveTitleAndDescription() {
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else {
            editedTitle = task.title
            return
        }
        let trimmedDesc = editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDesc = task.desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedTitle != task.title || trimmedDesc != originalDesc else { return }
        do {
            try repository.updateTask(
                task,
                title: trimmedTitle,
                description: trimmedDesc.isEmpty ? nil : trimmedDesc
            )
        } catch {
            Self.logger.error("更新标题/描述失败: \(error.localizedDescription)")
        }
    }

    private func toggleCompletion() {
        do {
            if task.repeatRule != nil && !task.completed {
                // 重复任务完成时，生成下一个实例
                let generated = try repository.completeRepeatingTask(task)
                if generated {
                    // 刷新本地 task 状态
                    task = repository.findTask(by: task.id) ?? task
                }
            } else {
                // 普通任务直接切换完成状态
                let isCompleted = try repository.toggleTaskCompletion(task)
                // 更新本地状态
                task.completed = isCompleted
                task.completedAt = isCompleted ? Date() : nil
            }
        } catch {
            Self.logger.error("切换完成状态失败: \(error.localizedDescription)")
        }
    }

    private func updatePriority(_ priority: TaskPriority) {
        do {
            try repository.updateTask(task, priority: priority)
        } catch {
            Self.logger.error("更新优先级失败: \(error.localizedDescription)")
        }
    }

    private func deleteTask() {
        do {
            try repository.deleteTask(task)
            dismiss()
        } catch {
            Self.logger.error("删除任务失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 日期选择器 Sheet

    private var datePickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 是否设置截止日期
                        HStack {
                            Text("截止日期")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { task.dueDate != nil },
                                set: { newValue in
                                    if newValue {
                                        saveDueDate(selectedDate, isAllDay: !selectedHasTime, reminders: selectedReminders)
                                    } else {
                                        saveDueDate(nil, isAllDay: true, reminders: [])
                                    }
                                }
                            ))
                            .labelsHidden()
                            .tint(.holoPrimary)
                        }

                        if task.dueDate != nil {
                            Divider()
                                .padding(.vertical, HoloSpacing.xs)

                            // 日期滚轮选择器
                            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                                .datePickerStyle(.wheel)
                                .environment(\.locale, Locale(identifier: "zh_CN"))
                                .labelsHidden()

                            Divider()
                                .padding(.vertical, HoloSpacing.xs)

                            // 时间切换行
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "clock")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)

                                Text("时间")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                if selectedHasTime {
                                    Text(formattedSelectedTime)
                                        .font(.holoBody)
                                        .foregroundColor(.holoPrimary)
                                } else {
                                    Text("全天")
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPlaceholder)
                                }

                                Toggle("", isOn: $selectedHasTime)
                                    .labelsHidden()
                                    .tint(.holoPrimary)
                            }

                            if selectedHasTime {
                                Divider()
                                    .padding(.vertical, HoloSpacing.xs)

                                // 时间滚轮选择器
                                DatePicker("", selection: $selectedDate, displayedComponents: .hourAndMinute)
                                    .datePickerStyle(.wheel)
                                    .environment(\.locale, Locale(identifier: "zh_CN"))
                                    .labelsHidden()
                            }

                            Divider()
                                .padding(.vertical, HoloSpacing.xs)

                            // 提醒行
                            Button {
                                showReminderSheet = true
                            } label: {
                                HStack(spacing: HoloSpacing.sm) {
                                    Image(systemName: "bell")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.holoTextSecondary)

                                    Text("提醒")
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPrimary)

                                    Spacer()

                                    if selectedReminders.isEmpty {
                                        Text("未设置")
                                            .font(.holoBody)
                                            .foregroundColor(.holoTextPlaceholder)
                                    } else {
                                        Text(reminderSummaryText)
                                            .font(.holoCaption)
                                            .foregroundColor(.holoTextSecondary)
                                            .multilineTextAlignment(.trailing)
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.holoTextSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.holoCardBackground)
                    .cornerRadius(HoloRadius.sm)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("截止时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        showingDatePicker = false
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        if task.dueDate != nil {
                            saveDueDate(selectedDate, isAllDay: !selectedHasTime, reminders: selectedReminders)
                        }
                        showingDatePicker = false
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showReminderSheet) {
                reminderPickerSheet
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// 格式化的时间显示
    private var formattedSelectedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: selectedDate)
    }

    /// 提醒摘要文本
    private var reminderSummaryText: String {
        selectedReminders.sorted { $0.offsetMinutes > $1.offsetMinutes }
            .map(\.displayTitle)
            .joined(separator: "、")
    }

    // MARK: - 提醒选择弹窗

    private var reminderPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    ReminderPicker(
                        selectedReminders: $selectedReminders,
                        isEnabled: true
                    )
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("选择提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        showReminderSheet = false
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    private func saveDueDate(_ date: Date?, isAllDay: Bool, reminders: Set<TaskReminder>) {
        do {
            try repository.updateTask(task, dueDate: date, isAllDay: isAllDay, reminders: reminders)
        } catch {
            Self.logger.error("更新截止日期失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 标签选择器 Sheet

    private var tagPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.md) {
                        // 新增标签按钮
                        Button {
                            showAddTagSheet = true
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoPrimary)

                                Text("新增标签")
                                    .font(.holoBody)
                                    .foregroundColor(.holoPrimary)

                                Spacer()
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(PlainButtonStyle())

                        Divider()
                            .padding(.vertical, HoloSpacing.sm)

                        if repository.tags.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "tag")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无标签")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)

                                Text("点击上方\"新增标签\"创建")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary.opacity(0.7))
                            }
                            .padding(.top, HoloSpacing.xl)
                        }

                        ForEach(repository.tags, id: \.id) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                HStack(spacing: HoloSpacing.sm) {
                                    Circle()
                                        .fill(Color(hex: tag.color))
                                        .frame(width: 12, height: 12)

                                    Text(tag.name)
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPrimary)

                                    Spacer()

                                    if isTagSelected(tag) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.holoPrimary)
                                    }
                                }
                                .padding(.horizontal, HoloSpacing.lg)
                                .padding(.vertical, HoloSpacing.md)
                                .background(isTagSelected(tag) ? Color(hex: tag.color).opacity(0.1) : Color.holoCardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("选择标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        showingTagPicker = false
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(isPresented: $showAddTagSheet) {
                addTagSheet
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 新增标签 Sheet

    private var addTagSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: HoloSpacing.lg) {
                    // 标签名称
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标签名称")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        TextField("输入标签名称", text: $newTagName)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.holoCardBackground)
                            .cornerRadius(HoloRadius.sm)
                    }

                    // 颜色选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标签颜色")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: 8) {
                            ForEach(["#4A90D9", "#E74C3C", "#2ECC71", "#F39C12", "#9B59B6", "#1ABC9C"], id: \.self) { color in
                                Button {
                                    newTagColor = color
                                } label: {
                                    Circle()
                                        .fill(Color(hex: color))
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: newTagColor == color ? 3 : 0)
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            }
            .navigationTitle("新增标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        newTagName = ""
                        newTagColor = "#4A90D9"
                        showAddTagSheet = false
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("创建") {
                        createTag()
                    }
                    .foregroundColor(newTagName.trimmingCharacters(in: .whitespaces).isEmpty ? .holoTextSecondary : .holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func createTag() {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        do {
            let tag = try repository.createTag(name: trimmedName, color: newTagColor)
            // 自动选中新创建的标签
            var currentTags = (task.tags?.allObjects as? [TodoTag]) ?? []
            currentTags.append(tag)
            try repository.updateTask(task, tags: currentTags)

            newTagName = ""
            newTagColor = "#4A90D9"
            showAddTagSheet = false
        } catch {
            Self.logger.error("创建标签失败: \(error.localizedDescription)")
        }
    }

    private func isTagSelected(_ tag: TodoTag) -> Bool {
        guard let tags = task.tags?.allObjects as? [TodoTag] else { return false }
        return tags.contains(where: { $0.id == tag.id })
    }

    private func toggleTag(_ tag: TodoTag) {
        var currentTags = (task.tags?.allObjects as? [TodoTag]) ?? []

        if isTagSelected(tag) {
            currentTags.removeAll { $0.id == tag.id }
        } else {
            currentTags.append(tag)
        }

        do {
            try repository.updateTask(task, tags: currentTags)
        } catch {
            Self.logger.error("更新标签失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - TaskStatus 扩展（颜色）

extension TaskStatus {
    /// 状态对应的颜色
    var color: Color {
        switch self {
        case .todo: return .holoTextSecondary
        case .inProgress: return .holoPrimary
        case .completed: return .holoSuccess
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        TaskDetailView(
            repository: TodoRepository.shared,
            task: createSampleTask()
        )
    }
}

private func createSampleTask() -> TodoTask {
    let context = CoreDataStack.shared.viewContext
    let task = TodoTask(context: context)
    task.id = UUID()
    task.title = "示例任务"
    task.desc = "这是一个示例任务的描述内容"
    task.priority = 2
    task.status = "inProgress"
    task.createdAt = Date()
    task.updatedAt = Date()
    task.dueDate = Calendar.current.date(byAdding: .day, value: 2, to: Date())
    return task
}
