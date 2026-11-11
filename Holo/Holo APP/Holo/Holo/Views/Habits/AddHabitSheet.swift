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
    /// 习惯描述草稿（上限 Habit.descriptionLimit，输入时截断）
    @State private var habitDescription: String = ""
    @State private var selectedType: HabitType = .checkIn
    @State private var selectedIcon: String = "checkmark.circle"
    @State private var selectedColor: String = Self.quickColors[0]
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
                    // 录入：名字（必填）+ 描述（选填）同一张卡
                    inputSection

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
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 24)
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
        // 内容收拢后不长占整屏：默认 680 档、可拖到全屏（§8.3 定高优先）
        .presentationDetents([.height(680), .large])
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
                || Habit.normalizedDescription(habitDescription) != habit.habitDescription
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
                || Habit.normalizedDescription(habitDescription) != nil
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
            habitDescription = habit.habitDescription ?? ""
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

    /// 录入卡：名字（唯一必填）+ 描述同一张卡、分隔线隔开——输入即所见，
    /// 不再放预览磁贴复读同一段文字（2026-11-03 东林真机「没对齐没美感」判读 TOP1）
    private var inputSection: some View {
        VStack(spacing: 0) {
            TextField(String(localized: "起个名字，如：早起、喝水"), text: $name)
                .holoText(.body)
                .foregroundColor(.holoToolText)
                .tint(Color.holoToolAction)
                .padding(.horizontal, 16)
                .frame(minHeight: 50, alignment: .leading)

            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.5))
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                // 习惯描述：满 Habit.descriptionLimit 个字就输不进去（Emoji、空格、英文都算 1 个字）。
                // 上限按最窄展示位算出：375pt 宽 iPhone 今天页大卡描述行 13pt 下可用 241pt，
                // 16 字（含至多 5 个 Emoji）一行放下；系统字号调大时换行，任何位置不截成「…」
                TextField(String(localized: "一句话，为什么开始（选填）"), text: $habitDescription)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
                    .tint(Color.holoToolAction)
                    .onChange(of: habitDescription) { _, newValue in
                        if newValue.count > Habit.descriptionLimit {
                            habitDescription = String(newValue.prefix(Habit.descriptionLimit))
                        }
                    }
                    .accessibilityIdentifier("habit.edit.description")
                Text(verbatim: "\(habitDescription.count)/\(Habit.descriptionLimit)")
                    .holoText(.metadata)
                    .monospacedDigit()
                    .foregroundColor(.holoToolTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46, alignment: .leading)
        }
        .editorCardBackground()
    }

    // MARK: - 记录方式（分段控件灰轨白块 §8.8.3；「想减少」= 记录方向的第四分支，同卡）

    /// 三档与存储类型的映射（selection 双字段）
    private var recordMethodIndex: Binding<Int> {
        Binding(
            get: {
                if selectedType == .checkIn { return 0 }
                return selectedAggregationType == .sum ? 1 : 2
            },
            set: { index in
                withAnimation(allowsMotion ? HoloAnimation.standard : nil) {
                    switch index {
                    case 0: selectedType = .checkIn; selectedAggregationType = .sum
                    case 1: selectedType = .numeric; selectedAggregationType = .sum
                    default: selectedType = .numeric; selectedAggregationType = .latest
                    }
                }
            }
        )
    }

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "你每天要记什么？"))
                .holoText(.sectionTitle)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)

            VStack(spacing: 0) {
                Picker(String(localized: "记录方式"), selection: recordMethodIndex) {
                    Text(String(localized: "做了没")).tag(0)
                    Text(String(localized: "数几次")).tag(1)
                    Text(String(localized: "记一个数")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityIdentifier("habit.edit.method")

                Rectangle()
                    .fill(Color.holoToolBorder.opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                badHabitRow
            }
            .editorCardBackground()
        }
    }

    private var badHabitRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "这是想减少的事"))
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Spacer()
                Toggle("", isOn: $isBadHabit)
                    .labelsHidden()
                    .tint(Color.holoError)
                    .scaleEffect(0.88)
                    .accessibilityLabel(Text(String(localized: "这是想减少的事")))
            }
            .frame(minHeight: 44)
            if isBadHabit {
                Text(String(localized: "记录「发生了」，超过目标会提醒你控制"))
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, isBadHabit ? 0 : 10)
        .animation(allowsMotion ? HoloAnimation.standard : nil, value: isBadHabit)
    }

    // MARK: - 外观卡（行 1 图标入口；行 2 色点均分整行 → 每点热区约 56pt）

    /// 外观行快捷色（色板前 5 色；全量 12 色在图标选择器底部）
    private static let quickColors: [String] = ["#3B76C9", "#D9662C", "#2FA360", "#8063CE", "#A87B0F"]

    private var appearanceSection: some View {
        VStack(spacing: 0) {
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
                .accessibilityLabel(Text(String(localized: "图标与颜色")))

                Button {
                    showIconPicker = true
                } label: {
                    Text(String(localized: "图标与颜色"))
                        .holoText(.body)
                        .foregroundColor(.holoToolText)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.5))
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            // 五色点均分行宽：每点热区 ≈ 行宽/5 ≈ 56pt（≥44 规范）
            HStack(spacing: 0) {
                ForEach(Self.quickColors, id: \.self) { color in
                    HabitQuickColorDot(color: color, isSelected: selectedColor == color) {
                        selectedColor = color
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
        }
        .editorCardBackground()
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
                        .holoText(.body)
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
                VStack(alignment: .leading, spacing: 16) {
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
            } else {
                // 开关开着但当前类型没填值（如刚切换记录方式）：如实标注，不再无声消失
                parts.append(String(localized: "目标未设"))
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
                .holoText(.metadata)
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
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                Spacer(minLength: 8)

                Picker("", selection: $dayEndHour) {
                    ForEach(Self.dayEndHourOptions, id: \.self) { hour in
                        // 0:00 不带「（默认）」后缀：左侧说明行已表达自然日语义，
                        // 后缀曾让菜单文案折行撑爆单行容器（2026-11-03 东林真机红框实锤）
                        Text(Self.dayEndText(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.holoToolText)
                .frame(minWidth: 52, alignment: .trailing)
                .lineLimit(1)
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
                .holoText(.metadata)
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
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)

            HabitReminderModePicker(mode: $reminderMode, time: $reminderTime)
        }
    }

    // MARK: - 频率选择

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("频率")
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)

            Picker(String(localized: "频率"), selection: $selectedFrequency) {
                ForEach(HabitFrequency.allCases) { freq in
                    Text(freq.displayName).tag(freq)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                    .tint(Color.holoToolAction)
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
                // 与数值型分支同口径：开关开着但次数无效时拦截报错，
                // 而不是静默 clear 掉既有目标（丢目标会连锁改变达标口径）
                if let tc, tc > 0 {
                    payload.targetCount = .set(tc)
                } else if habit.targetCountValue != nil {
                    saveErrorMessage = String(localized: "目标次数需要大于 0；或关闭目标")
                    isSaving = false
                    return
                }
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
            payload.habitDescription = Habit.normalizedDescription(habitDescription).map { .set($0) } ?? .clear
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
                    habitDescription: habitDescription,
                    aggregationType: selectedAggregationType,
                    isBadHabit: badHabit,
                    reminderMode: isCheckIn ? reminderMode : .follow,
                    reminderTime: reminderTimeComponents,
                    dayEndTime: dayEndTimeComponents
                )
                // 目标关联失败不回滚基础习惯：保留同一草稿 ID 只补关联（方案 §8.3）
                if goalSelection != nil {
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

// MARK: - 图标渲染适配器

/// 让表单里的图标字符串复用 HabitIconRenderable 的三分支渲染（emoji/自定义资产/SF Symbol）
private struct HabitPreviewIcon: HabitIconRenderable {
    let icon: String
    var isCustomIcon: Bool {
        UnifiedIconCatalog.isAssetIcon(icon)
    }
}

/// 编辑页统一卡片外观：16 圆角、ToolSurface 底、0.5 描边（全页一档，无杂值）
private extension View {
    func editorCardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(Color.holoToolSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - 色点（编辑卡与图标选择器 footer 共用）

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
            ZStack {
                Circle()
                    .fill(Color(hex: color))
                    .frame(width: 24, height: 24)
                    .scaleEffect(isSelected ? 1.1 : 1)
                // 选中外环：2pt 全不透明深灰（0.55 透明度在浅色卡上判读实锤不可见）
                Circle()
                    .stroke(Color.holoToolText.opacity(isSelected ? 1.0 : 0), lineWidth: 2)
                    .frame(width: 29, height: 29)
            }
            .frame(width: 44, height: 44)   // 热区 44pt（规范底线；编辑卡内由外层均分加宽到 ~56pt）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "颜色")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
