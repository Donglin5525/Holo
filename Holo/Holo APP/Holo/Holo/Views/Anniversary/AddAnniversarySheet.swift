//
//  AddAnniversarySheet.swift
//  Holo
//
//  纪念日新增/编辑表单
//  结构精简为 3 个视觉块：①名称 ②类型+主题色 ③日期·重复·提醒·备注
//

import SwiftUI

struct AddAnniversarySheet: View {

    var editingAnniversary: Anniversary?

    @Environment(\.dismiss) private var dismiss
    private var repository: AnniversaryRepository { AnniversaryRepository.shared }

    // MARK: - 表单状态

    @State private var title: String = ""
    @State private var date: Date = Date().addingTimeInterval(60 * 60 * 24 * 30)
    @State private var selectedType: AnniversaryType = .countdown
    @State private var customColor: String? = nil
    @State private var customIcon: String? = nil
    @State private var showIconPicker = false
    @State private var note: String = ""
    @State private var repeatYearly: Bool = false
    @State private var reminderEnabled: Bool = false
    @State private var reminderDaysBefore: Int16 = 0
    @State private var generateTask: Bool = true
    @State private var isPinned: Bool = false

    @State private var hasLoadedInitial = false
    @State private var hasUserTouchedRepeat = false
    @State private var isSaving = false
    @State private var showDismissAlert = false
    @State private var showDeleteAlert = false

    private var isEditMode: Bool { editingAnniversary != nil }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 块1：名称
                    titleSection
                    // 块2：类型 + 主题色（合并）
                    typeAndColorSection
                    // 块3：日期 · 重复 · 提醒 · 备注（合并成一个卡片）
                    dateReminderNoteSection
                }
                .padding(HoloSpacing.lg)
                .padding(.bottom, 40)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle(isEditMode ? "编辑纪念日" : "新建纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { requestDismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.holoPrimary)
                    } else {
                        Button(action: save) {
                            Text("保存")
                                .font(.holoBody.bold())
                                .foregroundColor(canSave ? .holoPrimary : .holoTextSecondary)
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
        .onAppear { populateIfEditing() }
        // 右滑返回与其他表单 sheet（AddTaskSheet/AddHabitSheet）保持一致；
        // ignoreNavigationStack：本 sheet 无 push 层级，避免被窗口内其他 push 的
        // NavigationStack 让位导致手势失效（同 AddTaskSheet）
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            requestDismiss()
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
        .alert("删除纪念日", isPresented: $showDeleteAlert) {
            Button("删除纪念日及关联任务", role: .destructive) {
                performDelete(deleteTasks: true)
            }
            Button("仅删除纪念日", role: .destructive) {
                performDelete(deleteTasks: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个纪念日可能已生成关联任务，你想如何处理？")
        }
        // 无改动时保留系统下拉关闭；有改动时拦下并走 requestDismiss 的确认分流
        .interactiveDismissDisabled(hasUnsavedChanges)
        .sheetDismissGuard { requestDismiss() }
    }

    // MARK: - 块1：名称

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("名称")
                .font(.holoCaption.bold())
                .foregroundColor(.holoTextSecondary)

            TextField("如：妈妈的生日", text: $title)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoPrimary.opacity(title.isEmpty ? 0 : 0.3), lineWidth: 1)
                )
        }
    }

    // MARK: - 块2：类型 + 主题色（合并）

    private var typeAndColorSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("类型")
                .font(.holoCaption.bold())
                .foregroundColor(.holoTextSecondary)

            // 类型网格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.sm), count: 4), spacing: HoloSpacing.sm) {
                ForEach(AnniversaryType.allCases, id: \.self) { type in
                    typeChip(type)
                }
            }

            // 主题色（紧跟类型下方，不单独成块）
            HStack(spacing: HoloSpacing.md) {
                ForEach(themeColorOptions, id: \.hex) { option in
                    colorDot(option)
                }

                if customColor != nil {
                    Button {
                        customColor = nil
                    } label: {
                        Text("恢复默认")
                            .font(.system(size: 12))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            .padding(.top, HoloSpacing.xs)

            // 图标选择行（未手选时跟随类型默认）
            iconRow
        }
    }

    private var effectiveIcon: String {
        customIcon ?? selectedType.defaultEmoji
    }

    private var iconRow: some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                showIconPicker = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    Group {
                        if EmojiCatalog.isEmojiIcon(effectiveIcon) {
                            Text(effectiveIcon)
                                .font(.system(size: 22))
                        } else {
                            Image(systemName: effectiveIcon)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(Color(hex: effectiveColor))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(Color(hex: effectiveColor).opacity(0.12))
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("图标")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text(customIcon == nil ? "默认（按类型）" : "已自定义")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .buttonStyle(.plain)

            if customIcon != nil {
                Button {
                    customIcon = nil
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 12))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .sheet(isPresented: $showIconPicker) {
            EmojiIconPickerSheet(currentIcon: effectiveIcon) { emoji in
                customIcon = emoji
            }
        }
    }

    private func typeChip(_ type: AnniversaryType) -> some View {
        let isSelected = selectedType == type
        return Button {
            HapticManager.selection()
            selectedType = type
            if !hasUserTouchedRepeat {
                repeatYearly = type.defaultRepeatYearly
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    // emoji 自带颜色，选中态用浅底+描边替代实色底，避免彩色压彩色
                    Circle()
                        .fill(isSelected ? Color(hex: effectiveColor).opacity(0.15) : Color.holoCardBackground)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle().stroke(isSelected ? Color(hex: effectiveColor) : .clear, lineWidth: 1.5)
                        )

                    Text(type.defaultEmoji)
                        .font(.system(size: 20))
                }
                Text(type.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? Color(hex: effectiveColor).opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? Color(hex: effectiveColor).opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func colorDot(_ option: ThemeColorOption) -> some View {
        let isSelected = effectiveColor == option.hex
        return Button {
            HapticManager.selection()
            customColor = option.hex
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: option.hex))
                    .frame(width: 28, height: 28)
                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 2.5)
                        .frame(width: 28, height: 28)
                    Circle()
                        .stroke(Color(hex: option.hex), lineWidth: 1)
                        .frame(width: 34, height: 34)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 块3：日期 · 重复 · 提醒 · 备注（合并成一个卡片）

    private var dateReminderNoteSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("日期与提醒")
                .font(.holoCaption.bold())
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                // 日期选择行
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 28)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                }
                .padding(HoloSpacing.md)

                Divider().padding(.leading, HoloSpacing.lg + 28)

                // 每年重复
                toggleRow(icon: "arrow.clockwise", title: "每年重复", subtitle: "开启后自动计算下一个周年",
                          isOn: Binding(get: { repeatYearly }, set: { hasUserTouchedRepeat = true; repeatYearly = $0 }))

                Divider().padding(.leading, HoloSpacing.lg + 28)

                // 提醒开关
                toggleRow(icon: "bell.fill", title: "提醒", subtitle: "临近时推送通知", isOn: $reminderEnabled)

                // 提醒展开区域
                if reminderEnabled {
                    Divider().padding(.leading, HoloSpacing.lg + 28)

                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        HStack(spacing: HoloSpacing.sm) {
                            ForEach(AnniversaryReminderPreset.allCases, id: \.self) { preset in
                                reminderChip(preset)
                            }
                        }

                        toggleRow(icon: "checklist", title: "同步生成任务", subtitle: "在待办列表里创建一条提醒任务", isOn: $generateTask)
                    }
                    .padding(HoloSpacing.md)
                }

                Divider().padding(.leading, HoloSpacing.lg + 28)

                // 备注（合并进同一卡片底部）
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("备注")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    TextField("写下关于这个日子的故事…", text: $note, axis: .vertical)
                        .font(.holoBody)
                        .lineLimit(2...5)
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

            // 编辑模式下的删除按钮（与列表删除一致：确认 + 关联任务处理）
            if isEditMode {
                Button(role: .destructive) {
                    guard !isSaving else { return }
                    showDeleteAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("删除这个纪念日")
                    }
                    .font(.holoBody)
                    .foregroundColor(.holoError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HoloSpacing.md)
                    .background(Color.holoErrorLight)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .padding(.top, HoloSpacing.sm)
            }
        }
    }

    private func reminderChip(_ preset: AnniversaryReminderPreset) -> some View {
        let isSelected = reminderDaysBefore == preset.rawValue
        return Button {
            HapticManager.selection()
            reminderDaysBefore = preset.rawValue
        } label: {
            Text(preset.displayName)
                .font(.holoLabel)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(isSelected ? Color.holoPrimary : Color.holoBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 通用 Toggle 行

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(HoloSpacing.md)
    }

    // MARK: - 保存

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 统一退出入口：取消 / 右滑共用，有未保存修改时先确认
    private func requestDismiss() {
        if hasUnsavedChanges {
            showDismissAlert = true
        } else {
            dismiss()
        }
    }

    /// 是否有未保存的修改（对齐 AddHabitSheet 惯例）
    private var hasUnsavedChanges: Bool {
        if let item = editingAnniversary {
            // 编辑模式：与原始数据逐项对比（icon 回填规则见 populateIfEditing）
            let baseIcon = ["gift", "heart", "alarm", "flag"].contains(item.icon) ? nil : item.icon
            let baseColor = item.color != item.anniversaryType.defaultColor ? item.color : nil
            return title != item.title
                || !Calendar.current.isDate(date, inSameDayAs: item.date)
                || selectedType != item.anniversaryType
                || customColor != baseColor
                || customIcon != baseIcon
                || note != (item.note ?? "")
                || repeatYearly != item.repeatYearly
                || reminderEnabled != item.reminderEnabled
                || reminderDaysBefore != item.reminderDaysBefore
                || generateTask != item.generateTask
        }
        // 新增模式：输入过任何内容即视为有修改
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !note.isEmpty
            || customColor != nil
            || customIcon != nil
            || selectedType != .countdown
            || repeatYearly
            || reminderEnabled
    }

    /// 删除（软删进入回收站），可选同时软删已生成的关联任务 —— 与列表页删除行为一致
    private func performDelete(deleteTasks: Bool) {
        guard let item = editingAnniversary, !isSaving else { return }
        isSaving = true
        Task {
            if deleteTasks {
                await AnniversaryTaskGenerator.shared.deleteTasks(for: item.id)
            }
            try? await repository.softDeleteAnniversary(item)
            isSaving = false
            dismiss()
        }
    }

    private var effectiveColor: String {
        customColor ?? selectedType.defaultColor
    }

    private func save() {
        guard canSave else { return }
        guard !isSaving else { return }
        isSaving = true

        Task {
            do {
                if let item = editingAnniversary {
                    try await repository.updateAnniversary(
                        item,
                        title: title.trimmingCharacters(in: .whitespaces),
                        date: date,
                        type: selectedType,
                        icon: customIcon ?? selectedType.defaultEmoji,
                        // nil 在仓库层语义是「不修改」，编辑路径必须物化出最终值，
                        // 否则「恢复默认」（颜色/清空备注）永远存不进去
                        color: customColor ?? selectedType.defaultColor,
                        note: note,
                        isPinned: isPinned,
                        repeatYearly: repeatYearly,
                        reminderEnabled: reminderEnabled,
                        reminderDaysBefore: reminderDaysBefore,
                        generateTask: reminderEnabled && generateTask
                    )
                } else {
                    _ = try await repository.addAnniversary(
                        title: title.trimmingCharacters(in: .whitespaces),
                        date: date,
                        type: selectedType,
                        icon: customIcon,
                        color: customColor,
                        note: note.isEmpty ? nil : note,
                        isPinned: isPinned,
                        repeatYearly: repeatYearly,
                        reminderEnabled: reminderEnabled,
                        reminderDaysBefore: reminderDaysBefore,
                        generateTask: reminderEnabled && generateTask
                    )
                }
                HapticManager.success()
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                // 保存失败才弹全局提示（成功不弹，避免独立 window 拦截触摸）
                HoloToastCenter.shared.show("保存失败", type: .error)
            }
        }
    }

    // MARK: - 编辑模式回填

    private func populateIfEditing() {
        guard let item = editingAnniversary, !hasLoadedInitial else { return }
        hasLoadedInitial = true
        title = item.title
        date = item.date
        selectedType = item.anniversaryType
        customColor = item.color != item.anniversaryType.defaultColor ? item.color : nil
        // 老默认 SF Symbol（gift/heart/alarm/flag）视为「默认」，编辑保存后自然升级为类型默认 emoji；
        // 用户手选的 emoji 与其他自定义图标名原样保留
        customIcon = ["gift", "heart", "alarm", "flag"].contains(item.icon) ? nil : item.icon
        note = item.note ?? ""
        repeatYearly = item.repeatYearly
        hasUserTouchedRepeat = true
        reminderEnabled = item.reminderEnabled
        reminderDaysBefore = item.reminderDaysBefore
        generateTask = item.generateTask
        isPinned = item.isPinned
    }
}

// MARK: - 主题色选项

struct ThemeColorOption {
    let hex: String
    let name: String
}

private let themeColorOptions: [ThemeColorOption] = [
    ThemeColorOption(hex: "#F46D38", name: "暖橙"),
    ThemeColorOption(hex: "#EC4899", name: "玫粉"),
    ThemeColorOption(hex: "#60A5FA", name: "晴蓝"),
    ThemeColorOption(hex: "#C084FC", name: "紫罗兰"),
    ThemeColorOption(hex: "#22C55E", name: "生机绿"),
    ThemeColorOption(hex: "#F43F5E", name: "赤红"),
]
