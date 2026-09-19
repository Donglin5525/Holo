//
//  CategoryDeletionImpactView.swift
//  Holo
//
//  二级分类删除的影响处理页（方案 §3.2）。
//
//  输入是纯值快照（CategoryDeletionImpactSnapshot），全程不持有托管对象；
//  转移目标由用户主动选择（不预选「待分类」）；一并删除需二次精确确认；
//  提交前策略层校验阻塞项，仓库层再校验版本指纹，过期即拒绝并提示重新发起。
//

import SwiftUI
import OSLog

struct CategoryDeletionImpactView: View {
    @Environment(\.dismiss) private var dismiss
    private let repository = FinanceRepository.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "CategoryDeletion")

    let snapshot: CategoryDeletionImpactSnapshot
    let sourceName: String
    let sourceIcon: String
    let sourceColor: Color
    let sourceType: TransactionType
    /// 删除完成（成功）回调；错误由本页呈现后一并结束
    let onDeleted: () -> Void

    private enum HandlingOption { case move, deleteAlong }

    @State private var option: HandlingOption = .move
    @State private var targetCandidate: CategoryMoveCandidate?
    @State private var candidates: [CategoryMoveCandidate] = []
    @State private var targetContext: CategoryDeletionPolicy.SubmissionContext?
    @State private var budgetDecisions: [UUID: BudgetConflictResolution] = [:]
    @State private var visibleLimit = 100
    @State private var isLoadingCandidates = true
    @State private var isSubmitting = false
    @State private var showFinalConfirmation = false
    @State private var errorMessage: String?
    @State private var showStaleAlert = false

    // MARK: - 派生

    private var pendingCommand: CategoryDeletionCommand? {
        switch option {
        case .move:
            guard let target = targetCandidate else { return nil }
            return CategoryDeletionCommand(
                sourceCategoryID: snapshot.sourceCategoryID,
                expectedRevision: snapshot.sourceRevision,
                disposition: .secondary(.moveAll(
                    toCategoryID: target.id,
                    budgetConflicts: budgetDecisions
                ))
            )
        case .deleteAlong:
            return CategoryDeletionCommand(
                sourceCategoryID: snapshot.sourceCategoryID,
                expectedRevision: snapshot.sourceRevision,
                disposition: .secondary(.deleteWithReferences)
            )
        }
    }

    private var blockers: [CategoryDeletionBlocker] {
        guard let command = pendingCommand else {
            return snapshot.blockers
        }
        return CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot,
            command: command,
            context: targetContext ?? CategoryDeletionPolicy.SubmissionContext()
        )
    }

    /// 转移方式下探测到的预算冲突（选定目标后才有）
    private var budgetConflicts: [BudgetImpactItem] {
        guard let context = targetContext else { return [] }
        let conflictIDs = Set(CategoryDeletionPolicy.budgetConflicts(
            moving: snapshot.budgets.map(\.conflictProbe),
            intoTarget: context.targetBudgetProbes
        ).map(\.budgetID))
        return snapshot.budgets.filter { conflictIDs.contains($0.id) }
    }

    private var canSubmit: Bool { blockers.isEmpty && !isSubmitting }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                impactSummarySection

                if !snapshot.blockers.isEmpty {
                    precheckBlockerSection
                }

                dispositionSection

                if option == .move, !budgetConflicts.isEmpty {
                    budgetConflictSection
                }

                transactionListSection
            }
            .navigationTitle(String(localized: "删除「\(sourceName)」"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle, role: .destructive) {
                        if option == .deleteAlong {
                            showFinalConfirmation = true
                        } else {
                            Task { await submit() }
                        }
                    }
                    // destructive 描边样式会覆盖 foregroundStyle，用透明度表达不可提交
                    .opacity(canSubmit ? 1 : 0.35)
                    .disabled(!canSubmit)
                }
            }
            .task { await loadCandidates() }
            .onChange(of: targetCandidate) { _, newValue in
                budgetDecisions = [:]
                targetContext = nil
                if let target = newValue {
                    Task { await loadSubmissionContext(for: target.id) }
                }
            }
            .alert(String(localized: "错误"), isPresented: .constant(errorMessage != nil)) {
                Button(String(localized: "确定")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(String(localized: "确认一并删除"), isPresented: $showFinalConfirmation) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "删除 \(snapshot.liveTransactions.count) 笔和分类"), role: .destructive) {
                    Task { await submit() }
                }
            } message: {
                Text(String(localized: "将删除 \(snapshot.liveTransactions.count) 笔账目、\(snapshot.budgets.count) 项预算和 \(snapshot.spendingProjects.count) 项固定支出，与分类一同移入回收站，30 天内可恢复。固定支出的未来自动记账将停止。"))
            }
            .alert(String(localized: "分类数据已变化"), isPresented: $showStaleAlert) {
                Button(String(localized: "知道了")) {
                    dismiss()
                }
            } message: {
                Text(String(localized: "打开此页面期间该分类的数据发生了变化，请返回分类列表重新发起删除。"))
            }
        }
    }

    // MARK: - 区块

    private var impactSummarySection: some View {
        Section {
            HStack(spacing: HoloSpacing.md) {
                CategoryIconBadge(iconName: sourceIcon, color: sourceColor, diameter: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "\(snapshot.liveTransactions.count) 笔账目，合计 \(totalAmountText)"))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(summaryDetailText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var precheckBlockerSection: some View {
        Section(String(localized: "需要先处理")) {
            ForEach(Array(snapshot.blockers), id: \.self) { blocker in
                Label(blockerText(blocker), systemImage: "exclamationmark.triangle.fill")
                    .font(.holoCaption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var dispositionSection: some View {
        Section(String(localized: "处理方式")) {
            optionRow(
                .move,
                title: String(localized: "转移后删除分类"),
                subtitle: String(localized: "保留账目与关联配置，转移到其他分类")
            )
            if option == .move {
                NavigationLink {
                    CategoryMoveTargetPicker(candidates: candidates, selection: $targetCandidate)
                } label: {
                    HStack {
                        Text(String(localized: "转移到"))
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Text(targetCandidate?.name ?? String(localized: "请选择"))
                            .foregroundColor(targetCandidate == nil ? .holoTextPlaceholder : .holoTextSecondary)
                    }
                }
                .accessibilityLabel(String(localized: "选择转移目标分类"))
            }
            optionRow(
                .deleteAlong,
                title: String(localized: "账目与分类一起删除"),
                subtitle: String(localized: "全部进入回收站，30 天内可恢复")
            )
        }
    }

    private var budgetConflictSection: some View {
        Section(String(localized: "预算冲突")) {
            Text(String(localized: "目标分类已有同账户同周期的预算，请为以下预算选择处理方式："))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            ForEach(budgetConflicts) { budget in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(budgetLineText(budget))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Picker(String(localized: "预算处理"), selection: binding(for: budget.id)) {
                        Text(String(localized: "金额并入目标预算")).tag(BudgetConflictResolution.mergeAmounts)
                        Text(String(localized: "保留目标预算，此预算随分类回收")).tag(BudgetConflictResolution.keepTarget)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
    }

    private var transactionListSection: some View {
        Section(String(localized: "账目明细（共 \(snapshot.liveTransactions.count) 笔）")) {
            ForEach(snapshot.liveTransactions.prefix(visibleLimit)) { item in
                transactionRow(item)
            }
            if snapshot.liveTransactions.count > visibleLimit {
                Button(String(localized: "显示更多（还有 \(snapshot.liveTransactions.count - visibleLimit) 笔）")) {
                    visibleLimit += 200
                }
            }
        }
    }

    // MARK: - 组件

    private func optionRow(_ value: HandlingOption, title: String, subtitle: String) -> some View {
        Button {
            option = value
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(subtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: option == value ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(option == value ? .holoPrimary : .holoTextPlaceholder)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(option == value ? .isSelected : [])
    }

    private func transactionRow(_ item: TransactionImpactItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                HStack(spacing: 4) {
                    Text(Self.dateText(for: item.date))
                    if let account = item.accountName {
                        Text("· \(account)")
                    }
                    if let label = item.installmentText {
                        Text("· \(label)")
                    }
                    if let source = item.importSourceText {
                        Text("· \(source)")
                    }
                }
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            }
            Spacer()
            Text(amountText(item.signedAmount))
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 动作

    private func binding(for budgetID: UUID) -> Binding<BudgetConflictResolution> {
        Binding(
            get: { budgetDecisions[budgetID] ?? .mergeAmounts },
            set: { budgetDecisions[budgetID] = $0 }
        )
    }

    @MainActor
    private func loadCandidates() async {
        defer { isLoadingCandidates = false }
        do {
            // 影响页打开即进入预检阶段：确保「待分类」这个安全暂存位可选（方案 §3.4，
            // 纯浏览的选择器不隐式写库，这里用户已表达删除意图）
            _ = repository.ensurePendingCategory(type: sourceType)
            let all = try await repository.categoryMoveCandidates(
                excluding: snapshot.sourceFamilyIDs,
                type: sourceType
            )
            candidates = CategoryDeletionPolicy.moveTargetCandidates(
                from: all,
                sourceFamilyIDs: snapshot.sourceFamilyIDs,
                sourceTypeRaw: snapshot.sourceTypeRaw,
                pendingCategoryNames: [FinancePendingCategory.currentName]
            )
        } catch {
            Self.logger.error("加载转移候选失败：\(error.localizedDescription)")
            candidates = []
        }
    }

    /// 选定目标后现查目标侧冲突上下文（预算探针）
    @MainActor
    private func loadSubmissionContext(for targetID: UUID) async {
        let context = try? await repository.categoryDeletionSubmissionContext(
            for: .secondary(.moveAll(toCategoryID: targetID, budgetConflicts: [:]))
        )
        targetContext = context ?? CategoryDeletionPolicy.SubmissionContext()
    }

    @MainActor
    private func submit() async {
        guard let command = pendingCommand else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await repository.executeCategoryDeletion(command)
            onDeleted()
            dismiss()
        } catch FinanceError.staleCategoryDeletion {
            showStaleAlert = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 文案

    private var submitTitle: String {
        switch option {
        case .move:
            return String(localized: "转移 \(snapshot.liveTransactions.count) 笔并删除分类")
        case .deleteAlong:
            return String(localized: "删除 \(snapshot.liveTransactions.count) 笔和分类")
        }
    }

    private var summaryDetailText: String {
        var parts: [String] = []
        if snapshot.recycledTransactionCount > 0 {
            parts.append(String(localized: "回收站中 \(snapshot.recycledTransactionCount) 笔"))
        }
        if !snapshot.budgets.isEmpty {
            parts.append(String(localized: "\(snapshot.budgets.count) 项预算"))
        }
        if !snapshot.spendingProjects.isEmpty {
            parts.append(String(localized: "\(snapshot.spendingProjects.count) 项固定支出"))
        }
        if !snapshot.learnedMappings.isEmpty {
            parts.append(String(localized: "\(snapshot.learnedMappings.count) 条智能分类规则"))
        }
        return parts.isEmpty
            ? String(localized: "删除前请选择账目与配置的去向")
            : parts.joined(separator: " · ")
    }

    private func blockerText(_ blocker: CategoryDeletionBlocker) -> String {
        switch blocker {
        case .typeMismatchedTransactions(let count):
            return String(localized: "有 \(count) 笔账目的收支类型与分类不一致（旧数据异常），请先在账目中修复后再删除")
        case .unresolvedBudgetConflicts(let count):
            return String(localized: "有 \(count) 项预算冲突待选择处理方式")
        case .unresolvedChildConflicts(let count):
            return String(localized: "有 \(count) 个同名子分类冲突待解决")
        case .childrenMissingDisposition(let count):
            return String(localized: "有 \(count) 个子分类未选择去向")
        }
    }

    private func budgetLineText(_ budget: BudgetImpactItem) -> String {
        let periodText = BudgetPeriod(rawValue: budget.periodRaw)?.displayName ?? budget.periodRaw
        let account = budget.accountName ?? String(localized: "未命名账户")
        return String(localized: "\(account) · \(periodText) · \(amountText(budget.amount))")
    }

    private var totalAmountText: String {
        amountText(snapshot.liveTransactionTotal)
    }

    private func amountText(_ value: Decimal) -> String {
        NumberFormatter.currency.string(from: NSDecimalNumber(decimal: abs(value))) ?? ""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    private static func dateText(for date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
