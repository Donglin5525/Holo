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
                    // 图标和颜色选择
                    iconColorSection
                    
                    // 名称输入
                    nameSection
                    
                    // 习惯类型选择
                    typeSection
                    
                    // 数值型子类型（仅当选择数值型时显示）
                    if selectedType == .numeric {
                        aggregationTypeSection
                    }

                    // 打卡提醒（仅打卡型）
                    if selectedType == .checkIn {
                        reminderSection
                    }

                    // 频率选择
                    frequencySection
                    
                    // 目标设置
                    targetSection

                    // 习惯性质（好习惯/坏习惯）
                    habitNatureSection
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
            }
            .background(Color.holoBackground)
            .navigationTitle(isEditing ? "编辑习惯" : "新增习惯")
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
                        saveHabit()
                    }
                    .foregroundColor(canSave ? .holoPrimary : .holoTextSecondary)
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
                .foregroundColor(.holoTextSecondary)
            
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
                                    .stroke(Color.holoCardBackground, lineWidth: selectedColor == color ? 2 : 0)
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
                .foregroundColor(.holoTextSecondary)
            
            TextField("如：早起、喝水、运动", text: $name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
        }
    }
    
    // MARK: - 习惯类型选择
    
    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("习惯类型")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
            
            Picker("习惯类型", selection: $selectedType) {
                ForEach(HabitType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            
            Text(selectedType.description)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }
    
    // MARK: - 聚合类型选择（数值型）

    private var aggregationTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("数值类型")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Picker("数值类型", selection: $selectedAggregationType) {
                ForEach(HabitAggregationType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedAggregationType.description)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - 打卡提醒选择（打卡型）

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("打卡提醒")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HabitReminderModePicker(mode: $reminderMode, time: $reminderTime)
        }
    }
    
    // MARK: - 频率选择
    
    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("频率")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
            
            HStack(spacing: 8) {
                ForEach(HabitFrequency.allCases) { freq in
                    Button {
                        selectedFrequency = freq
                    } label: {
                        Text(freq.displayName)
                            .font(.holoCaption)
                            .foregroundColor(selectedFrequency == freq ? .white : .holoTextPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.sm)
                                    .fill(selectedFrequency == freq ? Color.holoPrimary : Color.holoCardBackground)
                            )
                    }
                }
            }
        }
    }
    
    // MARK: - 目标设置

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("目标（可选）")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            if selectedType == .checkIn {
                HStack(spacing: 8) {
                    TextField("目标次数", text: $targetCount)
                        .font(.holoBody)
                        .keyboardType(.numberPad)
                        .foregroundColor(.holoTextPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoCardBackground)
                        .cornerRadius(HoloRadius.sm)

                    Text("次/\(selectedFrequency.displayName)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("目标值", text: $targetValue)
                        .font(.holoBody)
                        .keyboardType(.decimalPad)
                        .foregroundColor(.holoTextPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoCardBackground)
                        .cornerRadius(HoloRadius.sm)

                    TextField("单位", text: $unit)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoCardBackground)
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
                .foregroundColor(.holoTextSecondary)

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
                    .foregroundColor(isBadHabit == false ? .white : .holoTextPrimary)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(isBadHabit == false ? Color.holoPrimary : Color.holoCardBackground)
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
                    .foregroundColor(isBadHabit == true ? .white : .holoTextPrimary)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(isBadHabit == true ? Color.holoError : Color.holoCardBackground)
                    )
                }
            }

            Text(natureDescriptionText)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    /// 习惯性质描述文案
    private var natureDescriptionText: String {
        if isBadHabit == true {
            return "超过目标值时将以红色标记并提醒控制"
        } else if isBadHabit == false {
            return "培养积极的好习惯，目标达成时给予正向反馈"
        } else {
            return "选择后可启用对应的提醒策略"
        }
    }
    
    // MARK: - 保存习惯
    
    private func saveHabit() {
        guard canSave else { return }
        isSaving = true
        
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tc = Int(targetCount)
        let tv = Double(targetValue)
        let u = unit.isEmpty ? nil : unit
        let badHabit = isBadHabit ?? false
        let calendar = Calendar.current
        // 打卡提醒仅打卡型有意义；数值型不参与提醒，走默认值/不更新
        let isCheckIn = selectedType == .checkIn
        let reminderTimeComponents = (
            hour: calendar.component(.hour, from: reminderTime),
            minute: calendar.component(.minute, from: reminderTime)
        )

        do {
            if let habit = editingHabit {
                // 编辑模式
                try repository.updateHabit(habit, updates: HabitUpdates(
                    name: trimmedName,
                    icon: selectedIcon,
                    color: selectedColor,
                    frequency: selectedFrequency,
                    targetCount: tc,
                    targetValue: tv,
                    unit: u,
                    aggregationType: selectedAggregationType,
                    isBadHabit: isBadHabit,
                    reminderMode: isCheckIn ? reminderMode : nil,
                    reminderTime: isCheckIn ? reminderTimeComponents : nil
                ))
            } else {
                // 新增模式
                _ = try repository.createHabit(
                    name: trimmedName,
                    icon: selectedIcon,
                    color: selectedColor,
                    type: selectedType,
                    frequency: selectedFrequency,
                    targetCount: tc,
                    targetValue: tv,
                    unit: u,
                    aggregationType: selectedAggregationType,
                    isBadHabit: badHabit,
                    reminderMode: isCheckIn ? reminderMode : .follow,
                    reminderTime: reminderTimeComponents
                )
            }
            
            onSave?()
            dismiss()

            HapticManager.success()
        } catch {
            logger.error("保存失败: \(error)")
            isSaving = false
        }
    }
}

// MARK: - IconPickerSheet

/// 图标选择器（经典 SF Symbol 分组 + Emoji 库双页签）
struct IconPickerSheet: View {

    @Environment(\.dismiss) var dismiss
    @Binding var selectedIcon: String

    enum PickerTab: String, CaseIterable, Identifiable {
        case classic = "经典"
        case emoji = "Emoji"
        var id: String { rawValue }
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
                        Text(tab.rawValue).tag(tab)
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
                    .background(Color.holoBackground)
                }
            }
            .background(Color.holoBackground)
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
                    .foregroundColor(.holoTextSecondary)
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
                        .fill(selectedIcon == item.name ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
                        .frame(width: 52, height: 52)
                    
                    // 根据是否为自定义图标选择不同的显示方式
                    if item.isCustom {
                        Image(item.name)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .foregroundColor(selectedIcon == item.name ? .holoPrimary : .holoTextPrimary)
                    } else {
                        Image(systemName: item.name)
                            .font(.system(size: 22))
                            .foregroundColor(selectedIcon == item.name ? .holoPrimary : .holoTextPrimary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(selectedIcon == item.name ? Color.holoPrimary : Color.clear, lineWidth: 2)
                )
                
                Text(item.label)
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AddHabitSheet()
}
