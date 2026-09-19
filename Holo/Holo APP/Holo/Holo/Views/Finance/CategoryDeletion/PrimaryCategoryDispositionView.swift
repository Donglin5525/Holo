//
//  PrimaryCategoryDispositionView.swift
//  Holo
//
//  一级分类（分组）删除的处理页（方案 §3.3）。
//
//  一级是子分类的容器：默认方式是把子分类整体迁到另一个一级分类
//  （账目仍指原二级，语义损失最小）；危险方式是逐子分类配置去向后
//  删除整组。同名冲突（合并/保留两个）在选定目标后显式解决。
//

import SwiftUI
import OSLog

struct PrimaryCategoryDispositionView: View {
    @Environment(\.dismiss) private var dismiss
    private let repository = FinanceRepository.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "CategoryDeletion")

    let snapshot: CategoryDeletionImpactSnapshot
    let sourceName: String
    let sourceIcon: String
    let sourceColor: Color
    let sourceType: TransactionType
    let onDeleted: () -> Void

    private enum Mode { case moveChildren, disposeGroup }

    @State private var mode: Mode = .moveChildren
    @State private var targetParent: CategoryMoveCandidate?
    @State private var parentCandidates: [CategoryMoveCandidate] = []
    @State private var targetSiblingNames: [String] = []
    @State private var childConflicts: [UUID: ChildConflictResolution] = [:]
    @State private var childDispositions: [UUID: SecondaryCategoryDisposition] = [:]
    @State private var childTargets: [UUID: CategoryMoveCandidate] = [:]
    @State private var moveCandidates: [CategoryMoveCandidate] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showStaleAlert = false
    @State private var showFinalConfirmation = false

    // MARK: - 派生

    private var pendingCommand: CategoryDeletionCommand? {
        switch mode {
        case .moveChildren:
            guard let target = targetParent else { return nil }
            return CategoryDeletionCommand(
                sourceCategoryID: snapshot.sourceCategoryID,
                expectedRevision: snapshot.sourceRevision,
                disposition: .primary(.moveChildren(
                    toParentID: target.id,
                    conflicts: childConflicts
                ))
            )
        case .disposeGroup:
            guard snapshot.childCategories.allSatisfy({ childDispositions[$0.id] != nil }) else {
                return nil
            }
            return CategoryDeletionCommand(
                sourceCategoryID: snapshot.sourceCategoryID,
                expectedRevision: snapshot.sourceRevision,
                disposition: .primary(.disposeChildren(childDispositions))
            )
        }
    }

    private var submissionContext: CategoryDeletionPolicy.SubmissionContext {
        CategoryDeletionPolicy.SubmissionContext(targetSiblingNames: targetSiblingNames)
    }

    private var blockers: [CategoryDeletionBlocker] {
        guard let command = pendingCommand else {
            return snapshot.blockers + [.childrenMissingDisposition(count: 1)]
        }
        return CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot,
            command: command,
            context: submissionContext
        )
    }

    /// 迁移方式下探测到的同名子分类冲突
    private var nameConflictedChildren: [CategoryImpactItem] {
        guard targetParent != nil else { return [] }
        let conflicts = CategoryDeletionPolicy.childNameConflicts(
            childNames: snapshot.childCategories.map(\.name),
            targetSiblingNames: targetSiblingNames
        )
        return snapshot.childCategories.filter { conflicts.contains($0.name) }
    }

    private var canSubmit: Bool { blockers.isEmpty && !isSubmitting }

    private var totalTransactionCount: Int {
        snapshot.liveTransactions.count
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                summarySection
                blockerSection
                modeSection

                if mode == .moveChildren {
                    moveChildrenSection
                } else {
                    disposeGroupSection
                }
            }
            .navigationTitle(String(localized: "删除分组「\(sourceName)」"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle, role: .destructive) {
                        if mode == .disposeGroup {
                            showFinalConfirmation = true
                        } else {
                            Task { await submit() }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .task { await loadCandidates() }
            .onChange(of: targetParent) { _, newValue in
                childConflicts = [:]
                targetSiblingNames = []
                if let target = newValue {
                    Task { await loadSiblingNames(for: target.id) }
                }
            }
            .alert(String(localized: "错误"), isPresented: .constant(errorMessage != nil)) {
                Button(String(localized: "确定")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(String(localized: "分类数据已变化"), isPresented: $showStaleAlert) {
                Button(String(localized: "知道了")) { dismiss() }
            } message: {
                Text(String(localized: "打开此页面期间该分类的数据发生了变化，请返回分类列表重新发起删除。"))
            }
            .alert(String(localized: "确认删除整组"), isPresented: $showFinalConfirmation) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "删除分组与已选账目"), role: .destructive) {
                    Task { await submit() }
                }
            } message: {
                Text(String(localized: "分组、所选一并删除的账目与关联配置将一同移入回收站，30 天内可恢复。已选择转移的账目不受影响。"))
            }
        }
    }

    // MARK: - 区块

    @ViewBuilder
    private var blockerSection: some View {
        if !snapshot.blockers.isEmpty {
            Section(String(localized: "需要先处理")) {
                ForEach(Array(snapshot.blockers), id: \.self) { blocker in
                    Label(blockerText(blocker), systemImage: "exclamationmark.triangle.fill")
                        .font(.holoCaption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            HStack(spacing: HoloSpacing.md) {
                CategoryIconBadge(iconName: sourceIcon, color: sourceColor, diameter: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "\(snapshot.childCategories.count) 个子分类 · \(totalTransactionCount) 笔账目"))
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

    private var modeSection: some View {
        Section(String(localized: "处理方式")) {
            modeRow(
                .moveChildren,
                title: String(localized: "保留子分类，移到另一个一级分类"),
                subtitle: String(localized: "账目、预算与固定支出保持原二级分类不变"))
            modeRow(
                .disposeGroup,
                title: String(localized: "删除整个分组"),
                subtitle: String(localized: "逐个子分类选择账目去向或一并删除"))
        }
    }

    private var moveChildrenSection: some View {
        Group {
            Section {
                NavigationLink {
                    CategoryMoveTargetPicker(
                        candidates: parentCandidates,
                        selection: $targetParent
                    )
                } label: {
                    HStack {
                        Text(String(localized: "移动到"))
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Text(targetParent?.name ?? String(localized: "请选择一级分类"))
                            .foregroundColor(targetParent == nil ? .holoTextPlaceholder : .holoTextSecondary)
                    }
                }
                .accessibilityLabel(String(localized: "选择目标一级分类"))
            } header: {
                Text(String(localized: "目标一级分类（同\(sourceType == .expense ? "支出" : "收入")类型）"))
            } footer: {
                Text(String(localized: "子分类颜色将跟随新一级分类；所有账目仍指向原二级分类，不受影响。"))
            }

            if !nameConflictedChildren.isEmpty {
                Section(String(localized: "同名子分类")) {
                    Text(String(localized: "目标分类下已有同名子分类，请选择处理方式："))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    ForEach(nameConflictedChildren) { child in
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            Text(child.name)
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Picker(String(localized: "冲突处理"), selection: conflictBinding(for: child.id)) {
                                Text(String(localized: "合并到已有分类")).tag(ChildConflictResolution.mergeIntoExisting)
                                Text(String(localized: "保留两个并重命名")).tag(ChildConflictResolution.keepBothRenamed)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                }
            }
        }
    }

    private var disposeGroupSection: some View {
        Group {
            Section {
                Button(String(localized: "全部转到「\(FinancePendingCategory.currentName)」")) {
                    Task { await applyPendingToAll() }
                }
                .disabled(!hasUnconfiguredChild)
            } footer: {
                Text(String(localized: "快捷操作：所有子分类的账目与配置转移到「\(FinancePendingCategory.currentName)」。也可逐个选择转移目标或一并删除。"))
            }

            Section(String(localized: "子分类去向")) {
                ForEach(snapshot.childCategories) { child in
                    childDispositionRow(child)
                }
            }
        }
    }

    // MARK: - 组件

    private func modeRow(_ value: Mode, title: String, subtitle: String) -> some View {
        Button {
            mode = value
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
                Image(systemName: mode == value ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(mode == value ? .holoPrimary : .holoTextPlaceholder)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    @ViewBuilder
    private func childDispositionRow(_ child: CategoryImpactItem) -> some View {
        let choice = dispositionBinding(for: child.id).wrappedValue
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                CategoryIconBadge(
                    iconName: child.icon,
                    color: Color(hex: child.colorHex),
                    diameter: 32
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(childSummaryText(child))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                if childDispositions[child.id] != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.holoPrimary)
                }
            }
            Picker(String(localized: "\(child.name)去向"), selection: dispositionBinding(for: child.id)) {
                Text(String(localized: "转移到其他分类")).tag(DispositionChoice.move)
                Text(String(localized: "一并删除")).tag(DispositionChoice.deleteAlong)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if choice == .move {
                NavigationLink {
                    CategoryMoveTargetPicker(
                        candidates: moveCandidates,
                        selection: childTargetBinding(for: child.id),
                        autoDismiss: false
                    )
                } label: {
                    HStack {
                        Text(String(localized: "转移到"))
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Text(childTargets[child.id]?.name ?? String(localized: "请选择"))
                            .font(.holoBody)
                            .foregroundColor(childTargets[child.id] == nil ? .holoTextPlaceholder : .holoTextSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private enum DispositionChoice: String {
        case move
        case deleteAlong
    }

    private func dispositionBinding(for childID: UUID) -> Binding<DispositionChoice> {
        Binding(
            get: {
                if case .moveAll = childDispositions[childID] { return .move }
                if case .deleteWithReferences = childDispositions[childID] { return .deleteAlong }
                return .move
            },
            set: { choice in
                switch choice {
                case .move:
                    childDispositions[childID] = nil // 等待选择目标
                case .deleteAlong:
                    childDispositions[childID] = .deleteWithReferences
                }
            }
        )
    }

    private func childTargetBinding(for childID: UUID) -> Binding<CategoryMoveCandidate?> {
        Binding(
            get: { childTargets[childID] },
            set: { candidate in
                childTargets[childID] = candidate
                if let candidate {
                    childDispositions[childID] = .moveAll(
                        toCategoryID: candidate.id,
                        budgetConflicts: [:]
                    )
                }
            }
        )
    }

    private func conflictBinding(for childID: UUID) -> Binding<ChildConflictResolution> {
        Binding(
            get: { childConflicts[childID] ?? .mergeIntoExisting },
            set: { childConflicts[childID] = $0 }
        )
    }

    // MARK: - 动作

    private var hasUnconfiguredChild: Bool {
        snapshot.childCategories.contains { childDispositions[$0.id] == nil }
    }

    /// 批量快捷：全部子分类转移到「待分类」（必须由用户主动点击，不默认勾选）
    @MainActor
    private func applyPendingToAll() async {
        var candidates = moveCandidates
        if !candidates.contains(where: { $0.name == FinancePendingCategory.currentName }) {
            // 「待分类」尚未创建：先确保存在再刷新候选（方案 §3.4 预检阶段创建）
            _ = repository.ensurePendingCategory(type: sourceType)
            if let refreshed = try? await repository.categoryMoveCandidates(
                excluding: snapshot.sourceFamilyIDs,
                type: sourceType
            ) {
                candidates = CategoryDeletionPolicy.moveTargetCandidates(
                    from: refreshed,
                    sourceFamilyIDs: snapshot.sourceFamilyIDs,
                    sourceTypeRaw: snapshot.sourceTypeRaw,
                    pendingCategoryNames: [FinancePendingCategory.currentName]
                )
                moveCandidates = candidates
            }
        }
        guard let pending = candidates.first(where: { $0.name == FinancePendingCategory.currentName })
        else { return }
        for child in snapshot.childCategories {
            childTargets[child.id] = pending
            childDispositions[child.id] = .moveAll(
                toCategoryID: pending.id,
                budgetConflicts: [:]
            )
        }
    }

    @MainActor
    private func loadCandidates() async {
        do {
            let all = try await repository.categoryMoveCandidates(
                excluding: snapshot.sourceFamilyIDs,
                type: sourceType
            )
            // 一级迁移目标：同类型一级分类
            parentCandidates = all.filter { $0.parentID == nil }
            // 整组删除时的二级转移目标
            moveCandidates = CategoryDeletionPolicy.moveTargetCandidates(
                from: all,
                sourceFamilyIDs: snapshot.sourceFamilyIDs,
                sourceTypeRaw: snapshot.sourceTypeRaw,
                pendingCategoryNames: [FinancePendingCategory.currentName]
            )
        } catch {
            Self.logger.error("加载候选失败：\(error.localizedDescription)")
        }
    }

    /// 选定迁移目标后现查目标父下现有子分类名（同名冲突探测）
    @MainActor
    private func loadSiblingNames(for targetParentID: UUID) async {
        let context = try? await repository.categoryDeletionSubmissionContext(
            for: .primary(.moveChildren(toParentID: targetParentID, conflicts: [:]))
        )
        targetSiblingNames = context?.targetSiblingNames ?? []
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
        switch mode {
        case .moveChildren:
            return String(localized: "迁移 \(snapshot.childCategories.count) 个子分类并删除分组")
        case .disposeGroup:
            return String(localized: "删除分组与所选内容")
        }
    }

    private var summaryDetailText: String {
        var parts: [String] = []
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
            ? String(localized: "一级分类是分组容器，请先决定子分类的去向")
            : parts.joined(separator: " · ")
    }

    private func childSummaryText(_ child: CategoryImpactItem) -> String {
        var parts: [String] = []
        if child.liveTransactionCount > 0 {
            parts.append(String(localized: "\(child.liveTransactionCount) 笔"))
        }
        if child.budgetCount > 0 {
            parts.append(String(localized: "\(child.budgetCount) 项预算"))
        }
        if child.spendingProjectCount > 0 {
            parts.append(String(localized: "\(child.spendingProjectCount) 项固定支出"))
        }
        return parts.isEmpty ? String(localized: "空子分类") : parts.joined(separator: " · ")
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
}
