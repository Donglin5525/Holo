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
    @State private var hasDueDate = false
    @State private var hasTime = false
    @State private var selectedReminders: Set<TaskReminder> = []
    @State private var selectedTags: Set<UUID> = []
    @State private var selectedListId: UUID? = nil

    @State private var showListPicker = false
    @State private var showReminderSheet = false
    @State private var showRepeatSheet = false
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

    // 重复相关状态
    @State private var hasRepeat = false
    @State private var repeatType: RepeatType = .daily
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthDay: Int = 1
    @State private var monthWeekOrdinal: Int = 1
    @State private var monthWeekday: Weekday? = nil
    @State private var monthlyRepeatMode: MonthlyRepeatMode = .dayOfMonth
    @State private var endConditionType: EndConditionType = .never
    @State private var repeatEndDate: Date? = nil
    @State private var repeatEndCount: Int = 10

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

    // 未保存修改确认
    @State private var showDismissAlert: Bool = false

    // 检查清单相关
    @State private var checkItems: [CheckItem] = []
    @State private var pendingCheckItems: [String] = []
    @State private var newCheckItemTitle = ""
    @State private var showAdvancedProperties = false

    // 记忆上次选择的清单
    @AppStorage("lastSelectedListId") private var lastSelectedListId: String?

    private static let logger = Logger(subsystem: "com.holo.app", category: "AddTaskSheet")

    init(repository: TodoRepository, list: TodoList? = nil, task: TodoTask? = nil) {
        self.repository = repository
        self.existingTask = task

        if let task = task {
            _title = State(initialValue: task.title)
            _description = State(initialValue: task.desc ?? "")
            _priority = State(initialValue: task.taskPriority)
            _dueDate = State(initialValue: task.dueDate ?? Date())
            _hasDueDate = State(initialValue: task.dueDate != nil)
            _hasTime = State(initialValue: !task.isAllDay)
            _selectedReminders = State(initialValue: task.remindersSet)
            _selectedTags = State(initialValue: Set(task.tags?.allObjects.compactMap { ($0 as? TodoTag)?.id } ?? []))
            _selectedListId = State(initialValue: task.list?.id)

            // 加载重复规则
            if let rule = task.repeatRule {
                _hasRepeat = State(initialValue: true)
                _repeatType = State(initialValue: rule.repeatType)
                _selectedWeekdays = State(initialValue: Set(rule.weekdaysArray))
                _monthDay = State(initialValue: Int(rule.monthDay))
                _monthWeekOrdinal = State(initialValue: Int(rule.monthWeekOrdinal))
                _monthWeekday = State(initialValue: rule.monthWeekdayValue)
                _monthlyRepeatMode = State(initialValue: rule.monthWeekOrdinal > 0 ? .nthWeekday : .dayOfMonth)
                _endConditionType = State(initialValue: rule.endConditionType)
                _repeatEndDate = State(initialValue: rule.untilDate)
                _repeatEndCount = State(initialValue: Int(rule.untilCount))
            } else {
                _hasRepeat = State(initialValue: false)
            }
        } else {
            // 新建任务：优先用传入的 list，其次从记忆恢复
            let rememberedId = list?.id ?? (UserDefaults.standard.string(forKey: "lastSelectedListId").flatMap { UUID(uuidString: $0) })
            _selectedListId = State(initialValue: rememberedId)
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
                            // 任务内容
                            taskContentSection

                            // 检查清单
                            checklistSection

                            // 属性与清单
                            metadataSection

                            // 截止日期
                            dueDateSection
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)
                        .padding(.bottom, 100)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        if hasUnsavedChanges {
                            showDismissAlert = true
                        } else {
                            dismiss()
                        }
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
        .sheet(isPresented: $showReminderSheet) {
            reminderSheet
        }
        .sheet(isPresented: $showRepeatSheet) {
            repeatSheet
        }
        .swipeBackToDismiss {
            if hasUnsavedChanges {
                showDismissAlert = true
            } else {
                dismiss()
            }
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
        .onAppear {
            // 编辑模式：加载已有的检查清单
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }
            }
        }
    }

    // MARK: - 未保存修改检测

    /// 是否有未保存的修改
    private var hasUnsavedChanges: Bool {
        if let task = existingTask {
            // 编辑模式：比较与原始任务的差异
            return title != task.title
                || description != (task.desc ?? "")
                || priority != task.taskPriority
                || selectedListId != task.list?.id
                || selectedTags != Set(task.tags?.allObjects.compactMap { ($0 as? TodoTag)?.id } ?? [])
                || checkItems.count != (task.checkItems?.count ?? 0)
        } else {
            // 新增模式：检查是否输入了内容
            return !title.trimmingCharacters(in: .whitespaces).isEmpty
                || !description.isEmpty
                || hasDueDate
                || hasRepeat
                || !selectedTags.isEmpty
                || !pendingCheckItems.isEmpty
        }
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
    }

    // MARK: - 任务内容

    private var taskContentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            TextField("输入任务名称", text: $title)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            TextEditor(text: $description)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(minHeight: 46)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("添加描述、完成标准或需要注意的点")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPlaceholder)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - 属性与清单

    private var metadataSection: some View {
        VStack(spacing: 0) {
            advancedPropertiesSection

            Divider()
                .padding(.horizontal, 12)

            listRow
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private var dueDateSummaryText: String {
        guard hasDueDate else { return "无截止日期" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = hasTime ? "M月d日 HH:mm" : "M月d日"
        return formatter.string(from: dueDate)
    }

    private var reminderChipText: String {
        guard hasDueDate else { return "不提醒" }
        return selectedReminders.isEmpty ? "不提醒" : reminderSummaryText
    }

    // MARK: - 更多属性

    private var advancedPropertiesSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvancedProperties.toggle()
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("更多属性")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("优先级和标签默认收起")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .layoutPriority(1)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(priority.displayTitle)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .fontWeight(.semibold)

                        Text(tagSummaryText)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: 116, alignment: .trailing)

                    Image(systemName: showAdvancedProperties ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .buttonStyle(PlainButtonStyle())

            if showAdvancedProperties {
                Divider()
                    .padding(.horizontal, 12)

                VStack(spacing: HoloSpacing.md) {
                    prioritySection
                    tagSection
                }
                .padding(12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var tagSummaryText: String {
        selectedTags.isEmpty ? "无标签" : "\(selectedTags.count) 个标签"
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

    private var listRow: some View {
        Button {
            showListPicker = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("所属清单")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text("点击选择任务所在清单")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .layoutPriority(1)

                Spacer()

                Text(selectedListName)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 116, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 优先级

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("优先级")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                Spacer()
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

    /// 是否全天（由 hasTime 反向推导）
    private var isAllDay: Bool { !hasTime }

    private var dueDateSection: some View {
        VStack(spacing: 0) {
            // 标题行 + 开关
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("截止日期")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Toggle("", isOn: $hasDueDate)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }

            if hasDueDate {
                Divider()
                    .padding(.vertical, HoloSpacing.xs)

                // 日期滚轮选择器
                DatePicker("", selection: $dueDate, displayedComponents: .date)
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

                    if hasTime {
                        Text(formattedTime)
                            .font(.holoBody)
                            .foregroundColor(.holoPrimary)
                    } else {
                        Text("全天")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPlaceholder)
                    }

                    Toggle("", isOn: $hasTime)
                        .labelsHidden()
                        .tint(.holoPrimary)
                }

                if hasTime {
                    Divider()
                        .padding(.vertical, HoloSpacing.xs)

                    // 时间滚轮选择器
                    DatePicker("", selection: $dueDate, displayedComponents: .hourAndMinute)
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

                Divider()
                    .padding(.vertical, HoloSpacing.xs)

                // 重复行
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "repeat")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("重复")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    if hasRepeat {
                        Button {
                            showRepeatSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(repeatType.displayTitle)
                                    .font(.holoCaption)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.holoPrimary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Toggle("", isOn: $hasRepeat)
                        .labelsHidden()
                        .tint(.holoPrimary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    /// 格式化的时间显示
    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: dueDate)
    }

    /// 提醒摘要文本
    private var reminderSummaryText: String {
        selectedReminders.sorted { $0.offsetMinutes > $1.offsetMinutes }
            .map(\.displayTitle)
            .joined(separator: "、")
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

    // MARK: - 检查清单

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("检查清单（可选）")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                if existingTask != nil {
                    // 编辑模式：显示已有的检查项
                    ForEach(checkItems, id: \.id) { item in
                        HStack(spacing: HoloSpacing.sm) {
                            Button {
                                toggleCheckItem(item)
                            } label: {
                                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
                            }
                            .buttonStyle(PlainButtonStyle())

                            Text(item.title)
                                .font(.holoBody)
                                .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                                .strikethrough(item.isChecked, color: .holoTextSecondary)

                            Spacer()

                            Button {
                                deleteCheckItem(item)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.holoError.opacity(0.7))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        if item.id != checkItems.last?.id {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                } else {
                    // 新建模式：显示暂存的检查项
                    ForEach(pendingCheckItems.indices, id: \.self) { index in
                        HStack(spacing: HoloSpacing.sm) {
                            Image(systemName: "circle")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.holoTextSecondary.opacity(0.5))

                            Text(pendingCheckItems[index])
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)

                            Spacer()

                            Button {
                                pendingCheckItems.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.holoError.opacity(0.7))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        if index != pendingCheckItems.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }

                // 添加检查项输入
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoPrimary)

                    TextField("添加检查项", text: $newCheckItemTitle)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .submitLabel(.done)
                        .onSubmit {
                            addCheckItem()
                        }

                    if newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("输入后添加")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    } else {
                        Button {
                            addCheckItem()
                        } label: {
                            Text("添加")
                                .font(.holoCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.holoPrimary)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .animation(.easeInOut(duration: 0.16), value: newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.sm)
        }
    }

    private func addCheckItem() {
        let trimmed = newCheckItemTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let task = existingTask {
            // 编辑模式：直接创建到 Core Data
            do {
                let order = Int16(checkItems.count)
                let item = try repository.addCheckItem(title: trimmed, to: task, order: order)
                checkItems.append(item)
            } catch {
                Self.logger.error("添加检查项失败：\(error.localizedDescription)")
            }
        } else {
            // 新建模式：暂存
            pendingCheckItems.append(trimmed)
        }
        newCheckItemTitle = ""
    }

    private func toggleCheckItem(_ item: CheckItem) {
        do {
            try repository.toggleCheckItem(item)
            // 刷新列表以更新 UI
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }
            }
        } catch {
            Self.logger.error("切换检查项失败：\(error.localizedDescription)")
        }
    }

    private func deleteCheckItem(_ item: CheckItem) {
        do {
            try repository.deleteCheckItem(item)
            checkItems.removeAll { $0.id == item.id }
        } catch {
            Self.logger.error("删除检查项失败：\(error.localizedDescription)")
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

        // 只有设置了截止日期才允许重复
        let shouldCreateRepeat = hasRepeat && hasDueDate

        Task { @MainActor in
            do {
                if let task = existingTask {
                    try repository.updateTask(
                        task,
                        title: trimmedTitle,
                        description: description,
                        priority: priority,
                        dueDate: hasDueDate ? dueDate : nil,
                        isAllDay: !hasTime,
                        list: selectedList,
                        tags: selectedTagObjects,
                        reminders: remindersToSave
                    )

                    // 处理重复规则
                    if shouldCreateRepeat {
                        // 如果已有规则则删除旧的
                        if let existingRule = task.repeatRule {
                            try repository.deleteRepeatRule(existingRule)
                        }
                        // 创建新规则
                        _ = try repository.createRepeatRule(
                            type: repeatType,
                            for: task,
                            weekdays: repeatType == .custom ? Array(selectedWeekdays) : nil,
                            untilDate: endConditionType == .onDate ? repeatEndDate : nil
                        )

                        // 设置每月模式参数
                        if repeatType == .monthly {
                            if let rule = task.repeatRule {
                                try repository.updateRepeatRuleMonthlyParams(
                                    rule,
                                    monthDay: monthlyRepeatMode == .dayOfMonth ? monthDay : nil,
                                    monthWeekOrdinal: monthlyRepeatMode == .nthWeekday ? monthWeekOrdinal : nil,
                                    monthWeekday: monthlyRepeatMode == .nthWeekday ? monthWeekday : nil,
                                    untilCount: endConditionType == .afterCount ? repeatEndCount : nil
                                )
                            }
                        }
                    } else if let existingRule = task.repeatRule {
                        // 如果不需要重复但已有规则，则删除
                        try repository.deleteRepeatRule(existingRule)
                    }
                } else {
                    let newTask = try repository.createTask(
                        title: trimmedTitle,
                        description: description.isEmpty ? nil : description,
                        list: selectedList,
                        priority: priority,
                        dueDate: hasDueDate ? dueDate : nil,
                        isAllDay: !hasTime,
                        tags: selectedTagObjects,
                        reminders: remindersToSave
                    )

                    // 记忆本次选择的清单，下次创建任务时默认使用
                    lastSelectedListId = selectedListId?.uuidString

                    // 创建暂存的检查项
                    for (index, itemTitle) in pendingCheckItems.enumerated() {
                        _ = try repository.addCheckItem(title: itemTitle, to: newTask, order: Int16(index))
                    }

                    // 创建重复规则
                    if shouldCreateRepeat {
                        _ = try repository.createRepeatRule(
                            type: repeatType,
                            for: newTask,
                            weekdays: repeatType == .custom ? Array(selectedWeekdays) : nil,
                            untilDate: endConditionType == .onDate ? repeatEndDate : nil
                        )

                        // 设置每月模式参数
                        if repeatType == .monthly {
                            if let rule = newTask.repeatRule {
                                try repository.updateRepeatRuleMonthlyParams(
                                    rule,
                                    monthDay: monthlyRepeatMode == .dayOfMonth ? monthDay : nil,
                                    monthWeekOrdinal: monthlyRepeatMode == .nthWeekday ? monthWeekOrdinal : nil,
                                    monthWeekday: monthlyRepeatMode == .nthWeekday ? monthWeekday : nil,
                                    untilCount: endConditionType == .afterCount ? repeatEndCount : nil
                                )
                            }
                        }
                    }
                }

                HapticManager.success()

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

    // MARK: - 提醒选择弹窗

    private var reminderSheet: some View {
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

    // MARK: - 重复设置弹窗

    private var repeatSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    RepeatPicker(
                        hasRepeat: .constant(true),
                        repeatType: $repeatType,
                        selectedWeekdays: $selectedWeekdays,
                        monthDay: $monthDay,
                        monthWeekOrdinal: $monthWeekOrdinal,
                        monthWeekday: $monthWeekday,
                        monthlyRepeatMode: $monthlyRepeatMode,
                        endConditionType: $endConditionType,
                        endDate: $repeatEndDate,
                        endCount: $repeatEndCount,
                        isEnabled: true
                    )
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("重复设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        showRepeatSheet = false
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Preview

#Preview {
    AddTaskSheet(repository: TodoRepository.shared, list: nil)
}
