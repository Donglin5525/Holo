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
    @State private var hasDueDate = false
    @State private var selectedReminders: Set<TaskReminder> = []
    @State private var selectedTags: Set<UUID> = []
    @State private var selectedListId: UUID? = nil

    @State private var showListPicker = false
    @State private var showDatePicker = false
    @State private var showTagPicker = false
    @State private var showAddTagSheet = false
    @State private var showAddListSheet = false
    @State private var showEditListSheet = false
    @State private var editingList: TodoList? = nil
    @State private var showDeleteConfirm = false
    @State private var itemToDelete: DeleteTarget? = nil
    @State private var isSaving = false
    @State private var newTagName = ""
    @State private var newTagColor = "#4A90D9"

    // 删除目标类型
    private enum DeleteTarget: Identifiable {
        case list(TodoList)
        case tag(TodoTag)
        var id: String {
            switch self {
            case .list(let l): return "list-\(l.id)"
            case .tag(let t): return "tag-\(t.id)"
            }
        }
    }

    // 编辑标签相关
    @State private var showEditTagSheet = false
    @State private var editingTag: TodoTag? = nil

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
            _hasDueDate = State(initialValue: task.dueDate != nil)
            _selectedReminders = State(initialValue: task.remindersSet)
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

                            // 提醒
                            reminderSection

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
            HStack(spacing: HoloSpacing.sm) {
                // 日历图标
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                // 日期文字（可点击展开/收起）
                Button {
                    if hasDueDate {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showDatePicker.toggle()
                        }
                    }
                } label: {
                    Text(hasDueDate ? formattedDueDate : "无截止日期")
                        .font(.holoBody)
                        .foregroundColor(hasDueDate ? .holoTextPrimary : .holoTextPlaceholder)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // 全天/定时胶囊切换（仅当已设置日期时显示）
                if hasDueDate {
                    allDayToggleCapsule

                    Image(systemName: showDatePicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.leading, 4)
                }

                // 日期开关
                Toggle("", isOn: $hasDueDate)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.sm)
            .onChange(of: hasDueDate) { _, newValue in
                if newValue {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showDatePicker = true
                    }
                } else {
                    showDatePicker = false
                    // 清除提醒
                    selectedReminders.removeAll()
                }
            }

            // 展开的日期选择器
            if showDatePicker && hasDueDate {
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

    /// 全天/定时胶囊切换
    private var allDayToggleCapsule: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAllDay = true
                }
            } label: {
                Text("全天")
                    .font(.holoCaption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isAllDay ? Color.holoPrimary : Color.clear)
                    .foregroundColor(isAllDay ? .white : .holoTextSecondary)
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAllDay = false
                }
            } label: {
                Text("定时")
                    .font(.holoCaption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(!isAllDay ? Color.holoPrimary : Color.clear)
                    .foregroundColor(!isAllDay ? .white : .holoTextSecondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
        .clipShape(Capsule())
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

    // MARK: - 提醒

    private var reminderSection: some View {
        ReminderPicker(
            selectedReminders: $selectedReminders,
            isEnabled: hasDueDate
        )
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
                        // 新建清单按钮
                        Button {
                            showAddListSheet = true
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoPrimary)

                                Text("新建清单")
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

                        // 收件箱
                        Button {
                            selectedListId = nil
                            showListPicker = false
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
                            .background(selectedListId == nil ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(PlainButtonStyle())

                        // 所有清单（扁平化显示）
                        ForEach(allLists, id: \.id) { list in
                            Button {
                                selectedListId = list.id
                                showListPicker = false
                            } label: {
                                HStack(spacing: HoloSpacing.sm) {
                                    Circle()
                                        .fill(Color(hex: list.color ?? "#007AFF"))
                                        .frame(width: 10, height: 10)

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
                                .background(selectedListId == list.id ? Color(hex: list.color ?? "#007AFF").opacity(0.1) : Color.holoCardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contextMenu {
                                Button {
                                    editingList = list
                                    showEditListSheet = true
                                } label: {
                                    Label("编辑清单", systemImage: "pencil")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    itemToDelete = .list(list)
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除清单", systemImage: "trash")
                                }
                            }
                        }

                        // 空状态
                        if allLists.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)

                                Text("点击上方\"新建清单\"创建")
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
                        showListPicker = false
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(isPresented: $showAddListSheet) {
                AddListSheet(repository: repository, folder: nil)
            }
            .sheet(isPresented: $showEditListSheet) {
                if let list = editingList {
                    EditListSheet(repository: repository, list: list, folders: repository.folders)
                }
            }
            .alert("确认删除", isPresented: $showDeleteConfirm, presenting: itemToDelete) { target in
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    deleteTarget(target)
                }
            } message: { target in
                switch target {
                case .list(let list):
                    Text("确定要删除清单「\(list.name)」吗？该清单下的所有任务都将被删除。")
                case .tag(let tag):
                    Text("确定要永久删除标签「\(tag.name)」吗？此操作不可撤销，但已关联的任务将保留。")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 所有清单（包括没有文件夹的）
    private var allLists: [TodoList] {
        var lists = repository.folders.flatMap { $0.listsArray }
        // 也获取没有文件夹的清单
        let unfiledLists = repository.unfiledLists
        lists.insert(contentsOf: unfiledLists, at: 0)
        return lists
    }

    // MARK: - 删除操作

    private func deleteTarget(_ target: DeleteTarget) {
        do {
            switch target {
            case .list(let list):
                // 如果当前选中的是该清单，清除选择
                if selectedListId == list.id {
                    selectedListId = nil
                }
                try repository.deleteList(list)
            case .tag(let tag):
                // 如果当前选中了该标签，移除选中
                selectedTags.remove(tag.id)
                try repository.permanentlyDeleteTag(tag)
            }
        } catch {
            Self.logger.error("删除失败: \(error.localizedDescription)")
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

                        ForEach(repository.tags, id: \.id) { tag in
                            // 标签项（支持长按菜单）
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
                            .contextMenu {
                                Button {
                                    editingTag = tag
                                    showEditTagSheet = true
                                } label: {
                                    Label("编辑标签", systemImage: "pencil")
                                }

                                Button {
                                    archiveTag(tag)
                                } label: {
                                    Label("归档标签", systemImage: "archivebox")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    itemToDelete = .tag(tag)
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除标签", systemImage: "trash")
                                }
                            }
                        }

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
                        showTagPicker = false
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(isPresented: $showAddTagSheet) {
                addTagSheet
            }
            .sheet(isPresented: $showEditTagSheet) {
                if let tag = editingTag {
                    EditTagSheet(repository: repository, tag: tag)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 归档标签

    private func archiveTag(_ tag: TodoTag) {
        do {
            // 归档 = 软删除，标签从列表中隐藏，但已关联的任务保留关联
            try repository.deleteTag(tag)
            // 如果当前选中了该标签，移除选中
            selectedTags.remove(tag.id)
        } catch {
            Self.logger.error("归档标签失败: \(error.localizedDescription)")
        }
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

    // MARK: - 创建标签

    private func createTag() {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        do {
            let tag = try repository.createTag(name: trimmedName, color: newTagColor)
            selectedTags.insert(tag.id)
            newTagName = ""
            newTagColor = "#4A90D9"
            showAddTagSheet = false
        } catch {
            Self.logger.error("创建标签失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 清单查找

    private func findList(byId listId: UUID) -> TodoList? {
        // 先搜索没有文件夹的清单
        if let list = repository.unfiledLists.first(where: { $0.id == listId }) {
            return list
        }
        // 再搜索文件夹中的清单
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

        // 只有设置了截止日期才传递提醒
        let remindersToSave = hasDueDate ? selectedReminders : nil

        Task { @MainActor in
            do {
                if let task = existingTask {
                    try repository.updateTask(
                        task,
                        title: trimmedTitle,
                        description: description,
                        priority: priority,
                        dueDate: hasDueDate ? dueDate : nil,
                        isAllDay: isAllDay,
                        tags: selectedTagObjects,
                        reminders: remindersToSave
                    )
                } else {
                    _ = try repository.createTask(
                        title: trimmedTitle,
                        list: selectedList,
                        priority: priority,
                        dueDate: hasDueDate ? dueDate : nil,
                        isAllDay: isAllDay,
                        tags: selectedTagObjects,
                        reminders: remindersToSave
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
