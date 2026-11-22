//
//  GoalFormPickerSheets.swift
//  Holo
//
//  目标表单专属 Holo 定制选择弹层家族（HoloSheetScaffold）：
//  - GoalDeadlinePickerSheet：快捷期限芯片 + Holo 自绘月历网格（彻底替代系统灰色 DatePicker）
//  - GoalDataSourcePickerSheet：统一的数据来源选择（同步数值习惯 / 关联账本 / 手动更新）
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

// MARK: - 按原模块选择进度数据

struct GoalDataSourcePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let habits: [Habit]
    let accounts: [Account]
    let selection: GoalProgressDataSelection?
    let allowsRemoval: Bool
    let onSelect: (GoalProgressDataSelection?) -> Void

    @State private var search = ""
    @State private var group: SourceGroup = .all
    @FocusState private var isSearchFocused: Bool
    @State private var habitRows: [Option] = []
    @State private var financeRows: [Option] = []
    @State private var hasLoaded = false

    private enum SourceGroup: String, CaseIterable, Identifiable {
        case all, habits, finance, health
        var id: Self { self }
        var title: String {
            switch self {
            case .all: return String(localized: "全部")
            case .habits: return String(localized: "习惯")
            case .finance: return String(localized: "财务")
            case .health: return String(localized: "苹果健康")
            }
        }
    }

    private struct Option: Identifiable {
        let title: String
        let subtitle: String
        let icon: String
        let selection: GoalProgressDataSelection
        var id: String { selection.id }
    }

    var body: some View {
        HoloSheetScaffold(title: String(localized: "选择进度数据"), onClose: { dismiss() }) {
            VStack(spacing: HoloSpacing.sm) {
                VStack(spacing: HoloSpacing.sm) {
                    searchField
                    groupFilter
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.sm)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                        if hasLoaded {
                            sections
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.vertical, HoloSpacing.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(group)
            }
        }
        .task { prepareRows() }
        .presentationDetents([.large])
    }

    private var searchField: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.holoToolTextSecondary)
            TextField("搜索来源", text: $search, prompt: Text("搜索习惯、账户或健康指标").foregroundStyle(Color.holoToolTextSecondary))
                .holoText(.body)
                .focused($isSearchFocused)
                .accessibilityIdentifier("goal-source-search")
        }
        .padding(HoloSpacing.md)
        .holoSurface(.independent)
    }

    private var groupFilter: some View {
        ViewThatFits(in: .horizontal) {
            groupButtons
            ScrollView(.horizontal, showsIndicators: false) { groupButtons }
        }
    }

    private var groupButtons: some View {
        HStack(spacing: HoloSpacing.xs) {
            ForEach(SourceGroup.allCases) { item in
                Button {
                    isSearchFocused = false
                    group = item
                } label: {
                    Text(item.title)
                        .holoText(.supporting)
                        .fixedSize()
                        .padding(.horizontal, HoloSpacing.sm)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(group == item ? Color.holoToolText : Color.holoToolTextSecondary)
                        .background(group == item ? Color.holoToolSurface : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(group == item ? .isSelected : [])
                .accessibilityIdentifier("goal-source-group-\(item.rawValue)")
            }
        }
        .padding(HoloSpacing.xs)
        .background(Color.holoToolInset, in: Capsule())
    }

    @ViewBuilder
    private var sections: some View {
        let habits = group == .all || group == .habits ? matching(habitRows, section: SourceGroup.habits.title) : []
        let finance = group == .all || group == .finance ? matching(financeRows, section: SourceGroup.finance.title) : []
        let health = group == .all || group == .health ? matching(healthRows, section: SourceGroup.health.title) : []
        let hasQuery = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if habits.isEmpty && finance.isEmpty && health.isEmpty {
            if hasQuery {
                emptySources(String(localized: "找不到匹配的数据"), message: String(localized: "试试习惯名称、账户名称或健康指标。"),
                             action: String(localized: "清除搜索")) { search = "" }
            } else if group == .habits {
                emptySources(String(localized: "还没有数值习惯"), message: String(localized: "在习惯中记录的重量、时长或数量可以用来跟踪目标。"),
                             action: String(localized: "查看全部来源")) { group = .all }
            } else if group == .finance {
                emptySources(String(localized: "还没有可用账户"), message: String(localized: "添加账本账户后，可以跟踪它的余额或余额变化。"),
                             action: String(localized: "查看全部来源")) { group = .all }
            }
        }
        optionSection(SourceGroup.habits.title, options: habits, showsHeading: group == .all)
        optionSection(SourceGroup.finance.title, options: finance, showsHeading: group == .all)
        optionSection(SourceGroup.health.title, options: health, showsHeading: group == .all)
        if group == .all && !hasQuery {
            optionSection(String(localized: "其他"), options: [
                Option(title: String(localized: "手动记录"), subtitle: String(localized: "在目标详情记录数值"),
                       icon: "square.and.pencil", selection: .manual)
            ])
            if allowsRemoval {
                Button("移除进度数据") { choose(nil) }
                    .holoText(.body)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("goal-source-remove")
            }
        }
    }

    private func emptySources(_ title: String, message: String, action: String, onAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Label(title, systemImage: "magnifyingglass").holoText(.body)
            Text(message).holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            Button(action, action: onAction)
                .holoText(.body)
                .foregroundStyle(Color.holoToolAction)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    private func matching(_ options: [Option], section: String) -> [Option] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !section.localizedCaseInsensitiveContains(query) else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func optionSection(_ title: String, options: [Option], showsHeading: Bool = true) -> some View {
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                if showsHeading {
                    Text(title).holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(options) { option in
                        if option.id != options.first?.id {
                            Divider().padding(.leading, HoloSpacing.lg)
                        }
                        let selected = option.selection.matchesSource(selection)
                        Button { choose(selected ? selection : option.selection) } label: {
                            optionRow(option, selected: selected)
                        }
                        .buttonStyle(HoloPressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("goal-source-\(option.id)")
                    }
                }
                .holoSurface(.independent)
            }
        }
    }

    private func optionRow(_ option: Option, selected: Bool) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: option.icon)
                .font(.body)
                .frame(width: 24)
                .foregroundStyle(Color.holoToolTextSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(option.title).holoText(.body).foregroundStyle(Color.holoToolText)
                Text(option.subtitle).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.holoToolAction).accessibilityHidden(true)
            }
        }
        .padding(HoloSpacing.sm)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    @MainActor
    private func prepareRows() {
        let now = Date()
        habitRows = habits.renderable.map { habit in
            let record = GoalEvaluationSnapshotBuilder.valuedHabitRecord(habitID: habit.id, in: HabitRepository.shared.context, before: now)
            let summary = record.map {
                "\(GoalMetricEvaluator.formatValue($0.value)) \(habit.unitText) · \(GoalEditForm.shortDayText($0.date))"
            } ?? String(localized: "暂无数值记录")
            let mode = habit.isCountType ? String(localized: "累计") : String(localized: "取最新一条")
            return Option(title: habit.name, subtitle: "\(mode) · \(summary)",
                          icon: habit.isCountType ? "number" : "ruler", selection: .habit(habit.id))
        }
        financeRows = accounts.renderable.map { account in
            let balance: String
            if case .observed(let value, _, _, _) = FinanceRepository.shared.accountBalanceObservation(accountId: account.id, before: now) {
                balance = GoalJourneyNarrative.money(value)
            } else {
                balance = String(localized: "暂无可用余额")
            }
            return Option(title: account.name, subtitle: balance, icon: "wallet.bifold",
                          selection: .ledger(GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)))
        }
        if !financeRows.isEmpty {
            financeRows.append(Option(title: String(localized: "全部账本"), subtitle: String(localized: "累计净增加"),
                                      icon: "books.vertical", selection: .ledger(GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil))))
        }
        hasLoaded = true
    }

    private var healthRows: [Option] {
        GoalHealthMetricKind.allCases.map { kind in
            let detail: String
            switch kind {
            case .sleepHours: detail = String(localized: "最近一晚的睡眠时长")
            case .sleepAverage: detail = String(localized: "最近 7 晚的平均值")
            default: detail = kind.isLatestSample ? String(localized: "取最近一条记录") : String(localized: "从目标开始时累计")
            }
            return Option(title: kind.displayName, subtitle: "\(detail) · \(kind.defaultUnit)",
                          icon: "heart", selection: .health(kind))
        }
    }

    private func choose(_ selection: GoalProgressDataSelection?) {
        onSelect(selection)
        dismiss()
    }
}
