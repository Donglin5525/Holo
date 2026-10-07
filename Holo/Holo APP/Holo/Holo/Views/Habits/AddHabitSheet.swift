//
//  AddHabitSheet.swift
//  Holo
//
//  新增习惯表单
//  支持创建打卡型和数值型习惯
//

import SwiftUI
import os.log

/// 新建习惯的预填草稿（空状态示例磁贴入口）
/// id 仅用于驱动 sheet(item:) 的展示；空草稿（默认值）= 普通新建
struct HabitPrefillDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var icon: String = "checkmark.circle"
    var color: String = "#13A4EC"
}

/// 新增习惯表单
struct AddHabitSheet: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "AddHabitSheet")

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss

    /// 保存完成回调
    var onSave: (() -> Void)?

    /// 编辑模式（传入已有习惯）
    var editingHabit: Habit? = nil

    /// 新建预填草稿（与编辑模式互斥：编辑优先）
    var prefill: HabitPrefillDraft? = nil
    
    // 表单状态
    @State private var name: String = ""
    @State private var selectedType: HabitType = .checkIn
    @State private var selectedIcon: String = "checkmark.circle"
    @State private var selectedColor: String = "#13A4EC"
    @State private var selectedFrequency: HabitFrequency = .daily
    @State private var targetCount: String = ""
    @State private var targetValue: String = ""
    @State private var unit: String = ""
    @State private var selectedAggregationType: HabitAggregationType = .sum
    @State private var isBadHabit: Bool? = nil

    // 打卡提醒（仅打卡型；solo 模式的时刻，默认 09:00）
    @State private var reminderMode: HabitReminderMode = .follow
    @State private var reminderTime: Date = Self.defaultReminderTime
    
    @State private var showIconPicker: Bool = false
    @State private var isSaving: Bool = false

    // 目标三态（方案 §8.2/§12.4）：目标关闭 = 编辑模式提交 clear，不能被误解释为「不更新」
    @State private var targetEnabled: Bool = false
    // 关联目标（真实 Goal 关系，非名称字符串）
    @State private var goalSelection: Goal? = nil
    @State private var initialGoalId: UUID? = nil
    @State private var showGoalPicker: Bool = false
    // 渐进配置展开状态（§8.2：首屏只做名称+方式两个决定）
    @State private var expandedGoalsFrequency = false
    @State private var expandedReminderGoal = false
    @State private var expandedIconColor = false
    @State private var expandedNature = false

    // 保存失败：表单内错误 + 保留草稿重试（方案 §8.3/§11.4）
    @State private var saveErrorMessage: String? = nil
    /// 新增时「基础习惯已创建但目标关联失败」的续接草稿 ID（重试只补关联，不再新建）
    @State private var pendingGoalLinkHabitId: UUID? = nil

    // 未保存修改确认
    @State private var showDismissAlert: Bool = false
    
    private let repository = HabitRepository.shared
    
    /// 是否为编辑模式
    private var isEditing: Bool { editingHabit != nil }

    /// solo 模式默认时刻 09:00
    private static let defaultReminderTime: Date = {
        var comps = DateComponents()
        comps.hour = 9
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }()
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 名称：第一个必要决定
                    nameSection

                    // 记录方式：第二个必要决定（打卡/计数/测量，方案 §8.1）
                    methodSection

                    // 渐进配置：按需展开但能力完整（方案 §8.2）
                    configSection(title: String(localized: "目标与频率"),
                                  summary: goalsFrequencySummary,
                                  isExpanded: $expandedGoalsFrequency) {
                        frequencySection
                        targetSection
                    }

                    configSection(title: String(localized: "提醒与关联目标"),
                                  summary: reminderGoalSummary,
                                  isExpanded: $expandedReminderGoal) {
                        if selectedType == .checkIn {
                            reminderSection
                        }
                        goalLinkSection
                    }

                    configSection(title: String(localized: "图标与颜色"),
                                  summary: String(localized: "已选择"),
                                  isExpanded: $expandedIconColor) {
                        iconColorSection
                    }

                    configSection(title: String(localized: "习惯性质"),
                                  summary: natureSummaryText,
                                  isExpanded: $expandedNature) {
                        habitNatureSection
                    }

                    // 保存失败：表单内显示原因与重试，输入不清空不关闭（方案 §8.3）
                    if let saveErrorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 13))
                            Text(saveErrorMessage)
                        }
                        .font(.holoCaption)
                        .foregroundColor(.holoError)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(Color.holoError.opacity(0.08))
                        )
                    }

                    // V2 §8：编辑态底部 = 习惯设置的生命周期操作
                    if isEditing {
                        lifecycleSection
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(isEditing ? String(localized: "编辑习惯") : String(localized: "新增习惯"))
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
                    .foregroundColor(.holoToolTextSecondary)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveHabit()
                    }
                    .foregroundColor(canSave ? .holoPrimary : .holoToolTextSecondary)
                    .fontWeight(.semibold)
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear {
                loadEditingData()
            }
        }
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(selectedIcon: $selectedIcon)
        }
        .sheet(isPresented: $showGoalPicker) {
            GoalPickerSheet(currentGoalId: goalSelection?.id) { goal in
                goalSelection = goal
            }
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
        // 无改动时保留系统下拉关闭；有改动时拦下并走「放弃修改？」确认
        .interactiveDismissDisabled(hasUnsavedChanges)
        .sheetDismissGuard { showDismissAlert = true }
    }

    // MARK: - 生命周期操作（V2 §8：与编辑表单同层，操作靠近对象）

    @State private var pauseTarget: Habit? = nil
    @State private var pendingLifecycleAction: LifecycleAction? = nil
    @State private var lifecycleError: String? = nil
    @ObservedObject private var entitlement = HoloEntitlementState.shared

    private enum LifecycleAction: Identifiable {
        case archive, delete

        var id: Int { self == .archive ? 0 : 1 }
    }

    /// 编辑对象当前生命周期（读取托管对象现值）
    private var editingLifecycle: HabitLifecycle {
        guard let habit = editingHabit else { return .active }
        if habit.isArchived { return .archived }
        return habit.isPaused ? .paused : .active
    }

    @ViewBuilder
    private var lifecycleSection: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.6))
                .frame(height: 0.5)
                .padding(.vertical, 6)

            if let lifecycleError {
                Text(lifecycleError)
                    .font(.system(size: 12))
                    .foregroundColor(.holoError)
                    .padding(.bottom, 6)
            }

            switch editingLifecycle {
            case .active:
                lifecycleRow(icon: "pause.circle",
                             title: String(localized: "暂停习惯"),
                             plusMark: entitlement.isPlusActive ? false : true,
                             subtitle: String(localized: "给日常留一段空隙")) {
                    requestPause()
                }
                lifecycleRow(icon: "archivebox",
                             title: String(localized: "归档习惯"),
                             subtitle: String(localized: "从今天隐藏，保留全部历史")) {
                    pendingLifecycleAction = .archive
                }
            case .paused:
                lifecycleRow(icon: "play.circle",
                             title: String(localized: "恢复习惯"),
                             subtitle: String(localized: "重新出现在今天")) {
                    performLifecycle { try repository.resumeHabitById(editingHabit!.id) }
                }
                lifecycleRow(icon: "archivebox",
                             title: String(localized: "归档习惯"),
                             subtitle: String(localized: "从今天隐藏，保留全部历史")) {
                    pendingLifecycleAction = .archive
                }
            case .archived:
                lifecycleRow(icon: "archivebox",
                             title: String(localized: "取消归档"),
                             subtitle: String(localized: "恢复后沿用原暂停状态")) {
                    performLifecycle { try repository.unarchiveHabitById(editingHabit!.id) }
                }
            }

            lifecycleRow(icon: "trash",
                         title: String(localized: "删除习惯"),
                         subtitle: String(localized: "删除习惯及全部记录，无法恢复"),
                         destructive: true) {
                pendingLifecycleAction = .delete
            }
        }
        .sheet(item: $pauseTarget) { habit in
            HabitPauseSheet(habit: habit, onPaused: {
                // 暂停确认成功：收起整个设置弹层回页面（HTML 同款：关闭全部弹层）
                dismiss()
            })
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(get: { pendingLifecycleAction != nil },
                                 set: { if !$0 { pendingLifecycleAction = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirmButtonTitle, role: .destructive) {
                if let action = pendingLifecycleAction {
                    switch action {
                    case .archive:
                        performLifecycle { try repository.archiveHabitById(editingHabit!.id) }
                    case .delete:
                        performLifecycle { try repository.deleteHabitById(editingHabit!.id) }
                    }
                }
                pendingLifecycleAction = nil
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingLifecycleAction = nil
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        pendingLifecycleAction == .archive
            ? String(localized: "归档这个习惯？")
            : String(localized: "删除这个习惯？")
    }

    private var confirmButtonTitle: String {
        pendingLifecycleAction == .archive
            ? String(localized: "确认归档")
            : String(localized: "删除习惯与记录")
    }

    private var confirmMessage: String {
        if pendingLifecycleAction == .archive {
            return String(localized: "归档「\(editingHabit?.name ?? "")」后，它会从今天隐藏，历史记录全部保留。")
        }
        return String(localized: "删除「\(editingHabit?.name ?? "")」及全部记录？这项删除无法恢复。")
    }

    private func lifecycleRow(icon: String, title: String, plusMark: Bool = false,
                              subtitle: String, destructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(destructive ? .holoError : .holoToolTextSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.holoBody)
                            .foregroundColor(destructive ? .holoError : .holoToolText)
                        if plusMark {
                            Text("Plus")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.holoPrimary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.holoPrimary.opacity(0.6)))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 暂停按 Plus 权益执行（既有契约：真实权益确认后才开弹层）
    private func requestPause() {
        guard let habit = editingHabit else { return }
        if entitlement.isPlusActive {
            pauseTarget = habit
        } else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .habitPause) {
                await MainActor.run {
                    pauseTarget = HabitRepository.shared.findHabit(by: habit.id)
                }
            }
        }
    }

    /// 生命周期动作：成功关全部弹层；失败原状态保留并说明（A16）
    private func performLifecycle(_ work: () throws -> Void) {
        do {
            try work()
            lifecycleError = nil
            dismiss()
        } catch {
            lifecycleError = String(localized: "操作没有成功，状态保持原样。请重试。")
        }
    }

    // MARK: - 未保存修改检测

    /// 是否有未保存的修改
    private var hasUnsavedChanges: Bool {
        if let habit = editingHabit {
            // 编辑模式：比较与原始习惯的差异
            var changed = name != habit.name
                || selectedIcon != habit.icon
                || selectedColor != habit.color
                || selectedType.rawValue != habit.type
                || selectedFrequency.rawValue != habit.frequency

            // 打卡型：提醒模式/时间改动也算未保存修改
            if selectedType == .checkIn {
                let calendar = Calendar.current
                changed = changed
                    || reminderMode != habit.habitReminderMode
                    || calendar.component(.hour, from: reminderTime) != Int(habit.reminderHour)
                    || calendar.component(.minute, from: reminderTime) != Int(habit.reminderMinute)
            }
            // 目标三态与关联目标改动
            let originalTargetExists = habit.targetValueDouble != nil || habit.targetCountValue != nil
            changed = changed
                || targetEnabled != originalTargetExists
                || goalSelection?.id != habit.goal?.id
            if targetEnabled, originalTargetExists {
                changed = changed
                    || (Int(targetCount) ?? habit.targetCountValue ?? -1) != (habit.targetCountValue ?? -1)
                    || (Double(targetValue) ?? habit.targetValueDouble ?? -1) != (habit.targetValueDouble ?? -1)
                    || unit != (habit.unit ?? "")
            }
            return changed
        } else {
            // 新增模式：检查是否输入了内容
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    
    // MARK: - 是否可保存
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    // MARK: - 初始数据加载

    private func loadEditingData() {
        if let habit = editingHabit {
            name = habit.name
            selectedType = habit.habitType
            selectedIcon = habit.icon
            selectedColor = habit.color
            selectedFrequency = habit.habitFrequency
            selectedAggregationType = habit.habitAggregationType
            isBadHabit = habit.isBadHabit ? true : nil

            if let tc = habit.targetCountValue {
                targetCount = String(tc)
            }
            if let tv = habit.targetValueDouble {
                targetValue = habit.formatValue(tv)
            }
            if let u = habit.unit {
                unit = u
            }

            if habit.isCheckInType {
                reminderMode = habit.habitReminderMode
                var comps = DateComponents()
                comps.hour = Int(habit.reminderHour)
                comps.minute = Int(habit.reminderMinute)
                reminderTime = Calendar.current.date(from: comps) ?? Self.defaultReminderTime
            }

            // 目标三态初始值（数值型 targetValue 优先，历史 targetCount 兜底展示）
            targetEnabled = habit.targetValueDouble != nil || habit.targetCountValue != nil
            initialGoalId = habit.goal?.id
            goalSelection = habit.goal

            // 编辑模式默认展开全部配置（用户需要看到现值）
            expandedGoalsFrequency = true
            expandedReminderGoal = true
            expandedIconColor = false
            expandedNature = false
        } else if let draft = prefill {
            name = draft.name
            selectedIcon = draft.icon
            selectedColor = draft.color
        }
    }
    
    // MARK: - 颜色网格列定义（5列）
    
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
    
    // MARK: - 图标和颜色选择
    
    private var iconColorSection: some View {
        VStack(spacing: 12) {
            // 图标预览
            Button {
                showIconPicker = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(hex: selectedColor).opacity(0.1))
                        .frame(width: 64, height: 64)

                    // 判断是否为自定义图标
                    if EmojiCatalog.isEmojiIcon(selectedIcon) {
                        Text(selectedIcon)
                            .font(.system(size: 30))
                    } else if let item = HabitIconPresets.allItems.first(where: { $0.name == selectedIcon }), item.isCustom {
                        Image(selectedIcon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .foregroundColor(Color(hex: selectedColor))
                    } else {
                        Image(systemName: selectedIcon)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(Color(hex: selectedColor))
                    }
                }
            }
            
            Text("点击选择图标")
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
            
            // 颜色选择（5x2 网格布局）
            LazyVGrid(columns: colorColumns, spacing: 10) {
                ForEach(HabitColorPresets.colors, id: \.self) { color in
                    Button {
                        selectedColor = color
                    } label: {
                        Circle()
                            .fill(Color(hex: color))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .stroke(Color.holoToolSurface, lineWidth: selectedColor == color ? 2 : 0)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color(hex: color).opacity(0.3), lineWidth: selectedColor == color ? 1 : 0)
                                    .padding(-1)
                            )
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
        }
        .padding(.vertical, HoloSpacing.sm)
    }
    
    // MARK: - 名称输入
    
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("习惯名称")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
            
            TextField("如：早起、喝水、运动", text: $name)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoToolSurface)
                .cornerRadius(HoloRadius.sm)
        }
    }
    
    // MARK: - 记录方式（三卡，方案 §8.1：先名称后方式，两个必要决定）

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("记录方式")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            VStack(spacing: 8) {
                methodCard(.checkIn, .sum,
                           title: String(localized: "打卡"),
                           subtitle: String(localized: "做了以后留一个勾"),
                           icon: "checkmark.circle")
                methodCard(.numeric, .sum,
                           title: String(localized: "计数"),
                           subtitle: String(localized: "一次次累加，例如喝水、练习次数"),
                           icon: "number")
                methodCard(.numeric, .latest,
                           title: String(localized: "测量"),
                           subtitle: String(localized: "记下每次的数值，例如体重、时长"),
                           icon: "scalemass")
            }

            // 编辑模式且类型有改动：预告历史记录的转换方式（复用既有幂等桥接）
            if let habit = editingHabit,
               selectedType != habit.habitType || selectedAggregationType != habit.habitAggregationType {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text(typeChangeHint)
                }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(Color.holoPrimary.opacity(0.08))
                )
            }
        }
    }

    private func methodCard(_ type: HabitType, _ aggregation: HabitAggregationType,
                            title: String, subtitle: String, icon: String) -> some View {
        let isSelected = selectedType == type && selectedAggregationType == aggregation
        return Button {
            withAnimation(HoloAnimation.quick) {
                selectedType = type
                selectedAggregationType = aggregation
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .holoPrimary : .holoToolTextSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.holoBody.weight(.medium))
                        .foregroundColor(.holoToolText)
                    Text(subtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.08) : Color.holoToolSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .strokeBorder(isSelected ? Color.holoPrimary.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 类型/聚合切换的历史记录转换预告文案
    private var typeChangeHint: String {
        switch selectedType {
        case .checkIn:
            String(localized: "保存后，历史数值记录的每一天将标记为已完成，数值保留，可随时切回")
        case .numeric:
            selectedAggregationType == .sum
                ? String(localized: "保存后，历史打卡将按每次 1 计入统计，勾选状态保留，可随时切回")
                : String(localized: "保存后，历史打卡将按每次 1 计入统计，勾选状态保留，可随时切回")
        }
    }

    // MARK: - 渐进配置容器（摘要行 + 点开设置）

    private func configSection<Content: View>(title: String, summary: String,
                                              isExpanded: Binding<Bool>,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(HoloAnimation.quick) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.holoLabel)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    Text(summary)
                        .font(.holoCaption)
                        .foregroundColor(.holoToolTextSecondary)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.sm)
    }

    private var goalsFrequencySummary: String {
        var parts: [String] = [selectedFrequency.displayName]
        if targetEnabled {
            if selectedType == .checkIn, let tc = Int(targetCount), tc > 0 {
                parts.append(String(localized: "目标 \(tc) 次"))
            } else if selectedType == .numeric, !targetValue.isEmpty {
                parts.append(String(localized: "目标 \(targetValue)\(unit.isEmpty ? "" : " \(unit)")"))
            }
        } else {
            parts.append(String(localized: "无目标"))
        }
        return parts.joined(separator: " · ")
    }

    private var reminderGoalSummary: String {
        var parts: [String] = []
        if selectedType == .checkIn {
            parts.append(reminderMode.displayName)
        }
        parts.append(goalSelection != nil
            ? String(localized: "已关联目标")
            : String(localized: "未关联目标"))
        return parts.joined(separator: " · ")
    }

    private var natureSummaryText: String {
        switch isBadHabit {
        case .some(false): return String(localized: "好习惯")
        case .some(true): return String(localized: "坏习惯")
        case .none: return String(localized: "好习惯")
        }
    }

    // MARK: - 关联目标（真实 Goal 关系，方案 §6.3/§8.2）

    private var goalLinkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("关联目标（可选）")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            Button {
                showGoalPicker = true
            } label: {
                HStack {
                    Image(systemName: "target")
                        .font(.system(size: 13))
                        .foregroundColor(goalSelection != nil ? .holoPrimary : .holoToolTextSecondary)
                    Text(goalSelection?.title ?? String(localized: "暂不关联"))
                        .font(.holoBody)
                        .foregroundColor(goalSelection != nil ? .holoToolText : .holoToolTextSecondary)
                    Spacer()
                    if goalSelection != nil {
                        Button {
                            goalSelection = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("habit.edit.goal")
        }
    }

    // MARK: - 习惯类型（旧 segmented 保留兼容引用；新 UI 走 methodSection）
    
    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("习惯类型")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
            
            Picker("习惯类型", selection: $selectedType) {
                ForEach(HabitType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedType.description)
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)

            // 编辑模式且类型有改动：预告历史记录的转换方式
            if let habit = editingHabit, selectedType != habit.habitType {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text(typeChangeHint)
                }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(Color.holoPrimary.opacity(0.08))
                )
            }
        }
    }

    
    // MARK: - 聚合类型选择（数值型）

    private var aggregationTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("数值类型")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            Picker("数值类型", selection: $selectedAggregationType) {
                ForEach(HabitAggregationType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedAggregationType.description)
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
        }
    }

    // MARK: - 打卡提醒选择（打卡型）

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("打卡提醒")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            HabitReminderModePicker(mode: $reminderMode, time: $reminderTime)
        }
    }
    
    // MARK: - 频率选择
    
    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("频率")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
            
            HStack(spacing: 8) {
                ForEach(HabitFrequency.allCases) { freq in
                    Button {
                        selectedFrequency = freq
                    } label: {
                        Text(freq.displayName)
                            .font(.holoCaption)
                            .foregroundColor(selectedFrequency == freq ? .white : .holoToolText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.sm)
                                    .fill(selectedFrequency == freq ? Color.holoPrimary : Color.holoToolSurface)
                            )
                    }
                }
            }
        }
    }
    
    // MARK: - 目标设置

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("目标（可选）")
                    .font(.holoLabel)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                // 目标开关：关闭 = 编辑模式提交 clear（两个兼容字段一并清除，方案 §9.2）
                Toggle("", isOn: $targetEnabled)
                    .labelsHidden()
                    .frame(width: 46)
                    .accessibilityIdentifier("habit.edit.targetToggle")
            }

            if !targetEnabled {
                Text(String(localized: "未设置目标；编辑时关闭会清除已有目标"))
                    .font(.holoCaption)
                    .foregroundColor(.holoToolTextSecondary.opacity(0.8))
            } else if selectedType == .checkIn {
                HStack(spacing: 8) {
                    TextField("目标次数", text: $targetCount)
                        .font(.holoBody)
                        .keyboardType(.numberPad)
                        .foregroundColor(.holoToolText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoToolSurface)
                        .cornerRadius(HoloRadius.sm)

                    Text("次/\(selectedFrequency.displayName)")
                        .font(.holoCaption)
                        .foregroundColor(.holoToolTextSecondary)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("目标值", text: $targetValue)
                        .font(.holoBody)
                        .keyboardType(.decimalPad)
                        .foregroundColor(.holoToolText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoToolSurface)
                        .cornerRadius(HoloRadius.sm)

                    TextField("单位", text: $unit)
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoToolSurface)
                        .cornerRadius(HoloRadius.sm)
                        .frame(width: 70)
                }
            }
        }
    }

    // MARK: - 习惯性质选择

    private var habitNatureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("习惯性质（可选）")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            HStack(spacing: 8) {
                Button {
                    isBadHabit = isBadHabit == false ? nil : false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                        Text("好习惯")
                            .font(.holoCaption)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(isBadHabit == false ? .white : .holoToolText)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(isBadHabit == false ? Color.holoPrimary : Color.holoToolSurface)
                    )
                }

                Button {
                    isBadHabit = isBadHabit == true ? nil : true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("坏习惯")
                            .font(.holoCaption)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(isBadHabit == true ? .white : .holoToolText)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(isBadHabit == true ? Color.holoError : Color.holoToolSurface)
                    )
                }
            }

            Text(natureDescriptionText)
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
        }
    }

    /// 习惯性质描述文案
    private var natureDescriptionText: String {
        if isBadHabit == true {
            return String(localized: "超过目标值时将以红色标记并提醒控制")
        } else if isBadHabit == false {
            return String(localized: "培养积极的好习惯，目标达成时给予正向反馈")
        } else {
            return String(localized: "选择后可启用对应的提醒策略")
        }
    }
    
    // MARK: - 保存习惯
    
    private func saveHabit() {
        guard canSave else { return }
        isSaving = true
        saveErrorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tc = targetEnabled ? Int(targetCount) : nil
        let tv = targetEnabled ? Double(targetValue) : nil
        let u = targetEnabled && !unit.isEmpty ? unit : nil
        let badHabit = isBadHabit ?? false
        let calendar = Calendar.current
        // 打卡提醒仅打卡型有意义；数值型不参与提醒（方案 §6.3）
        let isCheckIn = selectedType == .checkIn
        let reminderTimeComponents = (
            hour: calendar.component(.hour, from: reminderTime),
            minute: calendar.component(.minute, from: reminderTime)
        )

        // 编辑模式：三态字段一次用户意图完整提交（方案 §8.3/§12.4）
        if let habit = editingHabit {
            var payload = HabitEditPayload(
                name: trimmedName, icon: selectedIcon, color: selectedColor,
                type: selectedType, aggregationType: selectedAggregationType,
                frequency: selectedFrequency, isBadHabit: badHabit,
                reminderMode: isCheckIn ? reminderMode : .follow,
                reminderTime: reminderTimeComponents
            )
            // 目标三态：关闭 = clear（两个兼容字段一并清除）；开启有值 = set；开启无值按无效拦截
            if !targetEnabled {
                payload.targetCount = .clear
                payload.targetValue = .clear
            } else if selectedType == .checkIn {
                payload.targetCount = tc.map { .set($0) } ?? .clear
            } else {
                if let tv, tv > 0 {
                    payload.targetValue = .set(tv)
                } else if habit.targetValueDouble != nil || habit.targetCountValue != nil {
                    saveErrorMessage = String(localized: "目标值需要大于 0；或关闭目标")
                    isSaving = false
                    return
                }
            }
            payload.unit = targetEnabled ? (u.map { HabitFieldUpdate<String>.set($0) } ?? .clear) : .clear
            // 目标关系三态
            switch (initialGoalId, goalSelection?.id) {
            case (.none, .none): payload.goalId = .keep
            case (.some(let origin), .some(let now)) where origin == now: payload.goalId = .keep
            case (_, .some(let now)): payload.goalId = .set(now)
            case (.some, .none): payload.goalId = .clear
            }

            do {
                try repository.applyHabitEdits(habitId: habit.id, payload: payload)
                onSave?()
                dismiss()
                HapticManager.success()
            } catch {
                // 失败：保留草稿、显示原因、可重试（不关闭不清理）
                logger.error("编辑保存失败: \(error)")
                saveErrorMessage = String(localized: "这次没有保存成功，内容还在，可以重试")
                isSaving = false
            }
            return
        }

        // 新增模式
        do {
            if let pendingId = pendingGoalLinkHabitId {
                // 续接：基础习惯已创建，仅补目标关联（同一草稿 ID，不重复新建）
                try linkGoal(habitId: pendingId)
                pendingGoalLinkHabitId = nil
            } else {
                let habit = try repository.createHabit(
                    name: trimmedName,
                    icon: selectedIcon,
                    color: selectedColor,
                    type: selectedType,
                    frequency: selectedFrequency,
                    targetCount: selectedType == .checkIn ? tc : nil,
                    targetValue: selectedType == .numeric ? tv : nil,
                    unit: selectedType == .numeric ? u : nil,
                    aggregationType: selectedAggregationType,
                    isBadHabit: badHabit,
                    reminderMode: isCheckIn ? reminderMode : .follow,
                    reminderTime: reminderTimeComponents
                )
                // 目标关联失败不回滚基础习惯：保留同一草稿 ID 只补关联（方案 §8.3）
                if let goal = goalSelection {
                    do {
                        try linkGoal(habitId: habit.id)
                    } catch {
                        pendingGoalLinkHabitId = habit.id
                        throw error
                    }
                }
            }
            onSave?()
            dismiss()
            HapticManager.success()
        } catch {
            logger.error("新增保存失败: \(error)")
            saveErrorMessage = pendingGoalLinkHabitId != nil
                ? String(localized: "习惯已创建，但目标关联没有成功；再点保存只补关联")
                : String(localized: "这次没有保存成功，内容还在，可以重试")
            isSaving = false
        }
    }

    /// 用 GoalRepository 既有通道建立习惯→目标关系
    private func linkGoal(habitId: UUID) throws {
        guard let goal = goalSelection else { return }
        guard let habit = repository.findHabit(by: habitId) else {
            throw HabitError.notFound
        }
        try GoalRepository.shared.linkHabit(habit, to: goal)
    }
}

// MARK: - IconPickerSheet

/// 图标选择器（经典 SF Symbol 分组 + Emoji 库双页签）
struct IconPickerSheet: View {

    @Environment(\.dismiss) var dismiss
    @Binding var selectedIcon: String

    enum PickerTab: String, CaseIterable, Identifiable {
        case classic
        case emoji = "Emoji"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .classic: String(localized: "经典")
            case .emoji: "Emoji"
            }
        }
    }

    @State private var pickerTab: PickerTab

    init(selectedIcon: Binding<String>) {
        self._selectedIcon = selectedIcon
        // 当前已是 emoji 时直接落在 Emoji 页
        self._pickerTab = State(initialValue: EmojiCatalog.isEmojiIcon(selectedIcon.wrappedValue) ? .emoji : .classic)
    }

    /// 网格列定义（5列）
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("图标类型", selection: $pickerTab) {
                    ForEach(PickerTab.allCases) { tab in
                        Text(tab.displayName).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(HoloSpacing.md)

                if pickerTab == .emoji {
                    EmojiCatalogGrid(currentIcon: selectedIcon) { emoji in
                        selectedIcon = emoji
                        dismiss()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 24, pinnedViews: []) {
                            ForEach(HabitIconPresets.categories) { category in
                                categorySection(category)
                            }
                        }
                        .padding()
                    }
                    .background(Color.holoToolBackground)
                }
            }
            .background(Color.holoToolBackground)
            .navigationTitle("选择图标")
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
    }
    
    // MARK: - 分类区块
    
    @ViewBuilder
    private func categorySection(_ category: HabitIconCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 分类标题
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoPrimary)
                
                Text(category.name)
                    .font(.holoLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }
            
            // 图标网格
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(category.items) { item in
                    iconButton(item)
                }
            }
        }
    }
    
    // MARK: - 图标按钮
    
    @ViewBuilder
    private func iconButton(_ item: IconItem) -> some View {
        Button {
            selectedIcon = item.name
            dismiss()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(selectedIcon == item.name ? Color.holoPrimary.opacity(0.1) : Color.holoToolSurface)
                        .frame(width: 52, height: 52)
                    
                    // 根据是否为自定义图标选择不同的显示方式
                    if item.isCustom {
                        Image(item.name)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .foregroundColor(selectedIcon == item.name ? .holoPrimary : .holoToolText)
                    } else {
                        Image(systemName: item.name)
                            .font(.system(size: 22))
                            .foregroundColor(selectedIcon == item.name ? .holoPrimary : .holoToolText)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(selectedIcon == item.name ? Color.holoPrimary : Color.clear, lineWidth: 2)
                )
                
                Text(item.label)
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AddHabitSheet()
}
