import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif
import CoreData

private struct GoalPlanCriteriaFields: View {
    @Binding var payload: GoalPlanPayloadV2
    @State private var accounts: [Account] = []
    var body: some View {
        GoalJourneyFormSection(title: "本目标的成功条件") {
            GoalJourneyField(title: "怎样才算达成") {
                TextField("怎样才算达成", text: Binding(get: { payload.intent.successCriteria ?? "" }, set: { payload.intent.successCriteria = $0 }), axis: .vertical)
            }
            if payload.resultSource != nil {
                GoalJourneyField(title: "成果目标值 · " + (payload.resultSource?.unit ?? "数值")) {
                    TextField("成果目标值", value: Binding<Double>(get: { payload.resultSource?.targetValue ?? 0 }, set: { payload.resultSource?.targetValue = $0 }), format: .number)
                        #if canImport(UIKit)
                        .keyboardType(.decimalPad).accessibilityIdentifier("goal-plan-result-target")
                        #endif
                }
            }
            if payload.resultSource?.sourceType == .ledger {
                GoalJourneyField(title: "资金来源") {
                    Picker("资金来源", selection: Binding<UUID?>(get: { payload.resultSource?.ledgerScope?.accountID }, set: { id in
                        payload.resultSource?.sourceID = id
                        payload.resultSource?.ledgerScope = GoalLedgerScopePayload(kind: id == nil ? .wholeLedgerDelta : .accountBalance, accountID: id)
                    })) {
                        Text("全账本净结余增加（旧口径）").tag(Optional<UUID>.none)
                        ForEach(accounts, id: \.id) { account in Text(account.name).tag(Optional(account.id)) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.onAppear { accounts = FinanceRepository.shared.getAccounts() }
    }
}

private struct GoalFundScheduleFields: View {
    @Binding var payload: GoalPlanPayloadV2
    var body: some View {
        if !payload.fundSchedule.isEmpty {
            GoalJourneyFormSection(title: "资金安排") {
                ForEach(payload.fundSchedule.indices, id: \.self) { index in
                    GoalJourneyField(title: GoalAnalysisSection.dayText(payload.fundSchedule[index].dueDate) + " · 计划存入（元）") {
                        TextField("计划存入", value: $payload.fundSchedule[index].amount, format: .number)
                            #if canImport(UIKit)
                            .keyboardType(.decimalPad).disabled(payload.fundSchedule[index].dueDate < Date())
                            #endif
                    }
                }
                Text("修改的是计划，账户余额和过去已确认的期次不被覆盖。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            }
        }
    }
}

struct GoalPlanEditorSheet: View {
    @ObservedObject var goal: Goal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var payload: GoalPlanPayloadV2?
    @State private var baseID: UUID?
    @State private var initialPayload: GoalPlanPayloadV2?
    @State private var operationID = UUID()
    @State private var confirmed = false
    @State private var error: String?
    @State private var saving = false
    @State private var changed = false
    @State private var showDiscard = false
    @State private var showHabitPicker = false
    @State private var showTaskPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(goal.title).goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary).padding(.top, 8)
                    Text("改安排，先看影响。") .goalJourneyText(.title).padding(.top, 8).padding(.bottom, 12)
                    if let draft = Binding($payload) {
                        GoalPlanCriteriaFields(payload: draft)
                        GoalJourneyFormSection(title: "各项来源与要求") {
                            ForEach(draft.bindings) { binding in GoalBindingRequirementEditor(binding: binding) }
                            linkingActions
                        }
                        GoalFundScheduleFields(payload: draft)
                        preview
                        Toggle("我确认采用本目标的新约定", isOn: $confirmed)
                            .goalJourneyText(.supporting).padding(.vertical, 16).accessibilityIdentifier("goal-plan-confirm")
                        if let error { Text(error).goalJourneyText(.supporting).foregroundStyle(Color.holoToolError).padding(.bottom, 12) }
                        Button(saving ? "保存中…" : "确认采用新版本") { save() }
                            .buttonStyle(GoalJourneyPrimaryStyle()).disabled(!confirmed || !changed || saving)
                            .accessibilityIdentifier("goal-plan-save")
                        Button("取消，沿用原要求") { cancel() }
                            .goalJourneyText(.supporting).frame(maxWidth: .infinity, minHeight: 44).disabled(saving)
                    } else if let error {
                        Text(error).goalJourneyText(.supporting).foregroundStyle(Color.holoToolError)
                    } else { ProgressView("正在读取约定").padding(.vertical, 20) }
                }.padding(.horizontal, GoalJourneyStyle.pageInset).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.holoToolBackground).foregroundStyle(Color.holoToolText).tint(GoalJourneyStyle.action)
            .navigationTitle("调整本目标约定").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { cancel() }.disabled(saving) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成输入") {
                        #if canImport(UIKit)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        #else
                        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSResponder.resignFirstResponder), with: nil)
                        #endif
                    }
                }
            }
            .sheet(isPresented: $showHabitPicker) {
                NavigationStack {
                    List(HabitRepository.shared.activeHabits, id: \.id) { habit in
                        Button(habit.name) { add(id: habit.id, type: .habit, title: habit.name); showHabitPicker = false }
                    }.navigationTitle("选择已有习惯")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showHabitPicker = false } } }
                }
            }
            .sheet(isPresented: $showTaskPicker) {
                NavigationStack {
                    List(TodoRepository.shared.activeTasks, id: \.id) { task in
                        Button(task.title) { add(id: task.id, type: .task, title: task.title); showTaskPicker = false }
                    }.navigationTitle("选择已有任务")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showTaskPicker = false } } }
                }
            }
        }
        .onChange(of: payload) { _, next in changed = initialPayload != nil && next != initialPayload }
        .interactiveDismissDisabled(changed || saving)
        .unsavedChangesAlert(isPresented: $showDiscard) { dismiss() }
        .task {
            do {
                let resolved = try GoalPlanResolver.resolveCurrentPlan(goal: goal, in: CoreDataStack.shared.viewContext, persist: true)
                var draft = resolved.payload
                // 旧版限制在编辑草稿内转为同一项局部要求，避免保存后出现两个相互冲突的上限。
                for constraint in draft.constraints {
                    guard let index = draft.bindings.firstIndex(where: { $0.id == constraint.bindingID }), draft.bindings[index].requirement == nil else { continue }
                    let habit = constraint.habitID.flatMap { HabitRepository.shared.findHabit(by: $0) }
                    draft.bindings[index].requirement = GoalBindingRequirement(metric: habit?.isCheckInType == true ? .eventCount : .sum,
                        target: constraint.limitValue, comparison: .stayBelow, windowDays: constraint.windowDays)
                }
                draft.constraints.removeAll { rule in draft.bindings.contains { $0.id == rule.bindingID && $0.requirement != nil } }
                initialPayload = draft; payload = draft; baseID = resolved.revisionID
            } catch { self.error = GoalPlanEditService.message(for: error) }
        }
    }
    private func cancel() { if changed { showDiscard = true } else { dismiss() } }

    private var linkingActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 20))
        return layout {
            Button("关联已有习惯") { showHabitPicker = true }.frame(minHeight: 44)
            Button("关联已有任务") { showTaskPicker = true }.frame(minHeight: 44)
        }.goalJourneyText(.supporting)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("采用后会改变").goalJourneyText(.body).foregroundStyle(Color.holoToolText)
            if let initialPayload, let payload {
                let changes = GoalPlanEditPresentation.changes(from: initialPayload, to: payload)
                if changes.isEmpty { Text("还没有修改，当前约定继续生效。") }
                ForEach(changes, id: \.self) { Text($0) }
            }
            Text("只影响本目标。实际记录、共享习惯默认要求和其他目标保持原值。")
        }.goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            .padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(GoalJourneyStyle.inset, in: RoundedRectangle(cornerRadius: 13))
            .accessibilityIdentifier("goal-plan-change-preview")
    }
    private func add(id: UUID, type: GoalPlanBindingEntityType, title: String) {
        guard payload?.bindings.contains(where: { $0.entityType == type && $0.entityID == id && $0.isActive }) != true else { return }
        payload?.bindings.append(GoalPlanBindingV2(id: .init(), entityType: type, entityID: id, role: .action, displayTitle: title, isGoalOwned: false))
        changed = true
    }
    private func save() {
        guard let payload, let baseID, !saving else { return }; saving = true
        defer { saving = false }
        do {
            try GoalPlanEditService.save(goalID: goal.id, baseRevisionID: baseID, payload: payload, operationID: operationID, successChangeConfirmed: confirmed)
            dismiss()
        } catch { self.error = GoalPlanEditService.message(for: error) }
    }
}

private struct GoalBindingRequirementEditor: View {
    @Binding var binding: GoalPlanBindingV2
    private var metrics: [GoalRequirementMetric] {
        guard let id = binding.entityID, let habit = HabitRepository.shared.findHabit(by: id) else { return [.recordedDays, .eventCount, .sum, .latest] }
        return habit.isCheckInType ? [.recordedDays, .eventCount] : [.recordedDays, .eventCount, .sum, .latest]
    }
    private var rule: Binding<GoalBindingRequirement> {
        Binding(get: { binding.requirement ?? GoalBindingRequirement(metric: binding.entityType == .task ? .taskCompletion : .recordedDays, target: 1) }, set: { binding.requirement = $0 })
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                GoalJourneyField(title: "在本目标中的作用") {
                    Picker("在本目标中的作用", selection: $binding.role) {
                        Text("必要成果条件").tag(GoalPlanBindingRole.result)
                        Text("行动方法").tag(GoalPlanBindingRole.action)
                        Text("限制").tag(GoalPlanBindingRole.constraint)
                        Text("参考背景").tag(GoalPlanBindingRole.context)
                    }.labelsHidden()
                }
                if binding.entityType == .habit || binding.entityType == .task {
                    Toggle("设置本目标的要求", isOn: Binding(get: { binding.requirement != nil }, set: { binding.requirement = $0 ? rule.wrappedValue : nil }))
                    if binding.requirement != nil {
                        if binding.entityType == .habit {
                            GoalJourneyField(title: "读取什么") {
                                Picker("读取什么", selection: rule.metric) {
                                    ForEach(metrics, id: \.self) { metric in Text(metric.title).tag(metric) }
                                }.labelsHidden()
                            }
                        }
                        if binding.entityType == .task { Text("按原任务是否完成判断") }
                        else {
                            GoalJourneyField(title: "本目标要求 · " + GoalPlanEditPresentation.unit(for: binding)) {
                                TextField("本目标要求", value: rule.target, format: .number).keyboardType(.decimalPad)
                                    .accessibilityIdentifier("goal-plan-binding-target-" + binding.id.uuidString)
                            }
                            GoalJourneyField(title: "怎样判断") {
                                Picker("怎样判断", selection: rule.comparison) {
                                    Text("至少达到").tag(GoalResultComparison.reach)
                                    Text("不超过").tag(GoalResultComparison.stayBelow)
                                }.labelsHidden()
                            }
                        }
                        if binding.entityType == .habit {
                            Toggle("按本自然月", isOn: rule.calendarMonth)
                            if !rule.wrappedValue.calendarMonth { Stepper("最近 \(rule.wrappedValue.windowDays) 天", value: rule.windowDays, in: 1...366) }
                            Toggle("只看已结束的归属日", isOn: rule.closedDaysOnly)
                        }
                    }
                }
                Button(binding.isActive ? "结束本目标的关联" : "恢复关联", role: binding.isActive ? .destructive : nil) { binding.endedAt = binding.isActive ? Date() : nil }
                    .frame(minHeight: 44)
            }.goalJourneyText(.supporting).padding(.vertical, 12)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(binding.displayTitle ?? "来源").goalJourneyText(.row).foregroundStyle(Color.holoToolText)
                Text(GoalPlanEditPresentation.summary(binding)).goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
            }.padding(.vertical, 13).frame(minHeight: 68, alignment: .leading)
        }.overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
            .accessibilityIdentifier("goal-plan-binding-" + binding.id.uuidString)
    }
}

/// 影响预览只比较计划版本，不对当前观测或原始记录做估算写回。
enum GoalPlanEditPresentation {
    static func unit(for binding: GoalPlanBindingV2) -> String {
        switch binding.requirement?.metric {
        case .recordedDays: return "天"
        case .eventCount: return "次"
        case .taskCompletion: return "完成状态"
        default: return binding.entityID.flatMap { HabitRepository.shared.findHabit(by: $0)?.unitText } ?? "数值"
        }
    }
    static func summary(_ binding: GoalPlanBindingV2) -> String {
        guard binding.isActive else { return "本目标的关联已结束" }
        let role = switch binding.role { case .result: "必要成果"; case .action: "行动方法"; case .constraint: "限制"; case .context: "参考背景" }
        guard let r = binding.requirement else { return role + " · 读取原记录" }
        if r.metric == .taskCompletion { return role + " · 原任务完成" }
        let window = r.calendarMonth ? "本月" : "最近\(r.windowDays)天"
        let comparison = r.comparison == .stayBelow || r.comparison == .trendDown ? "不超过" : "至少"
        return role + " · " + window + " " + comparison + GoalMetricEvaluator.formatValue(r.target) + " " + unit(for: binding) + (r.closedDaysOnly ? " · 已结束日" : "")
    }
    static func changes(from old: GoalPlanPayloadV2, to new: GoalPlanPayloadV2) -> [String] {
        var result: [String] = []
        if old.intent.successCriteria != new.intent.successCriteria { result.append("成功条件：" + (new.intent.successCriteria ?? "未填写")) }
        if old.resultSource?.targetValue != new.resultSource?.targetValue {
            result.append("成果要求：" + (old.resultSource?.targetValue.map(GoalMetricEvaluator.formatValue) ?? "未设置") + " → " + (new.resultSource?.targetValue.map(GoalMetricEvaluator.formatValue) ?? "未设置") + " " + (new.resultSource?.unit ?? ""))
        }
        if old.resultSource?.ledgerScope != new.resultSource?.ledgerScope {
            let name = new.resultSource?.ledgerScope?.accountID.flatMap { id in FinanceRepository.shared.getAccounts().first { $0.id == id }?.name } ?? "全账本净结余增加"
            result.append("资金来源改为：" + name)
        }
        for binding in new.bindings {
            let previous = old.bindings.first { $0.id == binding.id }
            guard previous != binding else { continue }
            result.append((binding.displayTitle ?? "来源") + "：" + (previous.map(summary) ?? "未关联") + " → " + summary(binding))
        }
        for (index, installment) in new.fundSchedule.enumerated() where old.fundSchedule.indices.contains(index) && old.fundSchedule[index] != installment {
            result.append(GoalAnalysisSection.dayText(installment.dueDate) + "计划存入：" + GoalJourneyNarrative.money(old.fundSchedule[index].amount) + " → " + GoalJourneyNarrative.money(installment.amount))
        }
        return result
    }
}
