//
//  GoalPlanConfirmCards.swift
//  Holo
//
//  目标闭环 v2 确认页三卡：结果来源 / 限制与安排 / 回顾节奏（最终规格 §3.1）。
//  每项可取消、编辑、选择已有对象：沿用草案列表样式（开关 + 行内轻编辑），
//  详细设置仍回原模块编辑器。本文件只改 GoalPlanConfirmation 的绑定值，
//  真实校验与写入在 GoalWorkshopCommitService（预算冲突、来源存在性等在提交时判）。
//

import SwiftUI
import CoreData

// MARK: - 结果来源确认卡

struct GoalResultSourceConfirmCard: View {
    @Binding var confirmation: GoalPlanConfirmation
    let draft: GoalDraft
    let candidates: GoalWorkshopAuthorizedCandidates

    var body: some View {
        goalConfirmCard(icon: "scope", title: String(localized: "结果来源")) {
            if confirmation.resultSource != nil {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Picker("", selection: sourceTypeBinding) {
                        Text("手动记录").tag(GoalResultSourceKind.manual)
                        Text("习惯").tag(GoalResultSourceKind.habit)
                        Text("账本").tag(GoalResultSourceKind.ledger)
                    }
                    .pickerStyle(.segmented)

                    switch source.sourceType {
                    case .manual:
                        goalConfirmHint(String(localized: "进度由你在目标里手动记录"))
                    case .habit:
                        habitPicker
                        aggregationPicker
                    case .ledger:
                        ledgerScopePicker
                        if source.resolvedLedgerScope == .accountBalance {
                            accountPicker
                        } else {
                            goalConfirmHint(String(localized: "按全账本收入减支出的净增加衡量，不是专项资金"))
                        }
                    }

                    targetRow

                    if source.isPending {
                        goalConfirmHint(pendingText, isWarning: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    Text("手动记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoToolText)
                    goalConfirmHint(String(localized: "这个目标不设量化来源，进度按任务与习惯的执行情况看"))
                }
            }
        }
    }

    // MARK: 来源值与写回

    private var source: GoalPlanResultSourceV2 {
        confirmation.resultSource ?? GoalPlanResultSourceV2(
            sourceType: .manual, sourceID: nil, unit: nil, aggregation: nil, comparison: nil,
            targetValue: nil, baselineValue: nil, baselineObservedAt: nil, freshnessDays: nil, ledgerScope: nil
        )
    }

    private func updateSource(_ mutate: (inout GoalPlanResultSourceV2) -> Void) {
        var updated = source
        mutate(&updated)
        updated.freshnessDays = updated.aggregation == .latest ? 14 : nil
        confirmation.resultSource = updated
    }

    /// 切换来源类型：清掉上一类型的对象引用；习惯未选定前标「待补齐」，账本默认全账本净增
    private var sourceTypeBinding: Binding<GoalResultSourceKind> {
        Binding(
            get: { source.sourceType },
            set: { kind in
                guard kind != source.sourceType else { return }
                confirmation.resultSourceHabitDraftID = nil
                updateSource { current in
                    current.sourceType = kind
                    current.sourceID = nil
                    switch kind {
                    case .manual:
                        current.ledgerScope = nil
                        current.isPending = false
                    case .habit:
                        current.ledgerScope = nil
                        if current.aggregation == nil { current.aggregation = .latest }
                        current.isPending = true
                    case .ledger:
                        current.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
                        current.aggregation = .sum
                        current.isPending = false
                    }
                }
            }
        )
    }

    private var pendingText: String {
        switch source.sourceType {
        case .habit: return String(localized: "待补齐：计划照常建立，报告里结果按未知处理；之后到习惯里选定来源")
        case .ledger: return String(localized: "待补齐：计划照常建立，报告里结果按未知处理；之后到财务完善账户再选定")
        case .manual: return String(localized: "待补齐")
        }
    }

    // MARK: 习惯来源（既有数值习惯 / 本草案新建数值习惯 / 待补齐）

    private static let pendingTag = "pending"

    private var draftNumericHabits: [GoalHabitDraft] {
        draft.habits.filter { $0.isSelected && $0.type == "numeric" }
    }

    private var candidateNumericHabits: [GoalWorkshopHabitCandidate] {
        candidates.habits.filter { $0.type == "numeric" }
    }

    private var habitSelectionBinding: Binding<String> {
        Binding(
            get: {
                if let draftID = confirmation.resultSourceHabitDraftID { return "draft:\(draftID)" }
                if let id = source.sourceID { return "habit:\(id.uuidString)" }
                return Self.pendingTag
            },
            set: { tag in
                if tag.hasPrefix("draft:") {
                    let draftID = String(tag.dropFirst("draft:".count))
                    let habitDraft = draft.habits.first { $0.id == draftID }
                    confirmation.resultSourceHabitDraftID = draftID
                    updateSource { current in
                        current.sourceID = nil
                        current.isPending = false
                        if let habitDraft {
                            current.aggregation = habitDraft.resolvedAggregation == .latest ? .latest : .sum
                            if current.unit == nil { current.unit = habitDraft.unit }
                        }
                    }
                } else if tag.hasPrefix("habit:"), let id = UUID(uuidString: String(tag.dropFirst("habit:".count))) {
                    let candidate = candidates.habits.first { $0.id == id }
                    confirmation.resultSourceHabitDraftID = nil
                    updateSource { current in
                        current.sourceID = id
                        current.isPending = false
                        if let candidate {
                            current.aggregation = candidate.aggregation == "latest" ? .latest : .sum
                            if current.unit == nil { current.unit = candidate.unit }
                        }
                    }
                } else {
                    confirmation.resultSourceHabitDraftID = nil
                    updateSource { current in
                        current.sourceID = nil
                        current.isPending = true
                    }
                }
            }
        )
    }

    private var habitPicker: some View {
        goalConfirmLabeled(String(localized: "读哪个习惯")) {
            Picker("", selection: habitSelectionBinding) {
                Text("稍后补齐").tag(Self.pendingTag)
                ForEach(draftNumericHabits) { habitDraft in
                    Text("新建 · \(habitDraft.name)").tag("draft:\(habitDraft.id)")
                }
                ForEach(candidateNumericHabits) { candidate in
                    Text("既有 · \(candidate.name)").tag("habit:\(candidate.id.uuidString)")
                }
                // 旧草案指向的既有习惯不在授权候选里：仍给出当前选项，避免选择器空白
                if let id = source.sourceID, !candidateNumericHabits.contains(where: { $0.id == id }) {
                    Text("既有 · \(GoalConfirmObjectResolver.habitName(id: id, candidates: candidates))")
                        .tag("habit:\(id.uuidString)")
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("goal.confirm.resultSource.habit")
        }
    }

    private var aggregationPicker: some View {
        goalConfirmLabeled(String(localized: "怎么读")) {
            Picker("", selection: Binding(
                get: { source.aggregation ?? .latest },
                set: { value in updateSource { $0.aggregation = value } }
            )) {
                Text("取最新一次（体重类）").tag(GoalHabitAggregationKind.latest)
                Text("累计相加（练习量类）").tag(GoalHabitAggregationKind.sum)
                if source.aggregation == .windowTrend {
                    Text("窗口趋势").tag(GoalHabitAggregationKind.windowTrend)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: 账本来源（全账本净增 / 单账户余额）

    private var ledgerScopePicker: some View {
        Picker("", selection: Binding(
            get: { source.resolvedLedgerScope },
            set: { kind in
                updateSource { current in
                    switch kind {
                    case .wholeLedgerDelta:
                        current.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
                        current.sourceID = nil
                        current.isPending = false
                    case .accountBalance:
                        let accountID = current.ledgerScope?.accountID
                        current.ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: accountID)
                        current.sourceID = accountID
                        current.isPending = accountID == nil
                    }
                }
            }
        )) {
            Text(GoalLedgerScopeKind.wholeLedgerDelta.displayName).tag(GoalLedgerScopeKind.wholeLedgerDelta)
            Text(GoalLedgerScopeKind.accountBalance.displayName).tag(GoalLedgerScopeKind.accountBalance)
        }
        .pickerStyle(.segmented)
    }

    /// 单账户余额只认真实资产账户；信用负债账户不能当专款来源（§4.1）
    private var selectableAccounts: [GoalWorkshopAccountCandidate] {
        candidates.accounts.filter { !$0.isCreditLiability }
    }

    private var accountSelectionBinding: Binding<String> {
        Binding(
            get: {
                if let id = source.ledgerScope?.accountID { return "account:\(id.uuidString)" }
                return Self.pendingTag
            },
            set: { tag in
                updateSource { current in
                    if tag.hasPrefix("account:"), let id = UUID(uuidString: String(tag.dropFirst("account:".count))) {
                        current.ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: id)
                        current.sourceID = id
                        current.isPending = false
                    } else {
                        current.ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: nil)
                        current.sourceID = nil
                        current.isPending = true
                    }
                }
            }
        )
    }

    private var accountPicker: some View {
        goalConfirmLabeled(String(localized: "哪个账户代表这笔资金")) {
            Picker("", selection: accountSelectionBinding) {
                Text("稍后补齐").tag(Self.pendingTag)
                ForEach(selectableAccounts) { account in
                    Text(account.name).tag("account:\(account.id.uuidString)")
                }
                if let id = source.ledgerScope?.accountID, !selectableAccounts.contains(where: { $0.id == id }) {
                    Text(GoalConfirmObjectResolver.accountName(id: id, candidates: candidates))
                        .tag("account:\(id.uuidString)")
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("goal.confirm.resultSource.account")
        }
    }

    // MARK: 目标值 / 单位 / 比较方式

    private static let comparisons: [(GoalResultComparison, String)] = [
        (.reach, String(localized: "达到")),
        (.stayBelow, String(localized: "不超过")),
        (.trendDown, String(localized: "持续下降")),
        (.trendUp, String(localized: "持续上升")),
    ]

    private var targetRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            Picker("", selection: Binding(
                get: { source.comparison ?? .reach },
                set: { value in updateSource { $0.comparison = value } }
            )) {
                ForEach(Self.comparisons, id: \.0) { comparison, name in
                    Text(name).tag(comparison)
                }
            }
            .pickerStyle(.menu)

            TextField(String(localized: "目标值"), value: Binding(
                get: { source.targetValue },
                set: { value in updateSource { $0.targetValue = value } }
            ), format: .number)
            #if canImport(UIKit)
            .keyboardType(.decimalPad)
            #endif
            .goalConfirmField()

            TextField(String(localized: "单位"), text: Binding(
                get: { source.unit ?? "" },
                set: { text in updateSource { $0.unit = text.isEmpty ? nil : text } }
            ))
            .goalConfirmField()
            .frame(maxWidth: 88)
        }
    }
}

// MARK: - 限制与安排确认卡（预算 / 资金期次 / 行为限制）

struct GoalConstraintsConfirmCard: View {
    @Binding var confirmation: GoalPlanConfirmation
    let draft: GoalDraft
    let candidates: GoalWorkshopAuthorizedCandidates

    var body: some View {
        goalConfirmCard(icon: "slider.horizontal.3", title: String(localized: "限制与安排")) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                if confirmation.budget != nil {
                    budgetSection
                }
                if !confirmation.fundSchedule.isEmpty {
                    if confirmation.budget != nil { CardDivider() }
                    fundScheduleSection
                }
                if !confirmation.constraints.isEmpty {
                    if confirmation.budget != nil || !confirmation.fundSchedule.isEmpty { CardDivider() }
                    constraintsSection
                }
            }
        }
    }

    // MARK: 预算（财务全局约定：同账户同周期已有预算须明确复用，R32）

    private func budgetBinding<T>(_ keyPath: WritableKeyPath<GoalBudgetConfirmation, T>) -> Binding<T> {
        Binding(
            get: { confirmation.budget![keyPath: keyPath] },
            set: { confirmation.budget?[keyPath: keyPath] = $0 }
        )
    }

    private var budgetAccountBinding: Binding<String> {
        Binding(
            get: { confirmation.budget?.accountID.map { "account:\($0.uuidString)" } ?? "none" },
            set: { tag in
                let id = tag.hasPrefix("account:") ? UUID(uuidString: String(tag.dropFirst("account:".count))) : nil
                confirmation.budget?.accountID = id
                // 换账户后既有预算的复用关系不再成立，重新判定
                confirmation.budget?.reuseExistingBudgetID = nil
            }
        )
    }

    private var budgetPeriodBinding: Binding<BudgetPeriod> {
        Binding(
            get: { BudgetPeriod(rawValue: confirmation.budget?.period ?? "") ?? .month },
            set: {
                confirmation.budget?.period = $0.rawValue
                confirmation.budget?.reuseExistingBudgetID = nil
            }
        )
    }

    /// 所选账户同周期（账户总预算）已存在的预算
    private var existingBudget: Budget? {
        guard let budget = confirmation.budget, budget.isSelected, let accountID = budget.accountID else { return nil }
        return GoalWorkshopCommitService.fetchBudget(
            accountID: accountID, categoryID: budget.categoryID, period: budget.period,
            in: CoreDataStack.shared.viewContext
        )
    }

    private var budgetSection: some View {
        let budget = confirmation.budget!
        let existing = existingBudget
        let isReusing = budget.reuseExistingBudgetID != nil
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Toggle("", isOn: budgetBinding(\.isSelected))
                    .labelsHidden()
                    .tint(.holoPrimary)
                    .accessibilityIdentifier("goal.confirm.budget.toggle")
                TextField(String(localized: "预算名称"), text: budgetBinding(\.title))
                    .font(.holoCaption)
                    .foregroundColor(.holoToolText)
                    .strikethrough(!budget.isSelected, color: .holoToolTextSecondary)
                goalConfirmBadge(String(localized: "预算"))
            }

            if budget.isSelected {
                goalConfirmLabeled(String(localized: "账户")) {
                    Picker("", selection: budgetAccountBinding) {
                        Text("选择账户").tag("none")
                        ForEach(candidates.accounts) { account in
                            Text(account.name).tag("account:\(account.id.uuidString)")
                        }
                        if let id = budget.accountID, !candidates.accounts.contains(where: { $0.id == id }) {
                            Text(GoalConfirmObjectResolver.accountName(id: id, candidates: candidates))
                                .tag("account:\(id.uuidString)")
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("goal.confirm.budget.account")
                }

                HStack(spacing: HoloSpacing.sm) {
                    TextField(String(localized: "金额"), value: budgetBinding(\.amount), format: .number)
                        #if canImport(UIKit)
                        .keyboardType(.decimalPad)
                        #endif
                        .goalConfirmField()
                        .disabled(isReusing)
                        .opacity(isReusing ? 0.6 : 1)
                    Picker("", selection: budgetPeriodBinding) {
                        ForEach(BudgetPeriod.allCases) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isReusing)
                }

                if let existing {
                    VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                        Toggle(isOn: Binding(
                            get: { isReusing },
                            set: { confirmation.budget?.reuseExistingBudgetID = $0 ? existing.id : nil }
                        )) {
                            Text("复用这个账户\(Self.periodName(existing.period))已有的预算 \(Self.moneyText(existing.amount.decimalValue))")
                                .font(.holoLabel)
                                .foregroundColor(.holoToolText)
                        }
                        .tint(.holoPrimary)
                        if !isReusing {
                            goalConfirmHint(String(localized: "同账户同周期不会再建第二份预算：复用它，或者换账户 / 换周期"), isWarning: true)
                        }
                    }
                } else if candidates.accounts.isEmpty, budget.accountID == nil {
                    goalConfirmHint(String(localized: "没有可用账户：可先取消预算，到财务添加账户后再设"), isWarning: true)
                } else if !budget.isReady {
                    goalConfirmHint(String(localized: "预算需要选定账户，金额大于 0"), isWarning: true)
                }
            }
        }
    }

    // MARK: 资金期次（每期一行：到期日 / 金额 / 删除；可加一期）

    private func installmentDate(_ index: Int) -> Binding<Date> {
        Binding(
            get: { confirmation.fundSchedule.indices.contains(index) ? confirmation.fundSchedule[index].dueDate : Date() },
            set: { if confirmation.fundSchedule.indices.contains(index) { confirmation.fundSchedule[index].dueDate = $0 } }
        )
    }

    private func installmentAmount(_ index: Int) -> Binding<Decimal> {
        Binding(
            get: { confirmation.fundSchedule.indices.contains(index) ? confirmation.fundSchedule[index].amount : 0 },
            set: { if confirmation.fundSchedule.indices.contains(index) { confirmation.fundSchedule[index].amount = $0 } }
        )
    }

    /// 新一期：接在最后一期之后一个月，金额沿用最后一期
    private func appendInstallment() {
        let calendar = Calendar.current
        let last = confirmation.fundSchedule.max { $0.dueDate < $1.dueDate }
        let dueDate = last.flatMap { calendar.date(byAdding: .month, value: 1, to: $0.dueDate) }
            ?? calendar.date(byAdding: .month, value: 1, to: Date())
            ?? Date()
        confirmation.fundSchedule.append(GoalFundInstallmentV2(dueDate: dueDate, amount: last?.amount ?? 0, note: nil))
    }

    private var fundScheduleSection: some View {
        let total = confirmation.fundSchedule.reduce(Decimal(0)) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("资金期次")
                    .font(.holoLabel)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                Button(action: appendInstallment) {
                    Label {
                        Text("加一期").font(.holoLabel)
                    } icon: {
                        Image(systemName: "plus.circle")
                    }
                    .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goal.confirm.fund.add")
            }

            ForEach(confirmation.fundSchedule.indices, id: \.self) { index in
                HStack(spacing: HoloSpacing.sm) {
                    DatePicker("", selection: installmentDate(index), displayedComponents: .date)
                        .labelsHidden()
                    TextField(String(localized: "金额"), value: installmentAmount(index), format: .number)
                        #if canImport(UIKit)
                        .keyboardType(.decimalPad)
                        #endif
                        .goalConfirmField()
                        .frame(maxWidth: 120)
                    Spacer(minLength: 0)
                    Button {
                        guard confirmation.fundSchedule.indices.contains(index) else { return }
                        confirmation.fundSchedule.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("删除这一期"))
                }
            }

            Text("共 \(confirmation.fundSchedule.count) 期，合计 \(Self.moneyText(total))")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
        }
    }

    // MARK: 行为限制（上限 / 窗口 / 对应习惯：新建或既有 / 阶段性到期）

    private static let windowOptions: [(Int, String)] = [
        (1, String(localized: "每天")),
        (7, String(localized: "每周")),
        (30, String(localized: "每月")),
    ]

    private var selectableDraftHabits: [GoalHabitDraft] {
        draft.habits.filter(\.isSelected)
    }

    private func habitSelectionBinding(_ constraint: Binding<GoalConstraintConfirmation>) -> Binding<String> {
        Binding(
            get: {
                if let draftID = constraint.wrappedValue.habitDraftID { return "draft:\(draftID)" }
                if let id = constraint.wrappedValue.habitID { return "habit:\(id.uuidString)" }
                return "none"
            },
            set: { tag in
                if tag.hasPrefix("draft:") {
                    constraint.wrappedValue.habitDraftID = String(tag.dropFirst("draft:".count))
                    constraint.wrappedValue.habitID = nil
                } else if tag.hasPrefix("habit:"), let id = UUID(uuidString: String(tag.dropFirst("habit:".count))) {
                    constraint.wrappedValue.habitDraftID = nil
                    constraint.wrappedValue.habitID = id
                } else {
                    constraint.wrappedValue.habitDraftID = nil
                    constraint.wrappedValue.habitID = nil
                }
            }
        )
    }

    /// 限制引用的新建习惯在上方「习惯」卡被取消后，这条限制就没有可执行对象了
    private func constraintHasHabit(_ constraint: GoalConstraintConfirmation) -> Bool {
        if constraint.habitID != nil { return true }
        guard let draftID = constraint.habitDraftID else { return false }
        return selectableDraftHabits.contains { $0.id == draftID }
    }

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("行为限制")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            ForEach($confirmation.constraints) { $constraint in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    HStack(spacing: HoloSpacing.sm) {
                        Toggle("", isOn: $constraint.isSelected)
                            .labelsHidden()
                            .tint(.holoPrimary)
                        TextField(String(localized: "限制名称"), text: $constraint.title)
                            .font(.holoCaption)
                            .foregroundColor(.holoToolText)
                            .strikethrough(!constraint.isSelected, color: .holoToolTextSecondary)
                    }

                    if constraint.isSelected {
                        HStack(spacing: HoloSpacing.sm) {
                            Text("上限")
                                .font(.holoLabel)
                                .foregroundColor(.holoToolTextSecondary)
                            TextField(String(localized: "数量"), value: $constraint.limitValue, format: .number)
                                #if canImport(UIKit)
                                .keyboardType(.decimalPad)
                                #endif
                                .goalConfirmField()
                                .frame(maxWidth: 80)
                            TextField(String(localized: "单位"), text: Binding(
                                get: { constraint.unit ?? "" },
                                set: { constraint.unit = $0.isEmpty ? nil : $0 }
                            ))
                            .goalConfirmField()
                            .frame(maxWidth: 72)
                            Picker("", selection: $constraint.windowDays) {
                                ForEach(Self.windowOptions, id: \.0) { days, name in
                                    Text(name).tag(days)
                                }
                                if !Self.windowOptions.contains(where: { $0.0 == constraint.windowDays }) {
                                    Text("每 \(constraint.windowDays) 天").tag(constraint.windowDays)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        goalConfirmLabeled(String(localized: "记在哪个习惯")) {
                            Picker("", selection: habitSelectionBinding($constraint)) {
                                Text("选择习惯").tag("none")
                                ForEach(selectableDraftHabits) { habitDraft in
                                    Text("新建 · \(habitDraft.name)").tag("draft:\(habitDraft.id)")
                                }
                                ForEach(candidates.habits) { candidate in
                                    Text("既有 · \(candidate.name)").tag("habit:\(candidate.id.uuidString)")
                                }
                                if let id = constraint.habitID, !candidates.habits.contains(where: { $0.id == id }) {
                                    Text("既有 · \(GoalConfirmObjectResolver.habitName(id: id, candidates: candidates))")
                                        .tag("habit:\(id.uuidString)")
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Toggle(isOn: Binding(
                            get: { constraint.effectiveThrough != nil },
                            set: { on in
                                constraint.effectiveThrough = on
                                    ? Calendar.current.date(byAdding: .day, value: 28, to: Calendar.current.startOfDay(for: Date()))
                                    : nil
                            }
                        )) {
                            Text("阶段性要求，到期自动结束")
                                .font(.holoLabel)
                                .foregroundColor(.holoToolText)
                        }
                        .tint(.holoPrimary)

                        if let through = constraint.effectiveThrough {
                            DatePicker(String(localized: "截止"), selection: Binding(
                                get: { through },
                                set: { constraint.effectiveThrough = $0 }
                            ), in: Date()..., displayedComponents: .date)
                            .font(.holoLabel)
                        }

                        if !constraintHasHabit(constraint) {
                            goalConfirmHint(String(localized: "这条限制要落在一个习惯上才能记数：选一个既有习惯，或保留上方新建的习惯"), isWarning: true)
                        }
                    }
                }
                .padding(.vertical, HoloSpacing.xs)

                if constraint.id != confirmation.constraints.last?.id {
                    CardDivider()
                }
            }
        }
    }

    // MARK: 文本

    private static func moneyText(_ amount: Decimal) -> String {
        NSDecimalNumber(decimal: amount).stringValue
    }

    private static func periodName(_ rawValue: String) -> String {
        guard let period = BudgetPeriod(rawValue: rawValue) else { return rawValue }
        return period.displayName
    }
}

// MARK: - 回顾节奏确认卡

struct GoalReviewCadenceConfirmCard: View {
    @Binding var review: GoalPlanReviewV2

    private static let cadenceOptions: [(Int, String)] = [
        (7, String(localized: "每周")),
        (14, String(localized: "每两周")),
        (30, String(localized: "每月")),
    ]

    var body: some View {
        goalConfirmCard(icon: "arrow.clockwise.circle", title: String(localized: "回顾节奏")) {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Toggle(isOn: Binding(
                    get: { review.cadenceDays != nil },
                    set: { on in
                        if on {
                            let cadence = GoalPlanReviewV2.defaultCadenceDays
                            review.cadenceDays = cadence
                            review.nextReviewAt = Calendar.current.date(byAdding: .day, value: cadence, to: Date())
                        } else {
                            review.cadenceDays = nil
                            review.nextReviewAt = nil
                        }
                    }
                )) {
                    Text("定期回顾")
                        .font(.holoCaption)
                        .foregroundColor(.holoToolText)
                }
                .tint(.holoPrimary)
                .accessibilityIdentifier("goal.confirm.review.toggle")

                if let cadenceDays = review.cadenceDays {
                    Picker("", selection: Binding(
                        get: { cadenceDays },
                        set: { value in
                            review.cadenceDays = value
                            review.nextReviewAt = Calendar.current.date(byAdding: .day, value: value, to: Date())
                        }
                    )) {
                        ForEach(Self.cadenceOptions, id: \.0) { days, name in
                            Text(name).tag(days)
                        }
                        if !Self.cadenceOptions.contains(where: { $0.0 == cadenceDays }) {
                            Text("每 \(cadenceDays) 天").tag(cadenceDays)
                        }
                    }
                    .pickerStyle(.segmented)

                    DatePicker(String(localized: "下次回顾"), selection: Binding(
                        get: { review.nextReviewAt ?? Calendar.current.date(byAdding: .day, value: cadenceDays, to: Date()) ?? Date() },
                        set: { review.nextReviewAt = $0 }
                    ), in: Date()..., displayedComponents: .date)
                    .font(.holoCaption)

                    Stepper(value: $review.observationWindowDays, in: 7...90, step: 7) {
                        Text("每次回看最近 \(review.observationWindowDays) 天")
                            .font(.holoLabel)
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    goalConfirmHint(String(localized: "到期先出现待回顾提示，你点开才会生成报告，不会每次记录都打扰"))
                } else {
                    goalConfirmHint(String(localized: "已关闭定期回顾；需要时仍可在目标里手动发起分析"))
                }
            }
        }
    }
}

// MARK: - 对象名称回查（候选优先；旧草案指向的对象不在候选时查库）

private enum GoalConfirmObjectResolver {
    @MainActor
    static func habitName(id: UUID, candidates: GoalWorkshopAuthorizedCandidates) -> String {
        if let candidate = candidates.habits.first(where: { $0.id == id }) { return candidate.name }
        return GoalWorkshopCommitService.fetchHabit(id: id, in: CoreDataStack.shared.viewContext)?.name
            ?? String(localized: "已选定的习惯")
    }

    @MainActor
    static func accountName(id: UUID, candidates: GoalWorkshopAuthorizedCandidates) -> String {
        if let candidate = candidates.accounts.first(where: { $0.id == id }) { return candidate.name }
        return GoalWorkshopCommitService.fetchAccount(id: id, in: CoreDataStack.shared.viewContext)?.name
            ?? String(localized: "已选定的账户")
    }
}

// MARK: - 共用卡片壳与行内控件（与 GoalDraftReviewView 现有卡片同款样式）

private func goalConfirmCard<Content: View>(
    icon: String,
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)
            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
            Spacer()
        }
        CardDivider()
        content()
    }
    .padding(HoloSpacing.md)
    .background(Color.holoToolSurface)
    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    .overlay(
        RoundedRectangle(cornerRadius: HoloRadius.md)
            .stroke(Color.holoBorder, lineWidth: 1)
    )
    .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
}

/// 「标签 + 控件」一行：标签靠左，控件靠右
private func goalConfirmLabeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: HoloSpacing.sm) {
        Text(label)
            .font(.holoLabel)
            .foregroundColor(.holoToolTextSecondary)
        Spacer(minLength: HoloSpacing.sm)
        content()
    }
}

private func goalConfirmHint(_ text: String, isWarning: Bool = false) -> some View {
    Label {
        Text(text).font(.holoLabel)
    } icon: {
        Image(systemName: isWarning ? "exclamationmark.triangle" : "info.circle")
    }
    .foregroundColor(isWarning ? .holoToolError : .holoToolTextSecondary)
}

private func goalConfirmBadge(_ text: String) -> some View {
    Text(text)
        .font(.holoTinyLabel)
        .foregroundColor(.holoPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.holoPrimary.opacity(0.12))
        .cornerRadius(4)
}

private extension View {
    /// 与确认页标题/说明输入框同款的行内输入样式
    func goalConfirmField() -> some View {
        font(.holoCaption)
            .foregroundColor(.holoToolText)
            .padding(HoloSpacing.sm)
            .background(Color.holoToolBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }
}
