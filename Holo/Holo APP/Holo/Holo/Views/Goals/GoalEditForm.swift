//
//  GoalEditForm.swift
//  Holo
//

import SwiftUI
import CoreData
import Combine

enum GoalProgressDataSelection: Equatable {
    case manual
    case habit(UUID)
    case ledger(GoalLedgerScopePayload)
    case health(GoalHealthMetricKind)

    var id: String {
        switch self {
        case .manual: return "manual"
        case .habit(let id): return "habit-\(id)"
        case .ledger(let scope): return "ledger-\(scope.kind.rawValue)-\(scope.accountID?.uuidString ?? "")"
        case .health(let kind): return "health-\(kind.rawValue)"
        }
    }

    func matchesSource(_ other: Self?) -> Bool {
        if case .ledger(let left) = self, case .ledger(let right) = other, let accountID = left.accountID {
            return accountID == right.accountID
        }
        return self == other
    }
}

private enum GoalEditPickerSheet: Identifiable {
    case domain, icon, dataSource, deadline
    var id: Self { self }
}

struct GoalEditForm: View {
    @Binding var draft: GoalDraft
    var showsExtendedFields: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var health = HealthRepository.shared
    @State private var showExtendedDetails = false
    @State private var activePicker: GoalEditPickerSheet?
    @State private var numericHabits: [Habit] = []
    @State private var ledgerAccounts: [Account] = []
    @State private var preview: GoalHealthSample?
    @State private var previewMessage: String?
    @State private var healthRefresh = 0
    @State private var loadingHealth = false
    @State private var metricTargetText: String
    @State private var metricBaselineText: String
    @State private var sourceTargets: [String: String] = [:]
    @State private var changedMeasurement = false
    private enum Field: Hashable { case title, baseline, target, unit }
    @FocusState private var focusedField: Field?

    init(draft: Binding<GoalDraft>, showsExtendedFields: Bool = false) {
        self._draft = draft
        self.showsExtendedFields = showsExtendedFields
        self._metricTargetText = State(initialValue: draft.wrappedValue.metricTargetValue.map(Self.inputText) ?? "")
        self._metricBaselineText = State(initialValue: draft.wrappedValue.metricBaselineValue.map(Self.inputText) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            titleInputRow
            VStack(spacing: 0) {
                sourceRow
                if draft.isQuantitative {
                    rowDivider
                    metricFields
                }
            }
            .holoSurface(.independent)

            deadlineRow
                .holoSurface(.independent)

            if showsExtendedFields {
                extendedDetailsCard
            }
        }
        .padding(.top, HoloSpacing.md)
        .onAppear(perform: loadSources)
        .onReceive(Publishers.Merge(
            NotificationCenter.default.publisher(for: .habitDataDidChange),
            NotificationCenter.default.publisher(for: .financeDataDidChange)
        )) { _ in loadSources() }
        .onChange(of: health.dataSourceState) { _, _ in healthRefresh += 1 }
        .onChange(of: draft.metricStartDate) { _, _ in healthRefresh += 1 }
        .onChange(of: draft.title) { _, _ in
            if !showsExtendedFields { refreshAutomaticComparison() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { healthRefresh += 1 }
        }
        .task(id: healthRefresh) { await refreshHealthPreview() }
        .sheet(item: $activePicker, content: sheetView)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
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
        case .dataSource:
            GoalDataSourcePickerSheet(
                habits: numericHabits, accounts: ledgerAccounts, selection: selection,
                allowsRemoval: draft.isQuantitative, onSelect: selectSource
            )
        case .deadline:
            GoalDeadlinePickerSheet(deadlineText: $draft.deadlineText)
        }
    }

    private var titleInputRow: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            fieldLabel(String(localized: "目标名称"))
            TextField("想做成什么？", text: $draft.title, axis: .vertical)
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1...3)
                .focused($focusedField, equals: .title)
                .padding(HoloSpacing.md)
                .holoSurface(.independent)
                .accessibilityIdentifier("goal-title")
        }
    }

    private var sourceRow: some View {
        Button {
            focusedField = nil
            activePicker = .dataSource
        } label: {
            groupedPickerRow(
                label: draft.isQuantitative ? String(localized: "进度数据") : String(localized: "添加进度数据"),
                value: sourceName
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goal-progress-source")
    }

    private var selection: GoalProgressDataSelection? {
        guard draft.isQuantitative else { return nil }
        switch draft.metricSource {
        case .manual: return .manual
        case .habit: return draft.sourceHabitId.map(GoalProgressDataSelection.habit)
        case .ledger: return draft.ledgerScope.map(GoalProgressDataSelection.ledger)
        case .healthKit: return draft.healthMetricKind.map(GoalProgressDataSelection.health)
        }
    }

    private var sourceName: String {
        guard draft.isQuantitative else { return String(localized: "可选") }
        switch selection {
        case .manual: return String(localized: "手动记录")
        case .habit(let id):
            return numericHabits.renderable.first(where: { $0.id == id }).map { "\(String(localized: "习惯")) · \($0.name)" }
                ?? String(localized: "原习惯不可用")
        case .ledger(let scope):
            if scope.kind == .wholeLedgerDelta { return String(localized: "全部账本 · 净增加") }
            return ledgerAccounts.renderable.first(where: { $0.id == scope.accountID })
                .map { String(localized: "财务 · \($0.name)") } ?? String(localized: "原账户不可用")
        case .health(let kind): return String(localized: "苹果健康 · \(kind.displayName)")
        case nil: return String(localized: "请选择")
        }
    }

    private func loadSources() {
        let repo = HabitRepository.shared
        repo.setup()
        numericHabits = repo.activeHabits.filter(\.isNumericType)
        ledgerAccounts = FinanceRepository.shared.getAccounts()
        reloadSourcePreview(setBaseline: !showsExtendedFields && draft.metricBaselineValue == nil)
    }

    private func selectSource(_ picked: GoalProgressDataSelection?) {
        guard picked != selection || (picked == nil && draft.isQuantitative) else { return }
        if let selection { sourceTargets[selection.id] = metricTargetText }
        changedMeasurement = true
        draft.metricComparisonIsExplicit = nil
        let priorUnit = draft.metricUnit
        let priorKind = draft.goalKind
        let priorHadSource = draft.isQuantitative

        draft.sourceHabitId = nil
        draft.ledgerScope = nil
        draft.healthMetricKind = nil
        draft.metricBaselineValue = nil
        draft.metricStartDate = nil
        draft.metricUnit = nil
        metricBaselineText = ""
        switch picked {
        case .manual:
            draft.metricSource = .manual
            draft.goalKind = .cumulative
            draft.metricUnit = priorUnit
        case .habit(let id):
            let habit = numericHabits.renderable.first { $0.id == id }
            draft.metricSource = .habit
            draft.sourceHabitId = id
            draft.goalKind = habit?.isCountType == true ? .cumulative : .target
            draft.metricUnit = habit?.unit
        case .ledger(let scope):
            draft.metricSource = .ledger
            draft.ledgerScope = scope
            draft.goalKind = scope.kind == .accountBalance ? .target : .cumulative
            draft.metricUnit = "¥"
        case .health(let kind):
            draft.metricSource = .healthKit
            draft.healthMetricKind = kind
            draft.goalKind = kind.isLatestSample ? .target : .cumulative
            draft.metricUnit = kind.defaultUnit
        case nil:
            draft.metricSource = .manual
            draft.goalKind = .process
        }
        if let picked, let remembered = sourceTargets[picked.id] {
            metricTargetText = remembered
            draft.metricTargetValue = Self.parseNumber(remembered)
        } else if priorHadSource && (priorUnit != draft.metricUnit || priorKind != draft.goalKind) {
            metricTargetText = ""
            draft.metricTargetValue = nil
        }

        draft.metricComparison = draft.goalKind == .cumulative ? .reach : nil
        preview = nil
        previewMessage = nil
        reloadSourcePreview(setBaseline: true)
        refreshAutomaticComparison()
        healthRefresh += 1
    }

    private func reloadSourcePreview(setBaseline: Bool = false) {
        switch selection {
        case .habit(let id):
            let active = numericHabits.renderable.contains { $0.id == id }
            let record = active ? GoalEvaluationSnapshotBuilder.valuedHabitRecord(habitID: id, in: HabitRepository.shared.context, before: Date()) : nil
            preview = record.map { GoalHealthSample(value: $0.value, date: $0.date) }
            previewMessage = active ? nil : String(localized: "请选择其他进度数据，或等原习惯恢复")
        case .ledger(let scope) where scope.accountID != nil:
            if let id = scope.accountID,
               case .observed(let balance, let date, _, let type) = FinanceRepository.shared.accountBalanceObservation(accountId: id, before: Date()) {
                preview = GoalHealthSample(value: NSDecimalNumber(decimal: balance).doubleValue, date: date)
                previewMessage = type == .creditCard ? String(localized: "余额回到 0 表示还清") : nil
            } else {
                preview = nil
                previewMessage = String(localized: "暂时无法读取这个账户")
            }
        default:
            return
        }
        if setBaseline && draft.goalKind == .target { draft.metricBaselineValue = preview?.value }
        if !showsExtendedFields || changedMeasurement { refreshAutomaticComparison() }
    }

    private func refreshHealthPreview() async {
        guard let kind = draft.healthMetricKind, draft.metricSource == .healthKit else {
            loadingHealth = false
            return
        }
        let now = Date()
        let start = draft.metricStartDate ?? now
        loadingHealth = true
        if draft.goalKind == .cumulative && start >= now {
            loadingHealth = false
            preview = nil
            previewMessage = nil
            return
        }
        let reading = await health.fetchGoalMetric(kind: kind, since: start, before: now)
        guard !Task.isCancelled, draft.metricSource == .healthKit, draft.healthMetricKind == kind else { return }
        loadingHealth = false
        preview = nil
        switch reading {
        case .value(let sample):
            preview = sample
            previewMessage = sample.coveredNights.map { String(localized: "已记录 \($0)/7 晚") }
        case .noData: previewMessage = String(localized: "暂无可用记录")
        case .waitingForUnlock: previewMessage = String(localized: "解锁设备后读取苹果健康")
        case .unavailable(.authorizationDenied): previewMessage = String(localized: "无法访问苹果健康")
        case .unavailable(.recoverable(let message)): previewMessage = message
        }
        if !showsExtendedFields || changedMeasurement { refreshAutomaticComparison() }
    }

    private var isSleep: Bool {
        draft.healthMetricKind == .sleepHours || draft.healthMetricKind == .sleepAverage
    }

    private var comparison: GoalResultComparison {
        draft.metricComparison ?? (draft.goalKind == .target ? suggestedComparison : .reach)
    }

    private var suggestedComparison: GoalResultComparison {
        .inferredTarget(title: draft.title, unit: draft.metricUnit, healthMetric: draft.healthMetricKind,
                        baseline: draft.metricBaselineValue ?? preview?.value, target: draft.metricTargetValue)
    }

    private func refreshAutomaticComparison() {
        guard draft.goalKind == .target, draft.metricComparisonIsExplicit != true else { return }
        draft.metricComparison = suggestedComparison
        draft.metricComparisonIsExplicit = false
    }

    private var metricFields: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            if showsSourcePreview {
                sourcePreview
            } else if draft.metricSource == .manual && draft.goalKind == .target {
                numericField(String(localized: "起始值"), text: $metricBaselineText, field: .baseline)
                    .onChange(of: metricBaselineText) { _, value in
                        draft.metricBaselineValue = Self.parseNumber(value)
                        changedMeasurement = true
                        refreshAutomaticComparison()
                    }
            }

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                fieldLabel(String(localized: "达成条件"))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HoloSpacing.md) { conditionMenu; targetField }
                    VStack(alignment: .leading, spacing: HoloSpacing.xs) { conditionMenu; targetField }
                }
                if currentReadingMeetsTarget {
                    Text("按当前记录已达成此条件")
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
            if draft.goalKind == .cumulative {
                cumulativeStartMenu
            }
        }
        .padding(HoloSpacing.md)
    }

    private var showsSourcePreview: Bool {
        switch draft.metricSource {
        case .manual: return false
        case .habit: return draft.goalKind == .target
        case .ledger: return draft.ledgerScope?.accountID != nil
        case .healthKit:
            return draft.goalKind == .target || loadingHealth || preview != nil || previewMessage != nil || offersHealthConnection
        }
    }

    private var offersHealthConnection: Bool {
        draft.metricSource == .healthKit && (health.dataSourceState == .notRequested || health.dataSourceState == .denied)
    }

    private var currentReadingMeetsTarget: Bool {
        guard draft.goalKind == .target, let preview, preview.hasEnoughData,
              let target = draft.metricTargetValue, Self.invalidTargetHint(for: draft, target: target) == nil else { return false }
        return comparison == .trendDown || comparison == .stayBelow ? preview.value <= target : preview.value >= target
    }

    private var sourcePreview: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            if loadingHealth {
                HStack { ProgressView(); Text("正在读取苹果健康") }
                    .holoText(.supporting)
            } else if let preview, preview.coveredNights != 0, draft.metricSource != .healthKit || draft.goalKind == .target {
                latestReading(preview)
            } else if draft.goalKind == .target, previewMessage == nil {
                Text("暂无记录，首次记录将作为起点")
                    .holoText(.supporting)
            }
            if !loadingHealth, draft.goalKind == .cumulative, let preview, draft.metricSource == .healthKit {
                let value = draft.healthMetricKind == .stepCount
                    ? preview.value.formatted(.number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(0)))
                    : Self.inputText(preview.value)
                Text("已累计 \(value) \(draft.metricUnit ?? "")")
                    .holoText(.body)
            }
            if let previewMessage, !loadingHealth {
                Text(previewMessage).holoText(.metadata)
            }
            if offersHealthConnection {
                Button("连接苹果健康") { health.requestAuthorization() }
                    .holoText(.body)
                    .foregroundStyle(Color.holoToolAction)
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(Color.holoToolTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latestReading(_ preview: GoalHealthSample) -> some View {
        let isStartingPoint = draft.metricBaselineValue == preview.value && draft.goalKind == .target
        let title = draft.metricSource == .ledger ? String(localized: "当前余额")
            : (isSleep ? String(localized: "当前统计") : String(localized: "最新记录"))
        let value = draft.metricSource == .ledger
            ? GoalJourneyNarrative.money(Decimal(preview.value))
            : "\(Self.inputText(preview.value)) \(draft.metricUnit ?? "")"
        return VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text(title).holoText(.metadata)
            Text(value)
                .holoText(.sectionTitle)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .accessibilityIdentifier("goal-reference-value")
            if let date = preview.date {
                Text(isStartingPoint
                     ? String(localized: "\(Self.shortDayText(date)) · 用作起点")
                     : Self.shortDayText(date))
                    .holoText(.metadata)
            }
            if let baseline = draft.metricBaselineValue, !isStartingPoint {
                let value = draft.metricSource == .ledger ? GoalJourneyNarrative.money(Decimal(baseline)) : "\(Self.inputText(baseline)) \(draft.metricUnit ?? "")"
                Text("起点 \(value)").holoText(.metadata)
            }
        }
    }

    private var conditionMenu: some View {
        Menu {
            if draft.metricSource == .ledger, let id = draft.ledgerScope?.accountID {
                Button("账户余额达到") {
                    selectSource(.ledger(GoalLedgerScopePayload(kind: .accountBalance, accountID: id)))
                    setCondition(.target, comparison: .trendUp)
                }
                Button("账户余额降到") {
                    selectSource(.ledger(GoalLedgerScopePayload(kind: .accountBalance, accountID: id)))
                    setCondition(.target, comparison: .trendDown)
                }
                Button("账户余额增加") {
                    selectSource(.ledger(GoalLedgerScopePayload(kind: .accountDelta, accountID: id)))
                }
            } else if draft.metricSource == .manual || draft.goalKind == .target && !isSleep {
                Button("达到") { setCondition(.target, comparison: .trendUp) }
                Button("降到") { setCondition(.target, comparison: .trendDown) }
                if draft.metricSource == .manual {
                    Button("累计到") { setCondition(.cumulative, comparison: .reach) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(conditionTitle)
                if canChooseCondition {
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .holoText(.body)
            .foregroundStyle(canChooseCondition ? Color.holoToolAction : Color.holoToolText)
            .frame(minHeight: 44)
            .fixedSize()
        }
        .disabled(!canChooseCondition)
        .accessibilityIdentifier("goal-condition")
    }

    private var canChooseCondition: Bool {
        if draft.metricSource == .ledger { return draft.ledgerScope?.accountID != nil }
        return draft.metricSource == .manual || draft.goalKind == .target && !isSleep
    }

    private var conditionTitle: String {
        if draft.metricSource == .ledger {
            if draft.goalKind == .cumulative { return String(localized: "余额增加") }
            return comparison == .trendDown ? String(localized: "余额降到") : String(localized: "余额达到")
        }
        if draft.goalKind == .cumulative { return String(localized: "累计到") }
        return comparison == .trendDown || comparison == .stayBelow ? String(localized: "降到") : String(localized: "达到")
    }

    private var cumulativeStartMenu: some View {
        Menu {
            Button(showsExtendedFields ? "从现在开始" : "从创建开始") { draft.metricStartDate = nil }
            Button("从今天开始") { draft.metricStartDate = Date().startOfDay }
            Button("从本周开始") { draft.metricStartDate = Date().startOfWeek }
            Button("从本月开始") { draft.metricStartDate = Date().startOfMonth }
        } label: {
            groupedPickerRow(
                label: String(localized: "累计起点"),
                value: draft.metricStartDate.map(Self.shortDayText)
                    ?? (showsExtendedFields ? String(localized: "现在") : String(localized: "创建时"))
            )
            .padding(.horizontal, -HoloSpacing.md)
        }
        .accessibilityIdentifier("goal-cumulative-start")
    }

    private func setCondition(_ kind: GoalKind, comparison: GoalResultComparison) {
        draft.goalKind = kind
        draft.metricComparison = comparison
        draft.metricComparisonIsExplicit = kind == .target ? true : nil
        if kind != .cumulative { draft.metricStartDate = nil }
    }

    private var targetField: some View {
        HStack(spacing: HoloSpacing.sm) {
            numericField(String(localized: "目标值"), text: $metricTargetText, field: .target)
                .onChange(of: metricTargetText) { _, value in
                    let target = Self.parseNumber(value)
                    guard target != draft.metricTargetValue else { return }
                    draft.metricTargetValue = target
                    changedMeasurement = true
                    refreshAutomaticComparison()
                }
            if draft.metricSource == .manual {
                TextField("单位", text: Binding(
                    get: { draft.metricUnit ?? "" },
                    set: { draft.metricUnit = $0.isEmpty ? nil : $0 }
                ))
                .holoText(.supporting)
                .frame(minWidth: 44, idealWidth: 52, maxWidth: 72)
                .focused($focusedField, equals: .unit)
            } else if let unit = draft.metricUnit, !unit.isEmpty {
                Text(unit).holoText(.supporting).fixedSize()
            }
        }
    }

    private func numericField(_ label: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: HoloSpacing.xs) {
            TextField(label, text: text)
                .holoText(.body)
                .monospacedDigit()
                .foregroundStyle(Color.holoToolText)
                .focused($focusedField, equals: field)
                .accessibilityIdentifier(field == .target ? "goal-target" : "goal-baseline")
                #if canImport(UIKit)
                .keyboardType(numericKeyboard)
                #endif
            if focusedField == field {
                Button {
                    focusedField = nil
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.body)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起键盘")
                .accessibilityIdentifier("goal-hide-keyboard")
            }
        }
        .padding(.leading, HoloSpacing.sm)
        .padding(.trailing, focusedField == field ? 0 : HoloSpacing.sm)
        .frame(minWidth: 104, minHeight: 44)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    #if canImport(UIKit)
    private var numericKeyboard: UIKeyboardType {
        if draft.healthMetricKind == .stepCount { return .numberPad }
        if draft.goalKind == .target && (draft.metricSource == .manual || draft.metricSource == .ledger) {
            return .numbersAndPunctuation
        }
        return .decimalPad
    }
    #endif

    private static func inputText(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "zh_CN")).grouping(.never).precision(.fractionLength(0...10)))
    }

    private static func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed.replacingOccurrences(of: "−", with: "-")), value.isFinite else { return nil }
        return value
    }

    private var deadlineRow: some View {
        Button {
            focusedField = nil
            activePicker = .deadline
        } label: {
            let value = draft.deadlineText.map { GoalListCard.dayText(Self.parseDeadlineText($0)) } ?? String(localized: "不设期限")
            groupedPickerRow(label: String(localized: "截止期限"), value: value)
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
            .holoText(.supporting)
            .foregroundStyle(Color.holoToolTextSecondary)
    }

    private func groupedPickerRow(label: String, value: String) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            fieldLabel(label)
            Spacer(minLength: HoloSpacing.sm)
            Text(value)
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.holoToolTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.xs)
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

    // MARK: - 日期与草案

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
        let resultSource = goal.managedObjectContext.flatMap { GoalPlanResolver.resultConfiguration(goal: goal, in: $0).source }
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
            ledgerScope: goal.metricSourceEnum == .ledger ? prefilledLedgerScope(of: goal) : nil,
            healthMetricKind: goal.healthMetricKindEnum,
            metricComparison: resultSource?.comparison,
            metricComparisonIsExplicit: resultSource?.comparisonIsExplicit,
            metricStartDate: goal.goalKindEnum == .cumulative ? goal.baselineDate ?? goal.createdAt : nil
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

    static func invalidTargetHint(for draft: GoalDraft, target: Double) -> String? {
        guard draft.metricSource == .healthKit, let kind = draft.healthMetricKind else { return nil }
        switch kind {
        case .stepCount:
            return target > 0 && target.rounded() == target ? nil : String(localized: "请输入大于 0 的整数步数")
        case .sleepHours, .sleepAverage:
            return target > 0 && target <= 24 ? nil : String(localized: "请输入大于 0 且不超过 24 小时的目标")
        case .bodyFatPercentage:
            return target > 0 && target <= 100 ? nil : String(localized: "请输入大于 0 且不超过 100% 的目标")
        case .bodyMass, .distanceWalkingRunning, .activeEnergyBurned, .workoutMinutes:
            return target > 0 ? nil : String(localized: "目标值要大于 0")
        }
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
            guard let target = draft.metricTargetValue, target.isFinite else { return String(localized: "数字还没填完") }
            guard target > 0 else { return String(localized: "目标量要大于 0") }
        case .target:
            guard let target = draft.metricTargetValue, target.isFinite else { return String(localized: "数字还没填完") }
            if draft.metricSource == .manual {
                guard let baseline = draft.metricBaselineValue, baseline.isFinite else { return String(localized: "数字还没填完") }
                if draft.metricComparison == nil, baseline == target { return String(localized: "现在和目标不能一样") }
            }
        }
        if draft.isQuantitative, let target = draft.metricTargetValue,
           let hint = invalidTargetHint(for: draft, target: target) {
            return hint
        }
        if draft.metricSource == .ledger {
            guard hasActiveLedgerAccounts else { return String(localized: "还没有账户") }
            guard hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts) else {
                return String(localized: "还没有可用的账本账户")
            }
        }
        if draft.isQuantitative && draft.metricSource == .habit && draft.sourceHabitId == nil {
            return String(localized: "请选择一个数值习惯")
        }
        if draft.isQuantitative && draft.metricSource == .healthKit && draft.healthMetricKind == nil {
            return String(localized: "请选择一个健康指标")
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
        guard let target = draft.metricTargetValue, target.isFinite,
              draft.goalKind != .cumulative || target > 0,
              invalidTargetHint(for: draft, target: target) == nil else { return false }
        if draft.metricSource == .manual, draft.goalKind == .target {
            guard let baseline = draft.metricBaselineValue, baseline.isFinite,
                  draft.metricComparison != nil || baseline != target else { return false }
        }
        switch draft.metricSource {
        case .habit: return draft.sourceHabitId != nil
        case .ledger: return hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts)
        case .healthKit: return draft.healthMetricKind != nil
        case .manual: return true
        }
    }
}
