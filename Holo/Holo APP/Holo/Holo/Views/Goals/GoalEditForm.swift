//
//  GoalEditForm.swift
//  Holo
//
//  目标创建/编辑表单（Holo 原生视觉重构）：
//  1. 暖灰圆角标题输入条 + 实时图标预览（同 TaskCreationSheet）
//  2. 四张直觉场景卡（攒钱 / 累计 / 达标 / 做成一件事），零工程术语，底层无损映射既有 GoalKind
//  3. 单一白色分组卡片（数据来源 / 数值 / Holo 定制半屏期限选择卡），彻底移除系统 DatePicker 与 DisclosureGroup
//

import SwiftUI
import CoreData

private enum MetricPlaceholder {
    static let cumulativeTarget = "300"
    static let cumulativeUnit = "km"
    static let targetBaseline = "75"
    static let targetTarget = "65"
    static let targetUnit = "kg"
    static let savingTarget = "50000"
}

private enum GoalEditPickerSheet: Identifiable {
    case domain, icon, account, habit, dataSource, deadline
    var id: Self { self }
}

private enum GoalScenarioIntent: CaseIterable, Identifiable {
    case saving, cumulative, target, process
    var id: Self { self }

    var emoji: String {
        switch self {
        case .saving: return "💰"
        case .cumulative: return "🏃"
        case .target: return "⚖️"
        case .process: return "✅"
        }
    }

    var title: String {
        switch self {
        case .saving: return String(localized: "攒钱")
        case .cumulative: return String(localized: "累计")
        case .target: return String(localized: "达标")
        case .process: return String(localized: "做成一件事")
        }
    }
}

struct GoalEditForm: View {
    @Binding var draft: GoalDraft
    /// 编辑模式为 true 时底部提供「补充说明、动机与图标」折叠区；新建模式保持 false 维持零干扰极速创建
    var showsExtendedFields: Bool = false

    @State private var showExtendedDetails = false
    @State private var activePicker: GoalEditPickerSheet?

    /// 数值输入用文本驱动（draft 存 Double），避免输入中途 "3." 被解析回写打断
    @State private var metricTargetText: String
    @State private var metricBaselineText: String

    /// 达标型自动读取基线时的来源说明
    @State private var baselineNote: String?

    @State private var numericHabits: [Habit] = []
    @State private var ledgerAccounts: [Account] = []

    @FocusState private var isFieldFocused: Bool

    init(draft: Binding<GoalDraft>, showsExtendedFields: Bool = false) {
        self._draft = draft
        self.showsExtendedFields = showsExtendedFields
        self._metricTargetText = State(
            initialValue: draft.wrappedValue.metricTargetValue.map(GoalMetricEvaluator.formatValue) ?? ""
        )
        self._metricBaselineText = State(
            initialValue: draft.wrappedValue.metricBaselineValue.map(GoalMetricEvaluator.formatValue) ?? ""
        )
    }

    private var currentIntent: GoalScenarioIntent {
        switch draft.goalKind {
        case .process: return .process
        case .target: return .target
        case .cumulative: return draft.metricSource == .ledger ? .saving : .cumulative
        }
    }

    private var titlePreviewIcon: String {
        if let chosen = draft.iconEmoji, !chosen.isEmpty { return chosen }
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let inferred = GoalDomain.infer(from: trimmed)
            if inferred != .other { return inferred.defaultEmoji }
        }
        return currentIntent.emoji
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            titleInputRow

            scenarioSelector

            if let hintNumber = activeHintNumber {
                cumulativeHintRow(hintNumber)
                    .transition(.opacity)
            }

            groupedFormCard

            if showsExtendedFields {
                extendedDetailsCard
            }
        }
        .padding(.top, HoloSpacing.md)
        .animation(.easeInOut(duration: 0.2), value: currentIntent)
        .animation(.easeInOut(duration: 0.2), value: activeHintNumber)
        .animation(.easeInOut(duration: 0.2), value: showExtendedDetails)
        .onAppear {
            loadHabits()
            loadAccounts()
            applyAutoBaselineForPrefilledDraft()
        }
        .onChange(of: draft.sourceHabitId) { _, newId in
            applyBaselineFromHabit(newId)
        }
        .sheet(item: $activePicker) { picker in
            sheetView(for: picker)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { isFieldFocused = false }
            }
        }
    }

    @ViewBuilder
    private func sheetView(for picker: GoalEditPickerSheet) -> some View {
        switch picker {
        case .domain:
            GoalDomainPickerSheet(current: draft.domain) { draft.domain = $0 }
        case .icon:
            EmojiIconPickerSheet(currentIcon: draft.iconEmoji ?? draft.domain.defaultEmoji) { draft.iconEmoji = $0 }
        case .account:
            GoalLedgerScopePickerSheet(
                goalKind: draft.goalKind,
                accounts: ledgerAccounts,
                selection: ledgerScopeSelection
            )
        case .habit:
            GoalNumericHabitPickerSheet(habits: numericHabits, selectedId: $draft.sourceHabitId)
        case .dataSource:
            GoalDataSourcePickerSheet(
                goalKind: draft.goalKind,
                habits: numericHabits,
                accounts: ledgerAccounts,
                metricSource: Binding(
                    get: { draft.metricSource },
                    set: { newSource in
                        draft.metricSource = newSource
                        if newSource == .ledger {
                            draft.metricUnit = "¥"
                        } else if draft.metricUnit == "¥" {
                            draft.metricUnit = nil
                        }
                    }
                ),
                selectedHabitId: $draft.sourceHabitId,
                ledgerScope: $draft.ledgerScope,
                healthMetricKind: Binding(
                    get: { draft.healthMetricKind },
                    set: { newKind in
                        draft.healthMetricKind = newKind
                        if let newKind, (draft.metricUnit ?? "").isEmpty {
                            draft.metricUnit = newKind.defaultUnit
                        }
                    }
                ),
                onPickedAccount: { scope in
                    applyBaselineFromAccount(scope)
                }
            )
        case .deadline:
            GoalDeadlinePickerSheet(deadlineText: $draft.deadlineText)
        }
    }

    // MARK: - 1. Holo 暖灰圆角标题输入条

    private var titleInputRow: some View {
        HStack(spacing: HoloSpacing.md) {
            Text(titlePreviewIcon)
                .font(.system(size: 22))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 42, height: 42)
                .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))

            TextField(
                String(localized: "想做成什么？"),
                text: $draft.title,
                prompt: Text(String(localized: "想做成什么？")).foregroundStyle(Color.holoTextPlaceholder)
            )
            .goalJourneyText(.heading)
            .tracking(-0.2)
            .foregroundStyle(Color.holoToolText)
            .lineLimit(1)
            .submitLabel(.done)
            .onSubmit { isFieldFocused = false }
            .focused($isFieldFocused)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
    }

    // MARK: - 2. 四直觉场景选择卡

    private var scenarioSelector: some View {
        HStack(spacing: 8) {
            ForEach(GoalScenarioIntent.allCases) { intent in
                let isSelected = currentIntent == intent
                Button {
                    selectIntent(intent)
                } label: {
                    VStack(spacing: 4) {
                        Text(intent.emoji)
                            .font(.system(size: 18))
                        Text(intent.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(
                        isSelected ? GoalJourneyStyle.action.opacity(0.08) : Color.holoToolSurface,
                        in: RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .strokeBorder(isSelected ? GoalJourneyStyle.action : Color.holoToolBorder, lineWidth: isSelected ? 1.2 : 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .buttonStyle(HoloPressStyle())
            }
        }
    }

    private func selectIntent(_ intent: GoalScenarioIntent) {
        isFieldFocused = false
        switch intent {
        case .saving:
            draft.goalKind = .cumulative
            draft.metricSource = .ledger
            draft.sourceHabitId = nil
            draft.metricUnit = "¥"
            normalizeLedgerScope()
            baselineNote = nil
        case .cumulative:
            draft.goalKind = .cumulative
            if draft.metricSource == .ledger {
                draft.metricSource = .manual
                if draft.metricUnit == "¥" { draft.metricUnit = nil }
            }
            baselineNote = nil
        case .target:
            draft.goalKind = .target
            if draft.metricSource == .ledger && ledgerAccounts.isEmpty {
                draft.metricSource = .manual
            }
            if draft.metricUnit == "¥" && draft.metricSource != .ledger {
                draft.metricUnit = nil
            }
            if draft.metricSource == .ledger {
                normalizeLedgerScope()
                applyBaselineFromAccount(draft.ledgerScope)
            } else if draft.metricSource == .habit {
                applyBaselineFromHabit(draft.sourceHabitId)
            }
        case .process:
            draft.goalKind = .process
            draft.metricSource = .manual
            draft.sourceHabitId = nil
            baselineNote = nil
        }
    }

    // MARK: - 数字提示行

    private var activeHintNumber: Int? {
        Self.showsCumulativeHint(in: draft)
            ? Self.cumulativeHintNumber(inTitle: draft.title) : nil
    }

    private func cumulativeHintRow(_ number: Int) -> some View {
        Button {
            applyCumulativeHint(number)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                Text("标题里有 \(number) —— 点一下按数量累计追踪")
                    .goalJourneyText(.metadata)
                    .lineLimit(2)
            }
            .foregroundStyle(GoalJourneyStyle.action)
            .padding(.horizontal, HoloSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
    }

    private func applyCumulativeHint(_ number: Int) {
        selectIntent(.cumulative)
        if metricTargetText.isEmpty {
            metricTargetText = GoalMetricEvaluator.formatValue(Double(number))
            draft.metricTargetValue = Double(number)
        }
        if (draft.metricUnit ?? "").isEmpty, let unit = Self.unitKeyword(in: draft.title) {
            draft.metricUnit = unit
            if unit == "¥" && !ledgerAccounts.isEmpty {
                selectIntent(.saving)
            }
        }
    }

    // MARK: - 3. 统一白色分组参数卡

    private var groupedFormCard: some View {
        VStack(spacing: 0) {
            switch currentIntent {
            case .saving:
                savingFields
                rowDivider
            case .cumulative:
                cumulativeFields
                rowDivider
            case .target:
                targetFields
                rowDivider
            case .process:
                processHintRow
                rowDivider
            }

            deadlineRow
        }
        .holoSurface()
    }

    @ViewBuilder
    private var savingFields: some View {
        HStack {
            fieldLabel(String(localized: "目标金额"))
            Spacer(minLength: 12)
            Text("¥")
                .goalJourneyText(.rowValue)
                .foregroundStyle(Color.holoToolTextSecondary)
            TextField(MetricPlaceholder.savingTarget, text: $metricTargetText)
                .goalJourneyText(.rowValue)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 80, maxWidth: 150)
                .focused($isFieldFocused)
                #if canImport(UIKit)
                .keyboardType(.decimalPad)
                #endif
                .onChange(of: metricTargetText) { _, newValue in
                    draft.metricTargetValue = Double(newValue)
                }
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 52)

        rowDivider

        Button {
            activePicker = .account
        } label: {
            groupedPickerRow(
                label: String(localized: "关联账户"),
                value: ledgerAccounts.isEmpty ? String(localized: "还没有账户") : ledgerScopeDisplayValue,
                subtitle: ledgerScopeExplanationText
            )
        }
        .buttonStyle(.plain)
        .disabled(ledgerAccounts.isEmpty)
    }

    @ViewBuilder
    private var cumulativeFields: some View {
        HStack(spacing: 8) {
            fieldLabel(String(localized: "目标累计"))
            Spacer(minLength: 12)
            TextField(MetricPlaceholder.cumulativeTarget, text: $metricTargetText)
                .goalJourneyText(.rowValue)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 64, maxWidth: 120)
                .focused($isFieldFocused)
                #if canImport(UIKit)
                .keyboardType(.decimalPad)
                #endif
                .onChange(of: metricTargetText) { _, newValue in
                    draft.metricTargetValue = Double(newValue)
                }
            TextField(MetricPlaceholder.cumulativeUnit, text: unitBinding)
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolTextSecondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($isFieldFocused)
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 52)

        rowDivider

        Button {
            activePicker = .dataSource
        } label: {
            groupedPickerRow(
                label: String(localized: "数据来源"),
                value: dataSourceDisplayValue,
                valueColor: draft.metricSource == .manual ? Color.holoToolText : GoalJourneyStyle.action,
                subtitle: aggregationMismatchText
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var targetFields: some View {
        Button {
            activePicker = .dataSource
        } label: {
            groupedPickerRow(
                label: String(localized: "数据来源"),
                value: dataSourceDisplayValue,
                valueColor: GoalJourneyStyle.action,
                subtitle: aggregationMismatchText
            )
        }
        .buttonStyle(.plain)

        rowDivider

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                fieldLabel(String(localized: "当前数值"))
                if let baselineNote {
                    Text(baselineNote)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if draft.metricSource == .ledger {
                Text("¥")
                    .goalJourneyText(.body)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            TextField(MetricPlaceholder.targetBaseline, text: $metricBaselineText)
                .goalJourneyText(.rowValue)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 56, maxWidth: 110)
                .focused($isFieldFocused)
                #if canImport(UIKit)
                .keyboardType(.decimalPad)
                #endif
                .onChange(of: metricBaselineText) { _, newValue in
                    draft.metricBaselineValue = Double(newValue)
                    baselineNote = nil
                }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, baselineNote == nil ? 0 : 8)
        .frame(minHeight: 52)

        rowDivider

        HStack(spacing: 8) {
            fieldLabel(String(localized: "想达到"))
            Spacer(minLength: 8)
            if draft.metricSource == .ledger {
                Text("¥")
                    .goalJourneyText(.rowValue)
                    .foregroundStyle(GoalJourneyStyle.action)
            }
            TextField(MetricPlaceholder.targetTarget, text: $metricTargetText)
                .goalJourneyText(.rowValue)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(GoalJourneyStyle.action)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 56, maxWidth: 110)
                .focused($isFieldFocused)
                #if canImport(UIKit)
                .keyboardType(.decimalPad)
                #endif
                .onChange(of: metricTargetText) { _, newValue in
                    draft.metricTargetValue = Double(newValue)
                }
            if draft.metricSource != .ledger {
                TextField(MetricPlaceholder.targetUnit, text: unitBinding)
                    .goalJourneyText(.body)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .focused($isFieldFocused)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 52)
    }

    private var processHintRow: some View {
        HStack {
            Text("怎么推进")
                .goalJourneyText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer()
            Text("创建后到详情页拆成小任务或习惯")
                .goalJourneyText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 48)
    }

    private var deadlineRow: some View {
        Button {
            isFieldFocused = false
            activePicker = .deadline
        } label: {
            groupedPickerRow(
                label: String(localized: "截止期限"),
                value: deadlineDisplayText,
                valueColor: draft.deadlineText == nil ? Color.holoToolTextSecondary : GoalJourneyStyle.action
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goal-deadline-row")
    }

    // MARK: - 4. 编辑模式补充细节（Holo 折叠卡，无 DisclosureGroup）

    private var extendedDetailsCard: some View {
        VStack(spacing: 0) {
            Button {
                showExtendedDetails.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("补充说明、动机与图标")
                            .goalJourneyText(.body)
                            .foregroundStyle(Color.holoToolText)
                        Text("可选 · \(draft.domain.displayName)")
                            .goalJourneyText(.metadata)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .rotationEffect(.degrees(showExtendedDetails ? 90 : 0))
                }
                .padding(.horizontal, HoloSpacing.md)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showExtendedDetails {
                rowDivider
                Button { activePicker = .domain } label: {
                    groupedPickerRow(label: String(localized: "领域"), value: draft.domain.displayName)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goal-edit-domain-row")

                rowDivider
                Button { activePicker = .icon } label: {
                    HStack {
                        fieldLabel(String(localized: "图标"))
                        Spacer()
                        Text(draft.iconEmoji ?? draft.domain.defaultEmoji)
                            .font(.system(size: 20))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                rowDivider
                inlineTextRow(
                    title: String(localized: "补充说明"),
                    placeholder: String(localized: "想补充的背景"),
                    text: Binding(get: { draft.summary ?? "" }, set: { draft.summary = $0.isEmpty ? nil : $0 })
                )

                rowDivider
                inlineTextRow(
                    title: String(localized: "期望结果"),
                    placeholder: String(localized: "做到什么样算圆满"),
                    text: Binding(get: { draft.desiredOutcome ?? "" }, set: { draft.desiredOutcome = $0.isEmpty ? nil : $0 })
                )

                rowDivider
                inlineTextRow(
                    title: String(localized: "动机"),
                    placeholder: String(localized: "为什么想做这件事"),
                    text: Binding(get: { draft.motivation ?? "" }, set: { draft.motivation = $0.isEmpty ? nil : $0 })
                )
            }
        }
        .holoSurface()
    }

    // MARK: - 通用行部件

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.holoToolBorder.opacity(0.6))
            .frame(height: 0.5)
            .padding(.leading, HoloSpacing.md)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .goalJourneyText(.supporting)
            .foregroundStyle(Color.holoToolTextSecondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func groupedPickerRow(
        label: String,
        value: String,
        valueColor: Color = Color.holoToolText,
        subtitle: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                fieldLabel(label)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text(value)
                        .goalJourneyText(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, subtitle == nil ? 0 : 10)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private func inlineTextRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(title)
            TextField(placeholder, text: text, axis: .vertical)
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1...3)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 10)
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { draft.metricUnit ?? "" },
            set: { draft.metricUnit = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - 展示文案计算

    private var deadlineDisplayText: String {
        guard let text = draft.deadlineText, !text.isEmpty else {
            return String(localized: "不设期限")
        }
        let date = Self.parseDeadlineText(text)
        return GoalListCard.dayText(date)
    }

    private var selectedHabit: Habit? {
        guard let id = draft.sourceHabitId else { return nil }
        return numericHabits.first { $0.id == id }
    }

    private var dataSourceDisplayValue: String {
        switch draft.metricSource {
        case .manual:
            return String(localized: "手动记录")
        case .habit:
            if let habit = selectedHabit {
                return String(localized: "习惯：\(habit.name)")
            }
            return numericHabits.isEmpty ? String(localized: "还没有数值习惯") : String(localized: "选择习惯")
        case .ledger:
            return String(localized: "账本：\(ledgerScopeDisplayValue)")
        case .healthKit:
            if let kind = draft.healthMetricKind {
                return String(localized: "苹果健康：\(kind.displayName)")
            }
            return String(localized: "苹果健康")
        }
    }

    private var ledgerScopeDisplayValue: String {
        switch draft.ledgerScope?.kind {
        case .wholeLedgerDelta:
            return String(localized: "全部账本")
        case .accountDelta, .accountBalance:
            if let id = draft.ledgerScope?.accountID,
               let account = ledgerAccounts.first(where: { $0.id == id }) {
                return account.name
            }
            return String(localized: "未选择")
        case nil:
            return draft.goalKind == .cumulative ? String(localized: "全部账本") : String(localized: "未选择")
        }
    }

    private var ledgerScopeExplanationText: String? {
        guard draft.metricSource == .ledger else { return nil }
        let scope = draft.ledgerScope ?? GoalLedgerScopePayload(
            kind: draft.goalKind == .cumulative ? .wholeLedgerDelta : .accountBalance,
            accountID: nil
        )
        let name = scope.accountID.flatMap { id in ledgerAccounts.first { $0.id == id }?.name }
        return Self.ledgerScopeExplanation(kind: scope.kind, accountName: name)
    }

    private var ledgerScopeSelection: Binding<GoalLedgerScopePayload> {
        Binding(
            get: {
                draft.ledgerScope ?? GoalLedgerScopePayload(
                    kind: draft.goalKind == .cumulative ? .wholeLedgerDelta : .accountBalance,
                    accountID: draft.goalKind == .cumulative ? nil : ledgerAccounts.first?.id
                )
            },
            set: { newValue in
                draft.ledgerScope = newValue
                applyBaselineFromAccount(newValue)
            }
        )
    }

    private var aggregationMismatchText: String? {
        guard draft.metricSource == .habit, let habit = selectedHabit else { return nil }
        switch draft.goalKind {
        case .process:
            return nil
        case .cumulative:
            guard habit.isMeasureType else { return nil }
            return String(localized: "「\(habit.name)」每天只记最新值，累计会逐日相加")
        case .target:
            guard habit.isCountType else { return nil }
            return String(localized: "「\(habit.name)」每天累加，达标只看最新一条")
        }
    }

    // MARK: - 数据加载与自动基线

    private func loadHabits() {
        let repo = HabitRepository.shared
        repo.setup()
        numericHabits = repo.activeHabits.filter { $0.isNumericType }
        if let id = draft.sourceHabitId, !numericHabits.contains(where: { $0.id == id }) {
            draft.sourceHabitId = nil
        }
        if draft.metricSource == .habit, draft.sourceHabitId == nil, let first = numericHabits.first {
            draft.sourceHabitId = first.id
        }
    }

    private func loadAccounts() {
        ledgerAccounts = FinanceRepository.shared.getAccounts()
        if draft.metricSource == .ledger {
            draft.metricUnit = "¥"
            normalizeLedgerScope()
        }
    }

    private func applyBaselineFromHabit(_ habitId: UUID?) {
        guard draft.goalKind == .target,
              let habitId,
              let habit = numericHabits.first(where: { $0.id == habitId }),
              let record = latestNumericRecord(of: habit, before: Date()) else {
            baselineNote = nil
            return
        }
        metricBaselineText = GoalMetricEvaluator.formatValue(record.value)
        draft.metricBaselineValue = record.value
        if (draft.metricUnit ?? "").isEmpty && !habit.unitText.isEmpty {
            draft.metricUnit = habit.unitText
        }
        baselineNote = String(localized: "取自「\(habit.name)」最新记录（\(Self.shortDayText(record.date))）")
    }

    private func applyBaselineFromAccount(_ scope: GoalLedgerScopePayload?) {
        guard draft.goalKind == .target,
              let id = scope?.accountID,
              let account = ledgerAccounts.first(where: { $0.id == id }),
              case .observed(let balance, let asOf, _, _) = FinanceRepository.shared.accountBalanceObservation(accountId: id, before: Date()) else {
            baselineNote = nil
            return
        }
        let value = NSDecimalNumber(decimal: balance).doubleValue
        metricBaselineText = GoalMetricEvaluator.formatValue(value)
        draft.metricBaselineValue = value
        baselineNote = Self.accountBaselineNote(
            accountName: account.name,
            asOf: asOf,
            isCreditLiability: account.accountType == .creditCard
        )
    }

    private func applyAutoBaselineForPrefilledDraft() {
        guard draft.goalKind == .target,
              draft.metricBaselineValue == nil,
              draft.metricSource == .habit || draft.metricSource == .ledger else { return }
        switch draft.metricSource {
        case .habit:
            applyBaselineFromHabit(draft.sourceHabitId)
        case .ledger:
            applyBaselineFromAccount(draft.ledgerScope)
        case .manual, .healthKit:
            break
        }
    }

    private func latestNumericRecord(of habit: Habit, before date: Date) -> (value: Double, date: Date)? {
        guard let record = habit.recordsArray.first(where: { $0.valueDouble != nil && $0.date < date }),
              let value = record.valueDouble else {
            return nil
        }
        return (value, record.date)
    }

    private func normalizeLedgerScope() {
        draft.ledgerScope = Self.normalizedLedgerScope(
            current: draft.ledgerScope,
            goalKind: draft.goalKind,
            accountIDs: ledgerAccounts.map(\.id)
        )
    }

    // MARK: - 静态规则与工厂（供单测与表单共用）

    static let cumulativeHintNumberThreshold = 30
    static let cumulativeHintUnitNumberThreshold = 2

    static func unitKeyword(in title: String) -> String? {
        let table: [(String, String)] = [
            ("公里", "km"), ("kg", "kg"), ("公斤", "kg"),
            ("元", "¥"), ("块", "¥"),
            ("本", "本"), ("次", "次"), ("页", "页"),
        ]
        let lower = title.lowercased()
        return table.first { lower.contains($0.0) }?.1
    }

    static func cumulativeHintThreshold(forTitle title: String) -> Int {
        unitKeyword(in: title) == nil ? cumulativeHintNumberThreshold : cumulativeHintUnitNumberThreshold
    }

    static func cumulativeHintNumber(inTitle title: String) -> Int? {
        var runs: [Substring] = []
        var start: Substring.Index?
        for index in title.indices {
            let ch = title[index]
            if ch.isASCII, ch.isNumber {
                if start == nil { start = index }
            } else if let s = start {
                runs.append(title[s..<index])
                start = nil
            }
        }
        if let s = start { runs.append(title[s...]) }
        let threshold = cumulativeHintThreshold(forTitle: title)
        return runs.lazy.compactMap { Int($0) }.first { $0 >= threshold }
    }

    static func showsCumulativeHint(in draft: GoalDraft) -> Bool {
        draft.goalKind == .process
            && draft.metricTargetValue == nil
            && cumulativeHintNumber(inTitle: draft.title) != nil
    }

    static func normalizedLedgerScope(
        current scope: GoalLedgerScopePayload?,
        goalKind: GoalKind,
        accountIDs: [UUID]
    ) -> GoalLedgerScopePayload {
        func accountExists(_ id: UUID?) -> Bool {
            guard let id else { return false }
            return accountIDs.contains(id)
        }
        if let scope {
            let stillValid: Bool
            switch scope.kind {
            case .wholeLedgerDelta: stillValid = goalKind == .cumulative
            case .accountDelta: stillValid = goalKind == .cumulative && accountExists(scope.accountID)
            case .accountBalance: stillValid = goalKind == .target && accountExists(scope.accountID)
            }
            if stillValid { return scope }
            if scope.kind != .wholeLedgerDelta, accountExists(scope.accountID) {
                return GoalLedgerScopePayload(
                    kind: goalKind == .target ? .accountBalance : .accountDelta,
                    accountID: scope.accountID
                )
            }
        }
        if goalKind == .target, let first = accountIDs.first {
            return GoalLedgerScopePayload(kind: .accountBalance, accountID: first)
        }
        return GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
    }

    static func ledgerMenuTitle(accountName: String, kind: GoalKind) -> String {
        let qualifier = kind == .cumulative ? String(localized: "净增加") : String(localized: "余额达到")
        return "\(accountName)·\(qualifier)"
    }

    static func ledgerScopeExplanation(kind: GoalLedgerScopeKind, accountName: String?) -> String? {
        switch kind {
        case .wholeLedgerDelta:
            return String(localized: "按全部账本收入减支出的净增加衡量；还债、转账不改变净资产")
        case .accountDelta:
            return String(localized: "从今天起算「\(accountName ?? "？")」的净增加，已有余额不计入")
        case .accountBalance:
            return nil
        }
    }

    static func accountBaselineNote(accountName: String, asOf: Date, isCreditLiability: Bool) -> String {
        var note = String(localized: "取自「\(accountName)」当前余额（\(shortDayText(asOf))）")
        if isCreditLiability {
            note += String(localized: "；余额还到 0 即还清")
        }
        return note
    }

    static func shortDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    static func defaultDeadline(from now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 30, to: now) ?? now
    }

    static func endOfCurrentYear(from now: Date, calendar: Calendar = .current) -> Date {
        let year = calendar.component(.year, from: now)
        return calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? defaultDeadline(from: now, calendar: calendar)
    }

    static func parseDeadlineText(_ text: String?) -> Date {
        guard let text, !text.isEmpty else { return Date() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? Date()
    }

    static func formatDeadline(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func prefilledLedgerScope(of goal: Goal) -> GoalLedgerScopePayload? {
        if let payload = goal.ledgerScopePayload { return payload }
        guard let context = goal.managedObjectContext,
              let row = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context) else {
            return nil
        }
        return row.planPayloadV2?.resultSource?.ledgerScope
    }

    static func draft(from goal: Goal) -> GoalDraft {
        let deadlineText: String? = goal.deadline.map { formatDeadline($0) }
        return GoalDraft(
            id: goal.id.uuidString,
            title: goal.title,
            summary: goal.summary,
            domain: goal.goalDomain,
            iconEmoji: goal.iconEmoji,
            desiredOutcome: goal.desiredOutcome,
            motivation: goal.motivation,
            deadlineText: deadlineText,
            tasks: [],
            habits: [],
            missingInfoWarnings: [],
            goalKind: goal.goalKindEnum,
            metricSource: goal.metricSourceEnum,
            metricUnit: goal.metricUnit,
            metricTargetValue: goal.metricTargetValueDouble,
            metricBaselineValue: goal.baselineValueDouble,
            sourceHabitId: goal.sourceHabitId,
            ledgerScope: goal.metricSourceEnum == .ledger ? prefilledLedgerScope(of: goal) : nil
        )
    }

    static func emptyDraft() -> GoalDraft {
        GoalDraft(
            id: UUID().uuidString,
            title: "",
            summary: nil,
            domain: .other,
            iconEmoji: nil,
            desiredOutcome: nil,
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: []
        )
    }

    static func disabledHint(
        for draft: GoalDraft,
        hasActiveLedgerAccounts: Bool,
        criteriaUnconfirmed: Bool = false
    ) -> String? {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "起个名字就能创建")
        }
        switch draft.goalKind {
        case .process:
            break
        case .cumulative:
            guard let target = draft.metricTargetValue else { return String(localized: "数字还没填完") }
            guard target > 0 else { return String(localized: "目标量要大于 0") }
        case .target:
            guard let baseline = draft.metricBaselineValue,
                  let target = draft.metricTargetValue else { return String(localized: "数字还没填完") }
            guard baseline != target else { return String(localized: "现在和目标不能一样") }
        }
        if draft.metricSource == .ledger {
            guard hasActiveLedgerAccounts else { return String(localized: "还没有账户") }
            guard hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts) else {
                return String(localized: "还没有可用的账本账户")
            }
        }
        if criteriaUnconfirmed {
            return String(localized: "修改了成功条件——勾选下方确认后可保存")
        }
        return nil
    }

    static func hasValidLedgerScope(in draft: GoalDraft, hasActiveLedgerAccounts: Bool) -> Bool {
        guard draft.metricSource == .ledger, let scope = draft.ledgerScope else { return false }
        switch scope.kind {
        case .wholeLedgerDelta:
            return draft.goalKind == .cumulative && hasActiveLedgerAccounts
        case .accountDelta:
            return draft.goalKind == .cumulative && scope.accountID != nil
        case .accountBalance:
            return draft.goalKind == .target && scope.accountID != nil
        }
    }

    static func metricFieldsValid(in draft: GoalDraft, hasActiveLedgerAccounts: Bool) -> Bool {
        guard draft.isQuantitative else { return true }
        guard let target = draft.metricTargetValue, target > 0 else { return false }
        if draft.goalKind == .target {
            guard let baseline = draft.metricBaselineValue, baseline != target else { return false }
        }
        if draft.metricSource == .habit, draft.sourceHabitId == nil {
            return false
        }
        if draft.metricSource == .ledger {
            return hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts)
        }
        return true
    }
}
