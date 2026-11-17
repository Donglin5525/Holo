//
//  GoalFormPickerSheets.swift
//  Holo
//
//  目标表单专属 Holo 定制选择弹层家族（HoloSheetScaffold）：
//  - GoalDeadlinePickerSheet：快捷期限芯片 + Holo 自绘月历网格（彻底替代系统灰色 DatePicker）
//  - GoalDataSourcePickerSheet：统一的数据来源选择（同步数值习惯 / 关联账本 / 手动更新）
//  - GoalLedgerScopePickerSheet：账本范围/账户选择（展示账户图标、余额与口径）
//  - GoalNumericHabitPickerSheet：数值习惯选择（统一 habit.iconImage 渲染 Emoji/图标）
//

import SwiftUI

// MARK: - Holo 定制截止期限选择卡

struct GoalDeadlinePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var deadlineText: String?

    @State private var displayMonth: Date
    @State private var selectedDate: Date?

    private let todayStart = Date().startOfDay

    init(deadlineText: Binding<String?>) {
        self._deadlineText = deadlineText
        let initial: Date? = {
            guard let text = deadlineText.wrappedValue, !text.isEmpty else { return nil }
            return GoalEditForm.parseDeadlineText(text).startOfDay
        }()
        self._selectedDate = State(initialValue: initial)
        self._displayMonth = State(initialValue: (initial ?? Date()).startOfMonth)
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "截止期限"),
            onClose: { dismiss() },
            primaryTitle: String(localized: "确定"),
            primaryAction: { applyAndDismiss() },
            primaryActionColor: GoalJourneyStyle.action,
            footerBackground: GoalJourneyStyle.sheetFooterCream
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    quickPresetsRow
                    calendarCard
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .presentationDetents([.height(520), .large])
    }

    private var quickPresetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                HoloFilterChip(
                    title: String(localized: "不设期限"),
                    iconColor: GoalJourneyStyle.action,
                    isSelected: selectedDate == nil
                ) {
                    selectedDate = nil
                    deadlineText = nil
                    dismiss()
                }
                .accessibilityIdentifier("goal-deadline-clear")

                HoloFilterChip(
                    title: String(localized: "1个月后"),
                    iconColor: GoalJourneyStyle.action,
                    isSelected: matchesDate(GoalEditForm.defaultDeadline(from: Date()))
                ) {
                    let target = GoalEditForm.defaultDeadline(from: Date()).startOfDay
                    selectedDate = target
                    displayMonth = target.startOfMonth
                }
                .accessibilityIdentifier("goal-deadline-1m")

                HoloFilterChip(
                    title: String(localized: "3个月后"),
                    iconColor: GoalJourneyStyle.action,
                    isSelected: matchesDate(Date().addingDays(90))
                ) {
                    let target = Date().addingDays(90).startOfDay
                    selectedDate = target
                    displayMonth = target.startOfMonth
                }

                HoloFilterChip(
                    title: String(localized: "今年底"),
                    iconColor: GoalJourneyStyle.action,
                    isSelected: matchesDate(GoalEditForm.endOfCurrentYear(from: Date()))
                ) {
                    let target = GoalEditForm.endOfCurrentYear(from: Date()).startOfDay
                    selectedDate = target
                    displayMonth = target.startOfMonth
                }
            }
        }
    }

    private var calendarCard: some View {
        let days = CalendarGridGenerator.generateGrid(for: displayMonth)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let calendar = Calendar.current

        return VStack(spacing: HoloSpacing.md) {
            HStack {
                Button {
                    displayMonth = displayMonth.addingMonths(-1).startOfMonth
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(width: 36, height: 36)
                        .background(Color.holoToolInset, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(CalendarDateFormatter.monthTitle(for: displayMonth))
                    .goalJourneyText(.row)
                    .foregroundStyle(Color.holoToolText)

                Spacer()

                Button {
                    displayMonth = displayMonth.addingMonths(1).startOfMonth
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(width: 36, height: 36)
                        .background(Color.holoToolInset, in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                ForEach(CalendarDateFormatter.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .goalJourneyText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let isCurrentMonth = day.isSameMonth(as: displayMonth)
                    let isPast = day.startOfDay < todayStart
                    let isSelected = selectedDate.map { $0.isSameDay(as: day) } ?? false
                    let isDisabled = isPast && !isSelected

                    Button {
                        selectedDate = day.startOfDay
                        displayMonth = day.startOfMonth
                    } label: {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .foregroundStyle(
                                isSelected ? Color.holoToolOnAction
                                : (isCurrentMonth && !isDisabled ? Color.holoToolText : Color.holoToolTextSecondary.opacity(0.4))
                            )
                            .background(
                                Circle()
                                    .fill(isSelected ? GoalJourneyStyle.action : (day.isToday ? Color.holoToolInset : Color.clear))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                }
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func matchesDate(_ date: Date) -> Bool {
        guard let selectedDate else { return false }
        return selectedDate.isSameDay(as: date)
    }

    private func applyAndDismiss() {
        deadlineText = selectedDate.map { GoalEditForm.formatDeadline($0) }
        dismiss()
    }
}

// MARK: - 统一数据来源选择弹窗（达标/累计：选同步习惯、关联账户或手动）

struct GoalDataSourcePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goalKind: GoalKind
    let habits: [Habit]
    let accounts: [Account]
    @Binding var metricSource: GoalMetricSource
    @Binding var selectedHabitId: UUID?
    @Binding var ledgerScope: GoalLedgerScopePayload?
    var healthMetricKind: Binding<GoalHealthMetricKind?> = .constant(nil)
    let onPickedAccount: (GoalLedgerScopePayload) -> Void

    var body: some View {
        HoloSheetScaffold(
            title: goalKind == .target ? String(localized: "怎么更新当前数值") : String(localized: "数据来源"),
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    sectionTitle(String(localized: "自动同步习惯"))
                    if habits.isEmpty {
                        emptyHintCard(String(localized: "还没有数值型习惯，可在「习惯」里新建后回来绑定"))
                    } else {
                        ForEach(habits.renderable, id: \.id) { habit in
                            let isSelected = metricSource == .habit && selectedHabitId == habit.id
                            let mode = habit.isCountType ? String(localized: "每天累加") : String(localized: "同步最新数值")
                            let unit = habit.unitText.isEmpty ? "" : " · \(habit.unitText)"
                            Button {
                                metricSource = .habit
                                selectedHabitId = habit.id
                                dismiss()
                            } label: {
                                HStack(spacing: HoloSpacing.md) {
                                    habitBadge(habit, isSelected: isSelected)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(habit.name)
                                            .goalJourneyText(.row)
                                            .foregroundStyle(Color.holoToolText)
                                            .lineLimit(1)
                                        Text(mode + unit)
                                            .goalJourneyText(.metadata)
                                            .foregroundStyle(Color.holoToolTextSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    if isSelected {
                                        selectedCheck
                                    }
                                }
                                .padding(HoloSpacing.md)
                                .holoSurface()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HoloPressStyle())
                        }
                    }

                    sectionTitle(String(localized: "从苹果健康自动同步"))
                    ForEach(GoalHealthMetricKind.allCases.filter {
                        goalKind == .target ? $0.isLatestSample : !$0.isLatestSample
                    }) { kind in
                        let isSelected = metricSource == .healthKit && healthMetricKind.wrappedValue == kind
                        Button {
                            metricSource = .healthKit
                            healthMetricKind.wrappedValue = kind
                            selectedHabitId = nil
                            ledgerScope = nil
                            dismiss()
                        } label: {
                            HStack(spacing: HoloSpacing.md) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolError)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        Circle().fill(isSelected ? GoalJourneyStyle.action.opacity(0.12) : Color.holoToolInset)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.displayName)
                                        .goalJourneyText(.row)
                                        .foregroundStyle(Color.holoToolText)
                                    Text("苹果健康 · \(kind.defaultUnit) · \(kind.isLatestSample ? "取最新观测" : "自动累计")")
                                        .goalJourneyText(.metadata)
                                        .foregroundStyle(Color.holoToolTextSecondary)
                                }
                                Spacer(minLength: 8)
                                if isSelected {
                                    selectedCheck
                                }
                            }
                            .padding(HoloSpacing.md)
                            .holoSurface()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoloPressStyle())
                    }

                    sectionTitle(String(localized: "自己记在目标里"))
                    Button {
                        metricSource = .manual
                        selectedHabitId = nil
                        dismiss()
                    } label: {
                        HStack(spacing: HoloSpacing.md) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(metricSource == .manual ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle().fill(metricSource == .manual ? GoalJourneyStyle.action.opacity(0.12) : Color.holoToolInset)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("在目标里手动更新")
                                    .goalJourneyText(.row)
                                    .foregroundStyle(Color.holoToolText)
                                Text("不关联其他模块，想记时在目标详情里填数")
                                    .goalJourneyText(.metadata)
                                    .foregroundStyle(Color.holoToolTextSecondary)
                            }
                            Spacer(minLength: 8)
                            if metricSource == .manual {
                                selectedCheck
                            }
                        }
                        .padding(HoloSpacing.md)
                        .holoSurface()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoloPressStyle())

                    if !accounts.isEmpty {
                        sectionTitle(String(localized: "自动同步账户"))
                        ForEach(accounts.renderable, id: \.id) { account in
                            let scope = GoalLedgerScopePayload(
                                kind: goalKind == .cumulative ? .accountDelta : .accountBalance,
                                accountID: account.id
                            )
                            let isSelected = metricSource == .ledger && ledgerScope == scope
                            let balance = FinanceRepository.shared.getAccountBalance(account)
                            let mode = goalKind == .cumulative ? String(localized: "净增加") : String(localized: "当前余额")
                            Button {
                                metricSource = .ledger
                                selectedHabitId = nil
                                ledgerScope = scope
                                onPickedAccount(scope)
                                dismiss()
                            } label: {
                                HStack(spacing: HoloSpacing.md) {
                                    Image(systemName: account.icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            Circle().fill(isSelected ? GoalJourneyStyle.action.opacity(0.12) : Color.holoToolInset)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.name)
                                            .goalJourneyText(.row)
                                            .foregroundStyle(Color.holoToolText)
                                        Text("\(mode) · \(GoalJourneyNarrative.money(balance))")
                                            .goalJourneyText(.metadata)
                                            .monospacedDigit()
                                            .foregroundStyle(Color.holoToolTextSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    if isSelected {
                                        selectedCheck
                                    }
                                }
                                .padding(HoloSpacing.md)
                                .holoSurface()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HoloPressStyle())
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .presentationDetents([.height(500), .large])
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .goalJourneyText(.metadata)
            .foregroundStyle(Color.holoToolTextSecondary)
            .padding(.top, 2)
    }

    private func emptyHintCard(_ text: String) -> some View {
        Text(text)
            .goalJourneyText(.supporting)
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoloSpacing.md)
            .holoSurface()
    }

    private func habitBadge(_ habit: Habit, isSelected: Bool) -> some View {
        habit.iconImage(size: 18)
            .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
            .frame(width: 40, height: 40)
            .background(
                Circle().fill(isSelected ? GoalJourneyStyle.action.opacity(0.12) : Color.holoToolInset)
            )
    }

    private var selectedCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(GoalJourneyStyle.action)
    }
}

// MARK: - Holo 账本账户选择弹窗（显示图标、余额、口径）

struct GoalLedgerScopePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goalKind: GoalKind
    let accounts: [Account]
    @Binding var selection: GoalLedgerScopePayload

    var body: some View {
        HoloSheetScaffold(title: String(localized: "选择账本"), onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.sm) {
                    if goalKind == .cumulative {
                        let whole = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
                        optionCard(
                            icon: "books.vertical",
                            title: String(localized: "全部账本"),
                            subtitle: String(localized: "总收入减支出净增加"),
                            isSelected: selection == whole
                        ) {
                            selection = whole
                            dismiss()
                        }
                    }

                    ForEach(accounts.renderable, id: \.id) { account in
                        let scope = GoalLedgerScopePayload(
                            kind: goalKind == .cumulative ? .accountDelta : .accountBalance,
                            accountID: account.id
                        )
                        let balance = FinanceRepository.shared.getAccountBalance(account)
                        let modeText = goalKind == .cumulative ? String(localized: "净增加") : String(localized: "余额达到")
                        optionCard(
                            icon: account.icon,
                            title: account.name,
                            subtitle: "\(modeText) · 当前 \(GoalJourneyNarrative.money(balance))",
                            isSelected: selection == scope
                        ) {
                            selection = scope
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .presentationDetents([.height(440), .large])
    }

    private func optionCard(
        icon: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(isSelected ? GoalJourneyStyle.action.opacity(0.12) : Color.holoToolInset)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .goalJourneyText(.row)
                        .foregroundStyle(Color.holoToolText)
                    Text(subtitle)
                        .goalJourneyText(.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(GoalJourneyStyle.action)
                }
            }
            .padding(HoloSpacing.md)
            .holoSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
    }
}

// MARK: - Holo 数值习惯选择弹窗（修复 Emoji/自定义图标渲染）

struct GoalNumericHabitPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let habits: [Habit]
    @Binding var selectedId: UUID?

    var body: some View {
        HoloSheetScaffold(title: String(localized: "选择数值习惯"), onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.sm) {
                    ForEach(habits.renderable, id: \.id) { habit in
                        let isSelected = selectedId == habit.id
                        let mode = habit.isCountType ? String(localized: "每天累加") : String(localized: "每天记最新值")
                        let unit = habit.unitText.isEmpty ? "" : " · \(habit.unitText)"
                        Button {
                            selectedId = habit.id
                            dismiss()
                        } label: {
                            HStack(spacing: HoloSpacing.md) {
                                habit.iconImage(size: 18)
                                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        Circle().fill(isSelected ? GoalJourneyStyle.action.opacity(0.12) : Color.holoToolInset)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(habit.name)
                                        .goalJourneyText(.row)
                                        .foregroundStyle(Color.holoToolText)
                                    Text(mode + unit)
                                        .goalJourneyText(.metadata)
                                        .foregroundStyle(Color.holoToolTextSecondary)
                                }
                                Spacer(minLength: 8)
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(GoalJourneyStyle.action)
                                }
                            }
                            .padding(HoloSpacing.md)
                            .holoSurface()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoloPressStyle())
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .presentationDetents([.height(420), .large])
    }
}
