//
//  AddHabitSheet.swift
//  Holo
//
//  新建/编辑习惯弹层（2026-10-18 减法改版）
//  壳走 HoloSheetScaffold；首屏只做「名字 + 记录方式」两个决定，
//  图标颜色走外观行快捷点 + 图标选择器，其余配置收进「更多设置」折叠区。
//  生命周期操作（暂停/归档/删除）已移交今天页长按菜单与概览弹层菜单。
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

/// 新建习惯表单
struct AddHabitSheet: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "AddHabitSheet")

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 交互动效灰度开关（与系统 Reduce Motion 相与，同 HoloActionStyle 口径）
    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    private var allowsMotion: Bool { motionEnabled && !reduceMotion }

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
    @State private var isBadHabit = false

    // 打卡提醒（仅打卡型；solo 模式的时刻，默认 09:00）
    @State private var reminderMode: HabitReminderMode = .follow
    @State private var reminderTime: Date = Self.defaultReminderTime

    // 每日结算时间（整点；0 = 凌晨 0 点按自然日；结算前的打卡算前一天）
    @State private var dayEndHour: Int = 0

    @State private var showIconPicker: Bool = false
    @State private var isSaving: Bool = false

    // 目标三态（方案 §8.2/§12.4）：目标关闭 = 编辑模式提交 clear，不能被误解释为「不更新」
    @State private var targetEnabled: Bool = false
    // 关联目标（真实 Goal 关系，非名称字符串）
    @State private var goalSelection: Goal? = nil
    @State private var initialGoalId: UUID? = nil
    @State private var showGoalPicker: Bool = false
    // 「更多设置」单一折叠区（频率/目标/提醒/关联）
    @State private var expandedMoreSettings = false

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
        HoloSheetScaffold(
            title: isEditing ? String(localized: "编辑习惯") : String(localized: "新建习惯"),
            onClose: {
                if hasUnsavedChanges {
                    showDismissAlert = true
                } else {
                    dismiss()
                }
            },
            primaryTitle: String(localized: "保存"),
            primaryAction: { saveHabit() },
            primaryDisabled: !canSave || isSaving
        ) {
            ScrollView {
                VStack(spacing: 16) {
                    // 名称：第一个必要决定（下方磁贴实时预览成型的习惯）
                    nameAndPreviewSection

                    // 记录方式：第二个必要决定（打卡/计数/测量，方案 §8.1）
                    methodSection

                    // 外观：图标 + 快捷色点
                    appearanceSection

                    // 更多设置：频率/目标/提醒/关联目标
                    moreSettingsSection

                    // 编辑模式且类型有改动：预告历史记录的转换方式（复用既有幂等桥接）
                    if let habit = editingHabit,
                       selectedType != habit.habitType || selectedAggregationType != habit.habitAggregationType {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                            Text(String(localized: "保存后历史记录会自动转换，可随时切回"))
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

                    // 保存失败：表单内显示原因与重试，输入不清空不关闭（方案 §8.3）
                    if let saveErrorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 13))
                            Text(saveErrorMessage)
                        }
                        .font(.holoCaption)
                        .foregroundColor(.holoToolError)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.sm)
                                .fill(Color.holoError.opacity(0.08))
                        )
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
            }
        }
        .onAppear {
            loadEditingData()
        }
        .sheet(isPresented: $showIconPicker) {
            UnifiedIconPickerSheet(currentIcon: selectedIcon, onSelect: { selectedIcon = $0 }) {
                HabitIconColorFooter(selectedColor: $selectedColor)
            }
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
                || dayEndHour != Int(habit.dayEndHour)

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

            if habit.isCheckInType {
                reminderMode = habit.habitReminderMode
                var comps = DateComponents()
                comps.hour = Int(habit.reminderHour)
                comps.minute = Int(habit.reminderMinute)
                reminderTime = Calendar.current.date(from: comps) ?? Self.defaultReminderTime
            }
            dayEndHour = Int(habit.dayEndHour)

            // 目标三态初始值（数值型 targetValue 优先，历史 targetCount 兜底展示）
            targetEnabled = habit.targetValueDouble != nil || habit.targetCountValue != nil
            initialGoalId = habit.goal?.id
            goalSelection = habit.goal
            // 「更多设置」新建/编辑统一默认收起，现值由折叠头摘要呈现
        } else if let draft = prefill {
            name = draft.name
            selectedIcon = draft.icon
            selectedColor = draft.color
        }
    }

    // MARK: - 名称输入 + 活预览磁贴

    private var nameAndPreviewSection: some View {
        VStack(spacing: 8) {
            TextField(String(localized: "起个名字，如：早起、喝水"), text: $name)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .tint(Color.holoToolAction)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                        .fill(Color.holoToolSurface)
                )

            HabitPreviewTile(name: name, icon: selectedIcon, color: selectedColor)
        }
    }

    // MARK: - 记录方式（三卡，P2 白话化：技术词翻译成用户动词）

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "你每天要记什么？"))
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            VStack(spacing: 8) {
                methodCard(.checkIn, .sum,
                           title: String(localized: "做了没"),
                           subtitle: String(localized: "打了勾就算完成，如：冥想、跑步"),
                           icon: "checkmark")
                methodCard(.numeric, .sum,
                           title: String(localized: "数几次"),
                           subtitle: String(localized: "做了就 +1，如：喝水 8 杯"),
                           icon: "number")
                methodCard(.numeric, .latest,
                           title: String(localized: "记一个数"),
                           subtitle: String(localized: "每天记一个数字，如：体重 75"),
                           icon: "scalemass")
            }

            badHabitRow
        }
    }

    /// 记录方式卡：白卡未选中；选中 = 主色淡底 + 描边 + 说明行 + 右上勾弹性蹦入
    private func methodCard(_ type: HabitType, _ aggregation: HabitAggregationType,
                            title: String, subtitle: String, icon: String) -> some View {
        let isSelected = selectedType == type && selectedAggregationType == aggregation
        return Button {
            withAnimation(allowsMotion ? HoloAnimation.snappy : nil) {
                selectedType = type
                selectedAggregationType = aggregation
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    if isSelected {
                        Text(subtitle)
                            .font(.holoCaption)
                            .foregroundColor(.holoToolTextSecondary)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                        .padding(.top, 12)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                    .fill(isSelected
                          ? Color.holoPrimary.opacity(Color.habitTileTintOpacity(colorScheme))
                          : Color.holoToolSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                    .strokeBorder(isSelected ? Color.holoPrimary.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 坏习惯行（P2 白话化：从三态选择降为一行小开关，不占决策位）

    private var badHabitRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "这是想减少的事"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                Toggle("", isOn: $isBadHabit)
                    .labelsHidden()
                    .tint(Color.holoError)
                    .scaleEffect(0.82)
            }
            if isBadHabit {
                Text(String(localized: "记录「发生了」，超过目标会提醒你控制"))
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                .fill(isBadHabit ? Color.holoError.opacity(0.05) : Color.holoToolSurface)
        )
        .animation(allowsMotion ? HoloAnimation.standard : nil, value: isBadHabit)
    }

    // MARK: - 外观行（图标入口 + 5 个快捷色点）

    /// 外观行快捷色（色板前 5 色；全量 12 色在图标选择器底部）
    private static let quickColors: [String] = ["#3B76C9", "#D9662C", "#2FA360", "#8063CE", "#A87B0F"]

    private var appearanceSection: some View {
        HStack(spacing: 12) {
            Button {
                showIconPicker = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(hex: selectedColor).opacity(colorScheme == .dark ? 0.20 : 0.12))
                    if EmojiCatalog.isEmojiIcon(selectedIcon) {
                        Text(selectedIcon)
                            .font(.system(size: 18))
                    } else {
                        HabitPreviewIcon(icon: selectedIcon).iconImage(size: 20)
                            .foregroundColor(Color(hex: selectedColor))
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Button {
                showIconPicker = true
            } label: {
                Text(String(localized: "图标与颜色"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoToolText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                ForEach(Self.quickColors, id: \.self) { color in
                    HabitQuickColorDot(color: color, isSelected: selectedColor == color) {
                        selectedColor = color
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                .fill(Color.holoToolSurface)
        )
    }

    // MARK: - 「更多设置」单一折叠区（频率 · 目标 · 提醒 · 关联）

    private var moreSettingsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(allowsMotion ? HoloAnimation.standard : nil) {
                    expandedMoreSettings.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(String(localized: "更多设置"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoToolText)
                    Spacer(minLength: 8)
                    Text(moreSettingsSummary)
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Image(systemName: expandedMoreSettings ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedMoreSettings {
                VStack(alignment: .leading, spacing: 14) {
                    frequencySection
                    targetSection
                    if selectedType == .checkIn {
                        reminderSection
                    }
                    dayEndSection
                    goalLinkSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
    }

    /// 折叠头摘要：频率 · 目标 · 提醒/结算/关联
    private var moreSettingsSummary: String {
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
        if selectedType == .checkIn {
            parts.append(reminderMode.displayName)
        }
        if dayEndHour != 0 {
            parts.append(String(localized: "\(Self.dayEndText(dayEndHour)) 结算"))
        }
        if goalSelection != nil {
            parts.append(String(localized: "已关联目标"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 每日结算时间

    /// 可选的结算整点：0（自然日）～12 点。下午以后结算没有生活场景，不开放
    private static let dayEndHourOptions = Array(0...12)

    private static func dayEndText(_ hour: Int) -> String {
        HabitDayAttribution.displayText(hour: hour, minute: 0)
    }

    private var dayEndSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每日结算时间")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            HStack(spacing: 10) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(dayEndHour == 0 ? .holoToolTextSecondary : .holoPrimary)

                Text(dayEndHour == 0
                     ? String(localized: "凌晨 0 点，按自然日")
                     : String(localized: "\(Self.dayEndText(dayEndHour)) 前的记录算前一天"))
                    .font(.holoCaption)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Picker("", selection: $dayEndHour) {
                    ForEach(Self.dayEndHourOptions, id: \.self) { hour in
                        Text(hour == 0 ? String(localized: "0:00（默认）") : Self.dayEndText(hour))
                            .tag(hour)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.holoToolText)
                .accessibilityIdentifier("habit.edit.dayEnd")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                    .fill(Color.holoToolInset)
            )
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
                                RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                                    .fill(selectedFrequency == freq ? Color.holoPrimary : Color.holoToolInset)
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
                // 编辑已有目标的习惯且开关被关：明示保存后果
                if let habit = editingHabit,
                   habit.targetValueDouble != nil || habit.targetCountValue != nil {
                    Text(String(localized: "保存后将清除现有目标"))
                        .font(.holoCaption)
                        .foregroundColor(.holoToolTextSecondary.opacity(0.8))
                }
            } else if selectedType == .checkIn {
                HStack(spacing: 8) {
                    TextField("目标次数", text: $targetCount)
                        .font(.holoBody)
                        #if canImport(UIKit)
                        .keyboardType(.numberPad)
                        #endif
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
                        #if canImport(UIKit)
                        .keyboardType(.decimalPad)
                        #endif
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

    // MARK: - 保存习惯

    private func saveHabit() {
        guard canSave else { return }
        isSaving = true
        saveErrorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tc = targetEnabled ? Int(targetCount) : nil
        let tv = targetEnabled ? Double(targetValue) : nil
        let u = targetEnabled && !unit.isEmpty ? unit : nil
        let badHabit = isBadHabit
        let calendar = Calendar.current
        // 打卡提醒仅打卡型有意义；数值型不参与提醒（方案 §6.3）
        let isCheckIn = selectedType == .checkIn
        let reminderTimeComponents = (
            hour: calendar.component(.hour, from: reminderTime),
            minute: calendar.component(.minute, from: reminderTime)
        )
        let dayEndTimeComponents = (hour: dayEndHour, minute: 0)

        // 编辑模式：三态字段一次用户意图完整提交（方案 §8.3/§12.4）
        if let habit = editingHabit {
            var payload = HabitEditPayload(
                name: trimmedName, icon: selectedIcon, color: selectedColor,
                type: selectedType, aggregationType: selectedAggregationType,
                frequency: selectedFrequency, isBadHabit: badHabit,
                reminderMode: isCheckIn ? reminderMode : .follow,
                reminderTime: reminderTimeComponents,
                dayEndTime: dayEndTimeComponents
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
                    reminderTime: reminderTimeComponents,
                    dayEndTime: dayEndTimeComponents
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

// MARK: - 活预览磁贴

/// 名称输入下方的只读预览磁贴：对照 HabitTileView 未完成态画法
/// （纸感卡 + 淡底 chip + 右上空心环），名字/图标/颜色实时跟随表单。
private struct HabitPreviewTile: View {
    let name: String
    let icon: String
    let color: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    private var allowsMotion: Bool { motionEnabled && !reduceMotion }

    private var habitColor: Color { Color(hex: color) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        HStack(spacing: 8) {
            iconChip
            if !trimmedName.isEmpty {
                Text(name)
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 尾部安全距离：长名不贴右上空心环
                    .padding(.trailing, 26)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 36, alignment: .center)
        .overlay(alignment: .topTrailing) {
            // 未完成态空心环（对照 HabitTileView）
            Circle()
                .strokeBorder(Color.holoToolTextSecondary.opacity(0.45), lineWidth: 1.6)
                .frame(width: 21, height: 21)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.tile, style: .continuous)
                .strokeBorder(Color.holoToolBorder, lineWidth: 1)
        )
        // 换色柔和过渡；名字变化不加动画
        .animation(allowsMotion ? HoloAnimation.standard : nil, value: color)
    }

    /// 32×32 淡底 chip：习惯色 8%/16% 底 + 习惯色图标（emoji 原色直出）
    private var iconChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(habitColor.opacity(Color.habitTileTintOpacity(colorScheme)))

            Group {
                if EmojiCatalog.isEmojiIcon(icon) {
                    Text(icon)
                        .font(.system(size: 17))
                } else {
                    HabitPreviewIcon(icon: icon).iconImage(size: 17)
                        .foregroundColor(habitColor)
                }
            }
            .id(icon)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .frame(width: 32, height: 32)
        .animation(allowsMotion ? HoloAnimation.snappy : nil, value: icon)
    }
}

// MARK: - 快捷色点

/// 外观行 / 图标选择器共用的 24pt 色点：选中 = 1.17 弹性放大 + 白内环 + 同色外晕
private struct HabitQuickColorDot: View {
    let color: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    private var allowsMotion: Bool { motionEnabled && !reduceMotion }

    var body: some View {
        Button {
            if allowsMotion {
                withAnimation(HoloAnimation.snappy) { action() }
            } else {
                action()
            }
        } label: {
            Circle()
                .fill(Color(hex: color))
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .stroke(Color.holoToolSurface, lineWidth: isSelected ? 2 : 0)
                )
                .overlay(
                    Circle()
                        .stroke(Color(hex: color).opacity(0.3), lineWidth: isSelected ? 1 : 0)
                        .padding(-1)
                )
                .scaleEffect(isSelected ? 1.17 : 1)
                .animation(allowsMotion ? HoloAnimation.snappy : nil, value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 图标渲染适配器

/// 让表单里的图标字符串复用 HabitIconRenderable 的三分支渲染（emoji/自定义资产/SF Symbol）
private struct HabitPreviewIcon: HabitIconRenderable {
    let icon: String
    var isCustomIcon: Bool {
        UnifiedIconCatalog.isAssetIcon(icon)
    }
}

// MARK: - 选择器底部色点行

/// 统一图标选择弹层的常驻 footer：全量 12 色点，兜住外观行只摆 5 色的覆盖缺口（换色不关弹层）
private struct HabitIconColorFooter: View {
    @Binding var selectedColor: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "颜色"))
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(HabitColorPresets.colors, id: \.self) { color in
                        HabitQuickColorDot(color: color, isSelected: selectedColor == color) {
                            selectedColor = color
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, 10)
        .padding(.bottom, HoloSpacing.sm)
        .background(Color.holoToolBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}

// MARK: - Preview

#Preview {
    AddHabitSheet()
}
