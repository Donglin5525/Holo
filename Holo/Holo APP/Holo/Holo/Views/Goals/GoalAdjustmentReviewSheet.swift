//
//  GoalAdjustmentReviewSheet.swift
//  Holo
//
//  目标闭环·修正差异单（最终规格 §3.4 / R23 R24 R28 R32）
//
//  结构化差异：当前安排 → 建议安排 → 原因 → 适用期限 → 影响对象；逐项可取消、可轻编辑，
//  详细设置回原模块编辑器。成果标准/总额/期限变更有独立的第二步确认；改既有全局预算
//  展示影响范围、当前周期已花与剩余额度。只点阅读/关闭/离开不修改任何对象；
//  确认后同 goalID 真实写回所选原模块安排（GoalAdjustmentCommitService 单事务）。
//

import SwiftUI

struct GoalAdjustmentReviewContext: Identifiable {
    let goal: Goal
    let draft: GoalAdjustmentDraftV2
    let state: GoalReviewState
    var id: UUID { draft.draftID }
}

struct GoalAdjustmentReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: GoalAdjustmentReviewContext
    let onApplied: () -> Void

    @State private var draft: GoalAdjustmentDraftV2
    @State private var criteriaConfirmed = false
    @State private var budgetConfirmed = false
    @State private var isApplying = false
    @State private var errorText: String?
    @State private var needsRefresh = false
    @State private var appliedSummary: String?

    init(context: GoalAdjustmentReviewContext, onApplied: @escaping () -> Void) {
        self.context = context
        self.onApplied = onApplied
        _draft = State(initialValue: context.draft)
    }

    private var selectedCount: Int { draft.selectedOperations.count }
    private var containsCriteriaChange: Bool {
        draft.selectedOperations.contains { op in
            op.kind == .changeSuccessCriteria || (op.kind == .updateHabit && context.state.plan.payload.bindings.contains { $0.entityID == op.targetEntityID && $0.role == .result })
        }
    }
    private var containsBudgetUpdate: Bool { draft.selectedOperations.contains { $0.kind == .updateBudget } }
    private var containsFundSchedule: Bool { draft.selectedOperations.contains { $0.kind == .updateFundSchedule } }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    headerCard
                    ForEach($draft.operations) { $op in
                        GoalAdjustmentOperationRow(op: $op)
                    }
                    if containsFundSchedule { fundRecomputeCard }
                    if containsCriteriaChange { criteriaConfirmCard }
                    if containsBudgetUpdate { budgetConfirmCard }
                    if let appliedSummary { appliedCard }
                    if let errorText { errorCard }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 120)
            }
            .background(Color.holoToolBackground)
            .navigationTitle("调整这份计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isApplying)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .holoSheetShell()
            .sheetDismissGuard(onAttempt: { dismiss() })
            .interactiveDismissDisabled(isApplying)
        }
    }

    // MARK: - 头部

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Label {
                Text("目标「\(context.goal.title)」· 计划第 \(context.state.plan.revisionNumber) 版")
                    .holoText(.body).fontWeight(.semibold)
            } icon: {
                Image(systemName: "target").foregroundColor(.holoPrimary)
            }
            Text("按报告建议列出差异，逐项确认后才会真正改动；取消的项不会提交。确认前随时可以关闭，原计划不受影响。")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
            if draft.isExpired(at: Date()) {
                Label { Text("这份建议已超过有效期，需要重新分析后再确认。") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundColor(.holoToolError).holoText(.supporting)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - 期次重算说明（R26/R27）

    private var fundRecomputeCard: some View {
        let preview = fundPreview
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionTitle(icon: "creditcard", title: String(localized: "资金期次按当前情况重算"))
            if let preview {
                Text(preview)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
                Text("期次金额会按确认时点的真实资金自动重算，不采用报告里的旧数字；总目标金额不会因此自动降低。")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            } else {
                Text("当前资金未知（来源待补齐），期次保持建议日期、金额暂无法重算。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoPrimary.opacity(0.2), lineWidth: 1))
    }

    private var fundPreview: String? {
        guard let funds = context.state.snapshot.result.moneyValue,
              let schedule = draft.selectedOperations.first(where: { $0.kind == .updateFundSchedule })?.fundSchedule,
              let criteriaTarget = draft.selectedOperations.first(where: { $0.kind == .changeSuccessCriteria })?.criteriaChange?.newTargetValue
                ?? context.state.plan.payload.resultSource?.targetValue else { return nil }
        let outcome = GoalFundScheduleMath.evaluate(target: Decimal(criteriaTarget), currentFunds: funds,
                                                    schedule: schedule, cutoff: Date(),
                                                    deadline: context.state.plan.payload.intent.deadline)
        guard let perInstallment = outcome.suggestedPerInstallment else {
            return String(localized: "剩余 \(outcome.remainingInstallments.count) 期；已无剩余期次或已过截止，不能按期次分摊")
        }
        let feasibility = GoalFundScheduleMath.feasibility(suggestedPerInstallment: perInstallment,
                                                           historicalContributions: [],
                                                           expectedReliefPerInstallment: nil)
        var text = String(localized: "当前资金 \(GoalEvaluationSnapshotBuilder.moneyText(funds))，剩余 \(outcome.remainingInstallments.count) 期 → 每期应存 \(GoalEvaluationSnapshotBuilder.moneyText(perInstallment))")
        if let uncovered = feasibility.uncoveredAfterRelief {
            text += String(localized: "（若控制消费只能释放部分，仍有缺口需要另行安排，预计节省不会自动变成到账）")
            _ = uncovered
        }
        return text
    }

    // MARK: - 单独确认：成果标准 / 预算（R28 / R32）

    private var criteriaConfirmCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionTitle(icon: "exclamationmark.shield", title: String(localized: "修改成果标准（需单独确认）"))
            Text("这份调整包含对「想达到什么」的修改（成功标准 / 总目标金额 / 截止时间）。它只在你明确勾选下才会生效；不勾选则其余调整照常应用，原目标保持不变。")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
            Toggle(isOn: $criteriaConfirmed) {
                Text("我确认修改成果标准 / 总额 / 期限")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
            }
            .tint(.holoPrimary)
            .accessibilityIdentifier("goal.adjust.criteriaConfirm")
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolError.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoToolError.opacity(0.25), lineWidth: 1))
    }

    private var budgetConfirmCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionTitle(icon: "creditcard.fill", title: String(localized: "修改财务预算（需单独确认）"))
            if let budgetStatus = existingBudgetStatus {
                Text("这是财务模块的全局约定，影响该账户\(periodName)的全部支出，不只是本目标。当前周期已花 \(GoalEvaluationSnapshotBuilder.moneyText(budgetStatus.spent)) / 剩余 \(GoalEvaluationSnapshotBuilder.moneyText(budgetStatus.remaining))；历史支出不会回改。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            } else {
                Text("这是财务模块的全局约定，影响所选账户的全部支出，不只是本目标；历史支出不会回改。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
            Toggle(isOn: $budgetConfirmed) {
                Text("我确认修改这份预算")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
            }
            .tint(.holoPrimary)
            .accessibilityIdentifier("goal.adjust.budgetConfirm")
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
    }

    private var existingBudgetStatus: (spent: Decimal, remaining: Decimal)? {
        guard let rule = draft.selectedOperations.first(where: { $0.kind == .updateBudget })?.budgetRule,
              let budgetID = rule.reuseExistingBudgetID,
              let budget = try? BudgetRepository.shared.getBudgets(forAccount: rule.accountID).first(where: { $0.id == budgetID }),
              let status = BudgetRepository.shared.computeBudgetStatus(budget: budget) else { return nil }
        return (status.spentAmount, status.remainingAmount)
    }

    private var periodName: String {
        guard let period = draft.selectedOperations.first(where: { $0.kind == .updateBudget })?.budgetRule
            .flatMap({ BudgetPeriod(rawValue: $0.period) }) else { return "" }
        return period.displayName
    }

    private var appliedCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Label { Text(appliedSummary ?? "").holoText(.supporting).foregroundColor(.holoToolText) }
            icon: { Image(systemName: "checkmark.circle.fill").foregroundColor(.holoPrimary) }
            Text("新计划已生效（同一目标，新版本）；日常记录仍回原模块，下次回顾会同时看「调整是否执行」和「结果是否改善」。")
                .holoText(.metadata).foregroundColor(.holoToolTextSecondary)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var errorCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(errorText ?? "").holoText(.supporting)
                if needsRefresh {
                    Text("这份建议基于旧情况，需要重新分析刷新差异后再确认；原计划继续有效。")
                        .holoText(.metadata)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundColor(.holoToolError)
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: HoloSpacing.md) {
            Button("全部取消") {
                for index in draft.operations.indices { draft.operations[index].isSelected = false }
            }
            .foregroundColor(.holoToolTextSecondary)
            .disabled(isApplying || selectedCount == 0)

            Button {
                apply()
            } label: {
                HStack(spacing: 6) {
                    if isApplying { ProgressView().scaleEffect(0.8).tint(.white) }
                    Text(appliedSummary == nil ? String(localized: "确认应用 \(selectedCount) 项修改") : String(localized: "完成"))
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canApply ? Color.holoPrimary : Color.gray.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .disabled(!canApply || isApplying)
            .accessibilityIdentifier("goal.adjust.apply")
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoToolSurface)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
    }

    private var canApply: Bool {
        guard appliedSummary == nil else { return true }
        guard selectedCount > 0 else { return false }
        if containsCriteriaChange && !criteriaConfirmed { return false }
        if containsBudgetUpdate && !budgetConfirmed { return false }
        return true
    }

    private func apply() {
        if appliedSummary != nil { dismiss(); return }
        guard !isApplying else { return }
        isApplying = true
        errorText = nil
        needsRefresh = false
        let input = GoalAdjustmentCommitInput(goalID: context.goal.id, draft: draft,
                                              criteriaChangeConfirmed: criteriaConfirmed, now: Date())
        Task { @MainActor in
            do {
                let receipt = try await GoalAdjustmentCommitService.shared.commit(input: input)
                var summary = receipt.wasIdempotentReplay
                    ? String(localized: "这些修改此前已应用过，没有重复执行。")
                    : String(localized: "已应用 \(receipt.appliedOperationIDs.count) 项修改（计划第 \(receipt.revisionNumber) 版）。")
                if let perInstallment = receipt.recomputedPerInstallment {
                    summary += String(localized: "每期应存已按当前资金重算为 \(GoalEvaluationSnapshotBuilder.moneyText(perInstallment))。")
                }
                appliedSummary = summary
                isApplying = false
                onApplied()
            } catch let error as GoalAdjustmentCommitError {
                isApplying = false
                switch error {
                case .draftExpired:
                    needsRefresh = true
                    errorText = String(localized: "这份建议已过期。")
                case .sourceDigestChanged:
                    needsRefresh = true
                    errorText = String(localized: "报告之后相关数据变了（比如补记了资金），旧建议不能直接采纳。")
                case .baseRevisionChanged:
                    needsRefresh = true
                    errorText = String(localized: "计划已被更新过（本机或其他设备），这份建议基于旧版本。")
                case .concurrentBranchDetected:
                    needsRefresh = true
                    errorText = String(localized: "同一计划版本在多台设备上产生了不同修改，需要先核对实际安排、合并差异，暂不自动应用。")
                case .separateConfirmationRequired:
                    errorText = String(localized: "包含成果标准/总额/期限的修改，需要先勾选上面的单独确认。")
                case .goalMissing:
                    errorText = String(localized: "目标已不存在。")
                case .validation(let reason), .saveFailed(let reason):
                    errorText = String(localized: "没应用成功：\(reason)")
                case .objectMissing(let reason):
                    needsRefresh = true
                    errorText = reason
                case .budgetConflict:
                    errorText = String(localized: "这个账户同周期已有预算：请改为调整既有预算，或取消这项。")
                }
            } catch {
                isApplying = false
                errorText = String(localized: "没应用成功：\(error.localizedDescription)。内容还在，稍后再试。")
            }
        }
    }

    private func sectionTitle(icon: String, title: String) -> some View {
        Label { Text(title).holoText(.body).fontWeight(.semibold).foregroundColor(.holoToolText) }
        icon: { Image(systemName: icon).foregroundColor(.holoPrimary) }
    }
}

// MARK: - 单条操作行

struct GoalAdjustmentOperationRow: View {
    @Binding var op: GoalAdjustmentOperationV2

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Toggle("", isOn: $op.isSelected)
                    .labelsHidden()
                    .tint(.holoPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(for: op))
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)
                        .strikethrough(!op.isSelected, color: .holoToolTextSecondary)
                    if let affected = op.affectedObjectTitle {
                        Text("影响对象：\(affected)")
                            .holoText(.metadata)
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                Spacer()
                Text(Self.kindLabel(op.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(op.kind.requiresSeparateConfirmation ? .holoToolError : .holoPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((op.kind.requiresSeparateConfirmation ? Color.holoToolError : Color.holoPrimary).opacity(0.12))
                    .clipShape(Capsule())
            }

            if op.isSelected {
                diffLines
                editor
                if let reason = op.reason?.nilIfBlank {
                    Label { Text(reason).holoText(.metadata).foregroundColor(.holoToolTextSecondary) }
                        icon: { Image(systemName: "questionmark.circle") }
                }
                if let through = op.appliesThrough {
                    Label { Text("适用至 \(GoalAnalysisSection.dayText(through))") } icon: { Image(systemName: "calendar") }
                        .holoText(.metadata).foregroundColor(.holoToolTextSecondary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
        .accessibilityIdentifier("goal.adjust.row.\(op.id)")
    }

    @ViewBuilder
    private var diffLines: some View {
        if let current = op.currentSummary?.nilIfBlank, let proposed = op.proposedSummary?.nilIfBlank {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 6) {
                    Text("当前").holoText(.metadata).foregroundColor(.holoToolTextSecondary)
                    Text(current).holoText(.metadata).foregroundColor(.holoToolTextSecondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.down").font(.system(size: 9)).foregroundColor(.holoPrimary)
                    Text("建议").holoText(.metadata).foregroundColor(.holoPrimary)
                    Text(proposed).holoText(.metadata).foregroundColor(.holoToolText)
                }
            }
        } else if let proposed = op.proposedSummary?.nilIfBlank {
            Text(proposed).holoText(.metadata).foregroundColor(.holoToolText)
        }
    }

    /// 行内轻编辑（详细设置回原模块编辑器）：任务标题/日期、习惯目标、回顾节奏、成果标准数值
    @ViewBuilder
    private var editor: some View {
        switch op.kind {
        case .createTask, .updateTask:
            if op.taskSpec != nil {
                TextField("任务标题", text: Binding(
                    get: { op.taskSpec?.title ?? "" },
                    set: { op.taskSpec?.title = $0 }
                ))
                .holoText(.supporting)
                .padding(HoloSpacing.sm)
                .background(Color.holoToolBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                DatePicker("截止", selection: Binding(
                    get: { op.taskSpec?.dueDate ?? Date() },
                    set: { op.taskSpec?.dueDate = $0 }
                ), displayedComponents: .date)
                .holoText(.supporting)
            }
        case .createHabit, .updateHabit:
            if op.habitSpec != nil, op.kind == .updateHabit {
                Stepper(value: Binding(
                    get: { Int(op.habitSpec?.targetValue ?? 1) },
                    set: { op.habitSpec?.targetValue = Double($0) }
                ), in: 0...999) {
                    Text("目标 \(Int(op.habitSpec?.targetValue ?? 1)) \(op.habitSpec?.unit ?? "")")
                        .holoText(.supporting)
                }
            }
        case .updateReview:
            if op.review?.cadenceDays != nil {
                Picker("回顾周期", selection: Binding(
                    get: { op.review?.cadenceDays ?? 7 },
                    set: { op.review?.cadenceDays = $0 }
                )) {
                    Text("每周").tag(7)
                    Text("每两周").tag(14)
                    Text("每月").tag(30)
                }
                .pickerStyle(.segmented)
            }
        case .changeSuccessCriteria:
            if op.criteriaChange?.newTargetValue != nil {
                HStack(spacing: HoloSpacing.sm) {
                    Text("新目标值").holoText(.supporting).foregroundColor(.holoToolTextSecondary)
                    TextField("新目标值", value: Binding(
                        get: { op.criteriaChange?.newTargetValue },
                        set: { op.criteriaChange?.newTargetValue = $0 }
                    ), format: .number)
                    .keyboardType(.decimalPad)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoToolBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                }
            }
            if op.criteriaChange?.newDeadline != nil {
                DatePicker("新期限", selection: Binding(
                    get: { op.criteriaChange?.newDeadline ?? Date() },
                    set: { op.criteriaChange?.newDeadline = $0 }
                ), displayedComponents: .date)
                .holoText(.supporting)
            }
        case .updateFundSchedule:
            Text("金额按当前资金自动重算（见下方说明），日期保持建议值。")
                .holoText(.metadata).foregroundColor(.holoToolTextSecondary)
        default:
            EmptyView()
        }
    }

    static func title(for op: GoalAdjustmentOperationV2) -> String {
        op.affectedObjectTitle ?? op.proposedSummary ?? kindLabel(op.kind)
    }

    static func kindLabel(_ kind: GoalAdjustmentOperationKind) -> String {
        switch kind {
        case .createTask: return String(localized: "新建任务")
        case .reuseTask: return String(localized: "关联既有任务")
        case .updateTask: return String(localized: "调整任务")
        case .createHabit: return String(localized: "新建习惯")
        case .reuseHabit: return String(localized: "关联既有习惯")
        case .updateHabit: return String(localized: "调整习惯")
        case .createBudget: return String(localized: "新建预算")
        case .updateBudget: return String(localized: "调整预算")
        case .endBinding: return String(localized: "结束一项安排")
        case .replaceBinding: return String(localized: "替换一项安排")
        case .updateFundSchedule: return String(localized: "调整资金期次")
        case .updateReview: return String(localized: "调整回顾节奏")
        case .changeSuccessCriteria: return String(localized: "修改成果标准")
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
