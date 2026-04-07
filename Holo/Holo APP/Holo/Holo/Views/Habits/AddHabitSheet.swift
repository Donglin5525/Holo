//
//  AddHabitSheet.swift
//  Holo
//
//  新增习惯表单
//  支持创建打卡型和数值型习惯
//

import SwiftUI

/// 新增习惯表单
struct AddHabitSheet: View {
    
    // MARK: - Properties
    
    @Environment(\.dismiss) var dismiss
    
    /// 保存完成回调
    var onSave: (() -> Void)?
    
    /// 编辑模式（传入已有习惯）
    var editingHabit: Habit? = nil
    
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
    
    @State private var showIconPicker: Bool = false
    @State private var isSaving: Bool = false

    // 未保存修改确认
    @State private var showDismissAlert: Bool = false
    
    private let repository = HabitRepository.shared
    
    /// 是否为编辑模式
    private var isEditing: Bool { editingHabit != nil }
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
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
    }

    // MARK: - 未保存修改检测

    /// 是否有未保存的修改
    private var hasUnsavedChanges: Bool {
        if let habit = editingHabit {
            // 编辑模式：比较与原始习惯的差异
            return name != habit.name
                || selectedIcon != habit.icon
                || selectedColor != habit.color
                || selectedType.rawValue != habit.type
                || selectedFrequency.rawValue != habit.frequency
        } else {
            // 新增模式：检查是否输入了内容
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    
    // MARK: - 是否可保存
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    // MARK: - 加载编辑数据
    
    private func loadEditingData() {
        guard let habit = editingHabit else { return }

        name = habit.name
        selectedType = habit.habitType
        selectedIcon = habit.icon
        selectedColor = habit.color
        selectedFrequency = habit.habitFrequency
        selectedAggregationType = habit.habitAggregationType
        isBadHabit = habit.isBadHabit
        
        if let tc = habit.targetCountValue {
            targetCount = String(tc)
        }
        if let tv = habit.targetValueDouble {
            targetValue = habit.formatValue(tv)
        }
        if let u = habit.unit {
            unit = u
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
                        .fill(Color(hex: selectedColor).opacity(0.1) ?? Color.holoInfo.opacity(0.1))
                        .frame(width: 64, height: 64)
                    
                    // 判断是否为自定义图标
                    if let item = HabitIconPresets.allItems.first(where: { $0.name == selectedIcon }), item.isCustom {
                        Image(selectedIcon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .foregroundColor(Color(hex: selectedColor) ?? .holoInfo)
                    } else {
                        Image(systemName: selectedIcon)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(Color(hex: selectedColor) ?? .holoInfo)
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
                            .fill(Color(hex: color) ?? .holoInfo)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .stroke(Color.holoCardBackground, lineWidth: selectedColor == color ? 2 : 0)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color(hex: color).opacity(0.3) ?? .clear, lineWidth: selectedColor == color ? 1 : 0)
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
            Text("习惯性质")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: 8) {
                Button {
                    isBadHabit = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                        Text("好习惯")
                            .font(.holoCaption)
                    }
                    .foregroundColor(!isBadHabit ? .white : .holoTextPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(!isBadHabit ? Color.holoPrimary : Color.holoCardBackground)
                    )
                }

                Button {
                    isBadHabit = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("坏习惯")
                            .font(.holoCaption)
                    }
                    .foregroundColor(isBadHabit ? .white : .holoTextPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(isBadHabit ? Color.red : Color.holoCardBackground)
                    )
                }
            }

            Text(isBadHabit ? "超过目标值时将以红色标记并提醒控制" : "培养积极的好习惯，目标达成时给予正向反馈")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
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
                    isBadHabit: isBadHabit
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
                    isBadHabit: isBadHabit
                )
            }
            
            onSave?()
            dismiss()

            HapticManager.success()
        } catch {
            print("[AddHabitSheet] 保存失败: \(error)")
            isSaving = false
        }
    }
}

// MARK: - IconPickerSheet

/// 图标选择器（按分类展示）
struct IconPickerSheet: View {
    
    @Environment(\.dismiss) var dismiss
    @Binding var selectedIcon: String
    
    /// 网格列定义（5列）
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 24, pinnedViews: []) {
                    ForEach(HabitIconPresets.categories) { category in
                        categorySection(category)
                    }
                }
                .padding()
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
