//
//  AddTaskSheet.swift
//  Holo
//
//  添加/编辑任务表单
//  统一全局风格：圆角卡片、中文日期、自定义选择器
//

import SwiftUI
import OSLog

struct AddTaskSheet: View {
    @ObservedObject var repository: TodoRepository
    let existingTask: TodoTask?

    @Environment(\.dismiss) var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var priority: TaskPriority = .medium
    @State private var dueDate = Date()
    @State private var isAllDay = true
    @State private var selectedTags: Set<UUID> = []
    @State private var selectedListId: UUID? = nil

    @State private var showListPicker = false
    @State private var showDatePicker = false
    @State private var showTagPicker = false
    @State private var isSaving = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "AddTaskSheet")

    init(repository: TodoRepository, list: TodoList? = nil, task: TodoTask? = nil) {
        self.repository = repository
        self.existingTask = task

        if let task = task {
            _title = State(initialValue: task.title)
            _description = State(initialValue: task.desc ?? "")
            _priority = State(initialValue: task.taskPriority)
            _dueDate = State(initialValue: task.dueDate ?? Date())
            _isAllDay = State(initialValue: task.isAllDay)
            _selectedTags = State(initialValue: Set(task.tags?.allObjects.compactMap { ($0 as? TodoTag)?.id } ?? []))
            _selectedListId = State(initialValue: task.list?.id)
        } else {
            _selectedListId = State(initialValue: list?.id)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 拖动指示条
                    dragIndicator

                    // 顶部区域
                    headerSection

                    // 滚动区域
                    ScrollView {
                        VStack(spacing: HoloSpacing.lg) {
                            // 任务标题
                            titleSection

                            // 所属清单
                            listSection

                            // 优先级
                            prioritySection

                            // 截止日期
                            dueDateSection

                            // 标签
                            tagSection

                            // 描述
                            descriptionSection
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)
                        .padding(.bottom, 100)
                    }
                }
            }
            .navigationTitle(existingTask == nil ? "新建任务" : "编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveTask()
                    }
                    .foregroundColor(canSave ? .holoPrimary : .holoTextSecondary)
                    .fontWeight(.semibold)
                    .disabled(!canSave || isSaving)
                }
            }
        }
        .sheet(isPresented: $showListPicker) {
            listPickerSheet
        }
        .sheet(isPresented: $showTagPicker) {
            tagPickerSheet
        }
        .swipeBackToDismiss { dismiss() }
    }

    // MARK: - 是否可保存

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 拖动指示条

    private var dragIndicator: some View {
        Capsule()
            .fill(Color.holoTextSecondary.opacity(0.3))
            .frame(width: 36, height: 5)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    // MARK: - 顶部区域

    private var headerSection: some View {
        HStack {
            Spacer()
            Text(existingTask == nil ? "新建任务" : "编辑任务")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
    }

    // MARK: - 任务标题

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("任务标题")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            TextField("输入任务名称", text: $title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
        }
    }

    // MARK: - 所属清单

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("所属清单")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Button {
                showListPicker = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text(selectedListName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - 优先级

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("优先级")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                ForEach([TaskPriority.urgent, .high, .medium, .low], id: \.self) { p in
                    Button {
                        priority = p
                    } label: {
                        Text(p.displayTitle)
                            .font(.holoCaption)
                            .foregroundColor(priority == p ? .white : p.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(priority == p ? p.color : p.color.opacity(0.15))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    // MARK: - 截止日期

    private var dueDateSection: some View {
        VStack(spacing: 0) {
            // 日期显示行
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showDatePicker.toggle()
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text(formattedDueDate)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $isAllDay)
                        .labelsHidden()
                        .tint(.holoPrimary)

                    Text(isAllDay ? "全天" : "定时")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Image(systemName: showDatePicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
            }
            .buttonStyle(PlainButtonStyle())

            // 展开的日期选择器
            if showDatePicker {
                DatePicker(
                    "",
                    selection: $dueDate,
                    displayedComponents: isAllDay ? .date : [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, HoloSpacing.sm)
                .padding(.top, HoloSpacing.sm)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 判断是否是明天
    private var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(dueDate)
    }

    /// 格式化的日期显示
    private var formattedDueDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if isAllDay {
            formatter.dateFormat = "M月d日 E"
            let text = formatter.string(from: dueDate)
            if Calendar.current.isDateInToday(dueDate) { return "今天" }
            if isTomorrow { return "明天" }
            return text
        } else {
            if Calendar.current.isDateInToday(dueDate) {
                formatter.dateFormat = "HH:mm"
                return "今天 " + formatter.string(from: dueDate)
            }
            formatter.dateFormat = "M月d日 HH:mm"
            return formatter.string(from: dueDate)
        }
    }

    // MARK: - 标签

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Button {
                showTagPicker = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "tag")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    if selectedTags.isEmpty {
                        Text("选择标签")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPlaceholder)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(selectedTags.prefix(3)), id: \.self) { tagId in
                                if let tag = repository.tags.first(where: { $0.id == tagId }) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color(hex: tag.color))
                                            .frame(width: 8, height: 8)
                                        Text(tag.name)
                                            .font(.holoCaption)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: tag.color).opacity(0.1))
                                    .clipShape(Capsule())
                                }
                            }
                            if selectedTags.count > 3 {
                                Text("+\(selectedTags.count - 3)")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - 描述

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("描述（可选）")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            TextEditor(text: $description)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(minHeight: 80)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - 清单选择器 Sheet

    private var listPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.md) {
                        // 收件箱
                        Button {
                            selectedListId = nil
                            dismiss()
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "tray")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)

                                Text("收件箱（未归类）")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                if selectedListId == nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.holoPrimary)
                                }
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(PlainButtonStyle())

                        // 文件夹和清单
                        ForEach(repository.folders, id: \.id) { folder in
                            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                                Text(folder.name)
                                    .font(.holoLabel)
                                    .foregroundColor(.holoTextSecondary)
                                    .padding(.horizontal, HoloSpacing.xs)

                                ForEach(folder.listsArray, id: \.id) { list in
                                    Button {
                                        selectedListId = list.id
                                        dismiss()
                                    } label: {
                                        HStack(spacing: HoloSpacing.sm) {
                                            Image(systemName: "list.bullet")
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundColor(.holoTextSecondary)

                                            Text(list.name)
                                                .font(.holoBody)
                                                .foregroundColor(.holoTextPrimary)

                                            Spacer()

                                            if selectedListId == list.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundColor(.holoPrimary)
                                            }
                                        }
                                        .padding(.horizontal, HoloSpacing.lg)
                                        .padding(.vertical, HoloSpacing.md)
                                        .background(Color.holoCardBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }

                        if repository.folders.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)

                                Text("请先创建文件夹和清单")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary.opacity(0.7))
                            }
                            .padding(.top, HoloSpacing.xl)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("选择清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 标签选择器 Sheet

    private var tagPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.md) {
                        ForEach(repository.tags, id: \.id) { tag in
                            Button {
                                if selectedTags.contains(tag.id) {
                                    selectedTags.remove(tag.id)
                                } else {
                                    selectedTags.insert(tag.id)
                                }
                            } label: {
                                HStack(spacing: HoloSpacing.sm) {
                                    Circle()
                                        .fill(Color(hex: tag.color))
                                        .frame(width: 12, height: 12)

                                    Text(tag.name)
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPrimary)

                                    Spacer()

                                    if selectedTags.contains(tag.id) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.holoPrimary)
                                    }
                                }
                                .padding(.horizontal, HoloSpacing.lg)
                                .padding(.vertical, HoloSpacing.md)
                                .background(selectedTags.contains(tag.id) ? Color(hex: tag.color).opacity(0.1) : Color.holoCardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if repository.tags.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "tag")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无标签")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)
                            }
                            .padding(.top, HoloSpacing.xl)
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
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 清单查找

    private func findList(byId listId: UUID) -> TodoList? {
        for folder in repository.folders {
            if let list = folder.listsArray.first(where: { $0.id == listId }) {
                return list
            }
        }
        return nil
    }

    private var selectedListName: String {
        guard let listId = selectedListId else {
            return "收件箱（未归类）"
        }
        return findList(byId: listId)?.name ?? "收件箱（未归类）"
    }

    private var selectedList: TodoList? {
        guard let listId = selectedListId else { return nil }
        return findList(byId: listId)
    }

    // MARK: - 保存

    private func saveTask() {
        guard canSave else { return }
        isSaving = true

        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let selectedTagObjects = repository.tags.filter { selectedTags.contains($0.id) }

        Task { @MainActor in
            do {
                if let task = existingTask {
                    try repository.updateTask(
                        task,
                        title: trimmedTitle,
                        description: description,
                        priority: priority,
                        dueDate: dueDate,
                        isAllDay: isAllDay
                    )
                } else {
                    _ = try repository.createTask(
                        title: trimmedTitle,
                        list: selectedList,
                        priority: priority,
                        dueDate: dueDate,
                        isAllDay: isAllDay,
                        tags: selectedTagObjects
                    )
                }

                // 震动反馈
                let feedback = UINotificationFeedbackGenerator()
                feedback.notificationOccurred(.success)

                await MainActor.run {
                    dismiss()
                }
            } catch {
                Self.logger.error("保存任务失败: \(error.localizedDescription)")
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AddTaskSheet(repository: TodoRepository.shared, list: nil)
}
