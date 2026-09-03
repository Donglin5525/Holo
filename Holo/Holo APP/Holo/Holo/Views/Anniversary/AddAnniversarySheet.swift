//
//  AddAnniversarySheet.swift
//  Holo
//
//  纪念日创建/编辑 · 三步「点亮」向导
//  ① 这是个什么日子（场景预设 + 名称）→ ② 哪一天（公历/农历）→ ③ 想怎么记住它（重复/提醒/备注）
//  顶部迷你预览卡全程实时跟随；新建保存后播放「已点亮」庆祝时刻。
//

import SwiftUI

struct AddAnniversarySheet: View {

    var editingAnniversary: Anniversary?

    @Environment(\.dismiss) private var dismiss
    private var repository: AnniversaryRepository { AnniversaryRepository.shared }

    // MARK: - 表单状态

    @State private var title: String = ""
    @State private var date: Date = Date().addingTimeInterval(60 * 60 * 24 * 30)
    @State private var selectedType: AnniversaryType = .anniversary
    @State private var customColor: String? = nil
    @State private var customIcon: String? = nil
    @State private var showIconPicker = false
    @State private var note: String = ""
    @State private var repeatYearly: Bool = true
    @State private var isLunar: Bool = false
    @State private var reminderEnabled: Bool = false
    @State private var reminderDaysBefore: Int16 = 3
    @State private var generateTask: Bool = true
    @State private var isPinned: Bool = false

    // MARK: - 向导状态

    private enum WizardStep: Int, CaseIterable {
        case scene = 0, date = 1, ritual = 2

        var title: String {
            switch self {
            case .scene: return String(localized: "这是个什么日子？")
            case .date: return String(localized: "哪一天？")
            case .ritual: return String(localized: "想怎么记住它？")
            }
        }

        var hint: String {
            switch self {
            case .scene: return String(localized: "场景会预设好配色、图标和重复方式")
            case .date: return String(localized: "选中的日子会实时出现在上方预览卡")
            case .ritual: return String(localized: "最后一步，Holo 会按你的方式守着这一天")
            }
        }
    }

    @State private var currentStep: WizardStep = .scene
    @State private var showCelebration = false
    @State private var showAppearanceOptions = false

    @State private var hasLoadedInitial = false
    @State private var hasUserTouchedRepeat = false
    @State private var isSaving = false
    @State private var showDismissAlert = false
    @State private var showDeleteAlert = false

    private var isEditMode: Bool { editingAnniversary != nil }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    miniPreviewCard
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.sm)

                    stepIndicator
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)

                    stepContent

                    footerBar
                }

                // 「点亮」庆祝时刻（仅新建）
                if showCelebration {
                    AnniversaryLitUpOverlay(
                        icon: effectiveIcon,
                        title: title.trimmingCharacters(in: .whitespaces),
                        dateText: previewDateText,
                        daysText: previewDaysLine,
                        tint: Color(hex: effectiveColor),
                        onDone: { dismiss() })
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .navigationTitle(isEditMode ? String(localized: "编辑纪念日") : String(localized: "新建纪念日"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "取消")) { requestDismiss() }
                        .foregroundColor(.holoTextSecondary)
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
        .alert(String(localized: "删除纪念日"), isPresented: $showDeleteAlert) {
            Button(String(localized: "删除纪念日及关联任务"), role: .destructive) {
                performDelete(deleteTasks: true)
            }
            Button(String(localized: "仅删除纪念日"), role: .destructive) {
                performDelete(deleteTasks: false)
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "这个纪念日可能已生成关联任务，你想如何处理？"))
        }
        // 无改动时保留系统下拉关闭；有改动时拦下并走 requestDismiss 的确认分流
        .interactiveDismissDisabled(hasUnsavedChanges || showCelebration)
        .sheetDismissGuard { requestDismiss() }
        .sheet(isPresented: $showIconPicker) {
            EmojiIconPickerSheet(currentIcon: effectiveIcon) { emoji in
                customIcon = emoji
            }
        }
    }

    // MARK: - 迷你预览卡（所见即所得）

    private var miniPreviewCard: some View {
        HStack(spacing: 12) {
            Group {
                if EmojiCatalog.isEmojiIcon(effectiveIcon) {
                    Text(effectiveIcon).font(.system(size: 21))
                } else {
                    Image(systemName: effectiveIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.22)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? String(localized: "给这个日子起个名字") : title)
                    .font(.system(size: 14.5, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(previewDateText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 0) {
                Text(previewDaysText)
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                Text(previewDaysUnit)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: effectiveColor).opacity(0.92), Color(hex: effectiveColor).opacity(0.42)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: Color(hex: effectiveColor).opacity(0.35), radius: 12, y: 6)
        .animation(.easeInOut(duration: 0.25), value: effectiveColor)
        .animation(.easeInOut(duration: 0.25), value: effectiveIcon)
    }

    // MARK: - 步骤指示

    private var stepIndicator: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(WizardStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= currentStep.rawValue
                              ? Color(hex: effectiveColor)
                              : Color.holoBorder)
                        .frame(height: 4)
                        .animation(.easeInOut(duration: 0.3), value: currentStep)
                }
            }

            HStack {
                Text(currentStep.title)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }

            HStack {
                Text(currentStep.hint)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                Spacer()
            }
        }
    }

    // MARK: - 步骤内容

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                switch currentStep {
                case .scene: sceneStep
                case .date: dateStep
                case .ritual: ritualStep
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 步骤 ①：场景 + 名称

    private var sceneStep: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 11) {
                ForEach(AnniversaryType.allCases, id: \.self) { type in
                    sceneCard(type)
                }
            }

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(String(localized: "名称"))
                    .font(.holoCaption.bold())
                    .foregroundColor(.holoTextSecondary)

                TextField(String(localized: "如：妈妈的生日"), text: $title)
                    .font(.holoBody)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoPrimary.opacity(title.isEmpty ? 0 : 0.3), lineWidth: 1))
            }

            // 配色与图标细调（场景预设已覆盖大多数场景，按需展开）
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showAppearanceOptions.toggle() }
                } label: {
                    HStack {
                        Text(String(localized: "自定义配色与图标"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                        Spacer()
                        Image(systemName: showAppearanceOptions ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAppearanceOptions {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        HStack(spacing: HoloSpacing.md) {
                            ForEach(themeColorOptions, id: \.hex) { option in
                                colorDot(option)
                            }
                            if customColor != nil {
                                Button(String(localized: "恢复默认")) { customColor = nil }
                                    .font(.system(size: 12))
                                    .foregroundColor(.holoPrimary)
                            }
                        }
                        iconRow
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
        }
    }

    private func sceneCard(_ type: AnniversaryType) -> some View {
        let isSelected = selectedType == type
        let tint = Color(hex: customColor == nil || selectedType != type ? type.defaultColor : effectiveColor)
        return Button {
            HapticManager.selection()
            selectedType = type
            if !hasUserTouchedRepeat {
                repeatYearly = type.defaultRepeatYearly
            }
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Text(type.defaultEmoji)
                        .font(.system(size: 27))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(tint)
                            .background(Circle().fill(Color.holoBackground).frame(width: 18, height: 18))
                    }
                }

                Text(type.displayName)
                    .font(.system(size: 14.5, weight: .heavy))
                    .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)

                Text(type.sceneHint)
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.09) : Color.holoCardBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.55) : Color.holoBorder.opacity(0.6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var effectiveIcon: String {
        customIcon ?? selectedType.defaultEmoji
    }

    private var iconRow: some View {
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
                .background(Circle().fill(Color(hex: effectiveColor).opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "图标"))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(customIcon == nil ? String(localized: "默认（按类型）") : String(localized: "已自定义"))
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

    // MARK: 步骤 ②：日期

    private var dateStep: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            // 大日期标签
            VStack(spacing: 6) {
                Text(dateMainText)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundColor(.holoTextPrimary)
                Text(dateSubText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.holoBorder, lineWidth: 1))

            // 公历/农历
            if repeatYearly || !hasUserTouchedRepeat {
                HStack(spacing: 10) {
                    calendarSegmentButton(title: String(localized: "公历"), isActive: !isLunar) {
                        isLunar = false
                    }
                    calendarSegmentButton(title: String(localized: "农历"), isActive: isLunar) {
                        isLunar = true
                    }
                    Spacer()
                    Text(isLunar
                         ? String(localized: "按农历年年重复 · 适合生日与传统节日")
                         : String(localized: "按公历年年重复"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            DatePicker(
                String(localized: "日期"),
                selection: $date,
                displayedComponents: .date)
            .datePickerStyle(.graphical)
            .tint(Color(hex: effectiveColor))
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
        }
    }

    private func calendarSegmentButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.selection()
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(isActive ? .white : .holoTextSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isActive ? Color(hex: effectiveColor) : Color.holoCardBackground))
                .overlay(Capsule().strokeBorder(Color.holoBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var dateMainText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private var dateSubText: AttributedString {
        var parts: [String] = []
        let weekday = DateFormatter().weekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]
        parts.append(weekday)
        parts.append(String(localized: "农历\(ChineseLunarCalendar.lunarDateText(of: date))"))
        let days = previewDaysFromSelection
        if days > 0 {
            parts.append(String(localized: "距今天还有 \(days) 天"))
        } else if days == 0 {
            parts.append(String(localized: "就是今天"))
        } else {
            parts.append(String(localized: "将从那天开始累计"))
        }
        let text = parts.joined(separator: " · ")
        var attributed = AttributedString(text)
        if days >= 0, let range = attributed.range(of: parts.last ?? "") {
            attributed[range].foregroundColor = Color(hex: effectiveColor)
            attributed[range].font = .system(size: 12, weight: .heavy)
        }
        return attributed
    }

    /// 未填名称/未到重复步骤时，日期与今天的差（正=未来）
    private var previewDaysFromSelection: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: date)
        return (calendar.dateComponents([.day], from: today, to: day).day ?? 0)
    }

    // MARK: 步骤 ③：重复 / 提醒 / 备注

    private var ritualStep: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            VStack(spacing: 0) {
                toggleRow(icon: "arrow.clockwise",
                          title: String(localized: "每年重复"),
                          subtitle: isLunarRepeatHint,
                          isOn: Binding(
                            get: { repeatYearly },
                            set: { hasUserTouchedRepeat = true; repeatYearly = $0 }))

                Divider().padding(.leading, HoloSpacing.lg + 28)

                toggleRow(icon: "bell.fill",
                          title: String(localized: "提醒我"),
                          subtitle: String(localized: "临近时推送通知"),
                          isOn: $reminderEnabled.animation(.easeInOut(duration: 0.2)))

                if reminderEnabled {
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        HStack(spacing: HoloSpacing.sm) {
                            ForEach(AnniversaryReminderPreset.allCases, id: \.self) { preset in
                                reminderChip(preset)
                            }
                        }

                        toggleRow(icon: "checklist",
                                  title: String(localized: "同步生成任务"),
                                  subtitle: String(localized: "在待办列表里创建一条提醒任务"),
                                  isOn: $generateTask)
                    }
                    .padding(HoloSpacing.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text(String(localized: "一句备注 · 未来翻到这页时会心一笑的那种"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                TextField(String(localized: "写下关于这个日子的故事…"), text: $note, axis: .vertical)
                    .font(.holoBody)
                    .lineLimit(2...5)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }

            // 编辑模式下的删除按钮（与列表删除一致：确认 + 关联任务处理）
            if isEditMode {
                Button(role: .destructive) {
                    guard !isSaving else { return }
                    showDeleteAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text(String(localized: "删除这个纪念日"))
                    }
                    .font(.holoBody)
                    .foregroundColor(.holoError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HoloSpacing.md)
                    .background(Color.holoErrorLight)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
            }
        }
    }

    /// 农历重复时副标题换文案
    private var isLunarRepeatHint: String {
        isLunar
            ? String(localized: "按农历年年重复（农历\(ChineseLunarCalendar.lunarDateText(of: date))）")
            : String(localized: "开启后自动计算下一个周年")
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
                .background(isSelected ? Color(hex: effectiveColor) : Color.holoBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部操作条

    private var footerBar: some View {
        HStack(spacing: 11) {
            Button {
                guard let previous = WizardStep(rawValue: currentStep.rawValue - 1) else {
                    requestDismiss()
                    return
                }
                withAnimation(.easeInOut(duration: 0.22)) { currentStep = previous }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(currentStep == .scene ? .holoTextSecondary.opacity(0.5) : .holoTextSecondary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.holoCardBackground))
            }
            .disabled(currentStep == .scene)

            Button {
                guard let next = WizardStep(rawValue: currentStep.rawValue + 1) else {
                    save()
                    return
                }
                withAnimation(.easeInOut(duration: 0.22)) { currentStep = next }
            } label: {
                Group {
                    if currentStep == .ritual {
                        if isSaving {
                            ProgressView().tint(.white).controlSize(.small)
                        } else if isEditMode {
                            Text(String(localized: "保存"))
                        } else {
                            Text(String(localized: "✨ 点亮这个日子"))
                        }
                    } else {
                        Text(String(localized: "下一步"))
                    }
                }
                .font(.system(size: 15.5, weight: .heavy))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(canSave ? effectiveButtonColor : Color.holoTextSecondary.opacity(0.4)))
            }
            .disabled(!canSave || isSaving)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, 6)
        .padding(.bottom, 18)
    }

    private var effectiveButtonColor: Color {
        Color(hex: effectiveColor)
    }

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
                .tint(Color(hex: effectiveColor))
        }
        .padding(HoloSpacing.md)
    }

    // MARK: - 预览卡数据

    private var previewDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        var text = formatter.string(from: date)
        if repeatYearly {
            text += isLunar
                ? String(localized: " · 农历每年")
                : String(localized: " · 每年")
        }
        return text
    }

    /// 预览卡右侧大数字
    private var previewDaysText: String {
        if !repeatYearly {
            return "\(abs(previewDaysFromSelection))"
        }
        // 每年重复：模拟实体的 nextOccurrenceDate 推算
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let next: Date
        if isLunar {
            next = ChineseLunarCalendar.nextLunarOccurrence(of: date, onOrAfter: today)
        } else {
            let comps = calendar.dateComponents([.month, .day], from: date)
            let year = calendar.component(.year, from: today)
            var thisYear = DateComponents(year: year, month: comps.month, day: comps.day)
            var candidate = calendar.date(from: thisYear) ?? date
            if calendar.startOfDay(for: candidate) < today {
                thisYear.year = year + 1
                candidate = calendar.date(from: thisYear) ?? candidate
            }
            next = candidate
        }
        return "\(max(calendar.dateComponents([.day], from: today, to: next).day ?? 0, 0))"
    }

    private var previewDaysUnit: String {
        if previewDaysFromSelection == 0 && !repeatYearly {
            return String(localized: "就是今天")
        }
        return repeatYearly || previewDaysFromSelection >= 0
            ? String(localized: "天后")
            : String(localized: "天 · 累计")
    }

    private var previewDaysLine: String {
        if previewDaysFromSelection >= 0 {
            return String(localized: "距今天还有 \(previewDaysText) 天")
        } else {
            return String(localized: "将从那天开始累计")
        }
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
                || isLunar != item.isLunar
                || reminderEnabled != item.reminderEnabled
                || reminderDaysBefore != item.reminderDaysBefore
                || generateTask != item.generateTask
        }
        // 新增模式：输入过任何内容即视为有修改
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !note.isEmpty
            || customColor != nil
            || customIcon != nil
            || selectedType != .anniversary
            || repeatYearly != true
            || isLunar
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
        guard canSave, !isSaving else { return }
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
                        isLunar: isLunar,
                        reminderEnabled: reminderEnabled,
                        reminderDaysBefore: reminderDaysBefore,
                        generateTask: reminderEnabled && generateTask
                    )
                    HapticManager.success()
                    isSaving = false
                    dismiss()
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
                        isLunar: repeatYearly && isLunar,
                        reminderEnabled: reminderEnabled,
                        reminderDaysBefore: reminderDaysBefore,
                        generateTask: reminderEnabled && generateTask
                    )
                    isSaving = false
                    // 「点亮」庆祝时刻，看完关闭
                    withAnimation(.easeIn(duration: 0.25)) { showCelebration = true }
                }
            } catch {
                isSaving = false
                // 保存失败才弹全局提示（成功不弹，避免独立 window 拦截触摸）
                HoloToastCenter.shared.show(String(localized: "保存失败"), type: .error)
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
        isLunar = item.isLunar
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
    ThemeColorOption(hex: "#F46D38", name: String(localized: "暖橙")),
    ThemeColorOption(hex: "#EC4899", name: String(localized: "玫粉")),
    ThemeColorOption(hex: "#60A5FA", name: String(localized: "晴蓝")),
    ThemeColorOption(hex: "#C084FC", name: String(localized: "紫罗兰")),
    ThemeColorOption(hex: "#22C55E", name: String(localized: "生机绿")),
    ThemeColorOption(hex: "#F43F5E", name: String(localized: "赤红")),
]

// MARK: - 场景话术

extension AnniversaryType {
    /// 创建向导场景卡的一句话
    var sceneHint: String {
        switch self {
        case .birthday: return String(localized: "会替你记着 TA 的岁数")
        case .anniversary: return String(localized: "每年的这一天都算数")
        case .countdown: return String(localized: "等着它到来的那天")
        case .milestone: return String(localized: "见证达成的时刻")
        }
    }
}
