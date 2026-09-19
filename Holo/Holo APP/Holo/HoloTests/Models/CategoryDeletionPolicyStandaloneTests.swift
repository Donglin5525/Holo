//
//  CategoryDeletionPolicyStandaloneTests.swift
//  HoloTests
//
//  分类删除策略核心的纯值类型测试（方案 §7.1，无 Core Data 依赖）
//

import XCTest
@testable import Holo

final class CategoryDeletionPolicyStandaloneTests: XCTestCase {

    // MARK: - Helpers

    private func makeCandidate(
        id: UUID = UUID(),
        name: String,
        type: String = "expense",
        isSystem: Bool = false,
        parentID: UUID? = UUID(),
        parentName: String? = "父分类"
    ) -> CategoryMoveCandidate {
        CategoryMoveCandidate(
            id: id,
            name: name,
            icon: "tag",
            colorHex: "#13A4EC",
            transactionTypeRaw: type,
            isSystem: isSystem,
            parentID: parentID,
            parentName: parentName
        )
    }

    private func makeSnapshot(
        scope: CategoryDeletionScope = .secondary,
        typeRaw: String = "expense",
        transactions: [TransactionImpactItem] = [],
        budgets: [BudgetImpactItem] = [],
        children: [CategoryImpactItem] = [],
        blockers: [CategoryDeletionBlocker] = []
    ) -> CategoryDeletionImpactSnapshot {
        CategoryDeletionImpactSnapshot(
            sourceCategoryID: UUID(),
            sourceRevision: CategoryDeletionRevision(familyFingerprint: "fp", referenceSummary: "rs"),
            scope: scope,
            sourceTypeRaw: typeRaw,
            childCategories: children,
            liveTransactions: transactions,
            recycledTransactionCount: 0,
            budgets: budgets,
            spendingProjects: [],
            learnedMappings: [],
            blockers: blockers
        )
    }

    private func makeTransactionItem(typeRaw: String = "expense") -> TransactionImpactItem {
        TransactionImpactItem(
            id: UUID(),
            date: Date(),
            title: "测试",
            accountName: nil,
            signedAmount: Decimal(10),
            installmentText: nil,
            importSourceText: nil,
            typeRaw: typeRaw
        )
    }

    private func makeBudgetItem(
        accountID: UUID = UUID(),
        period: String = "month"
    ) -> BudgetImpactItem {
        BudgetImpactItem(
            id: UUID(),
            accountID: accountID,
            amount: Decimal(100),
            periodRaw: period,
            accountName: nil
        )
    }

    private func makeChild(id: UUID = UUID(), name: String) -> CategoryImpactItem {
        CategoryImpactItem(
            id: id,
            name: name,
            icon: "tag",
            colorHex: "#13A4EC",
            transactionTypeRaw: "expense",
            liveTransactionCount: 3,
            budgetCount: 0,
            spendingProjectCount: 0,
            learnedMappingCount: 0
        )
    }

    // MARK: - 删除资格（D1）

    func testPresetNonSystemCategoryIsDeletable() {
        XCTAssertTrue(CategoryDeletionPolicy.isDeletable(isSystem: false))
    }

    func testSystemCategoryIsNotDeletable() {
        XCTAssertFalse(CategoryDeletionPolicy.isDeletable(isSystem: true))
    }

    // MARK: - 转移目标资格

    func testMoveTargetsOnlyIncludeSameTypeSecondaryCategories() {
        let familyID = UUID()
        let secondary = makeCandidate(name: "咖啡")
        let primary = makeCandidate(name: "餐饮", parentID: nil, parentName: nil)
        let incomeSecondary = makeCandidate(name: "工资", type: "income")
        let systemSecondary = makeCandidate(name: "系统位", isSystem: true)
        let pending = makeCandidate(name: "待分类", isSystem: true)
        let familyMember = makeCandidate(id: familyID, name: "源家族")

        let result = CategoryDeletionPolicy.moveTargetCandidates(
            from: [secondary, primary, incomeSecondary, systemSecondary, pending, familyMember],
            sourceFamilyIDs: [familyID],
            sourceTypeRaw: "expense",
            pendingCategoryNames: ["待分类"]
        )

        XCTAssertEqual(result.map(\.name), ["咖啡", "待分类"])
    }

    func testMoveTargetsExcludeSourceFamilyAndDeletedCategory() {
        let sourceID = UUID()
        let childID = UUID()
        let source = makeCandidate(id: sourceID, name: "源")
        let child = makeCandidate(id: childID, name: "子")
        let normal = makeCandidate(name: "正常候选")

        let result = CategoryDeletionPolicy.moveTargetCandidates(
            from: [source, child, normal],
            sourceFamilyIDs: [sourceID, childID],
            sourceTypeRaw: "expense",
            pendingCategoryNames: []
        )

        XCTAssertEqual(result.map(\.name), ["正常候选"])
    }

    // MARK: - 一级整组删除

    func testDisposeChildrenRequiresDispositionForEveryChild() {
        let childA = UUID()
        let childB = UUID()
        let snapshot = makeSnapshot(
            scope: .primary,
            children: [makeChild(id: childA, name: "A"), makeChild(id: childB, name: "B")]
        )
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .primary(.disposeChildren([
                childA: .deleteWithReferences
                // B 未配置
            ]))
        )

        let blockers = CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: command
        )
        XCTAssertTrue(blockers.contains(.childrenMissingDisposition(count: 1)))
    }

    func testDisposeChildrenSubmittableWhenAllConfigured() {
        let childA = UUID()
        let childB = UUID()
        let snapshot = makeSnapshot(
            scope: .primary,
            children: [makeChild(id: childA, name: "A"), makeChild(id: childB, name: "B")]
        )
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .primary(.disposeChildren([
                childA: .moveAll(toCategoryID: UUID(), budgetConflicts: [:]),
                childB: .deleteWithReferences
            ]))
        )

        XCTAssertEqual(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: command
        ), [])
    }

    // MARK: - 同名子分类冲突

    func testPrimaryMoveRequiresExplicitConflictResolution() {
        let conflictedChild = UUID()
        let snapshot = makeSnapshot(
            scope: .primary,
            children: [makeChild(id: conflictedChild, name: "咖啡")]
        )
        let context = CategoryDeletionPolicy.SubmissionContext(
            targetSiblingNames: ["咖啡"]
        )
        let unresolved = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .primary(.moveChildren(toParentID: UUID(), conflicts: [:]))
        )
        XCTAssertFalse(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: unresolved, context: context
        ).isEmpty)

        let resolved = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .primary(.moveChildren(
                toParentID: UUID(), conflicts: [conflictedChild: .mergeIntoExisting]
            ))
        )
        XCTAssertEqual(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: resolved, context: context
        ), [])
    }

    func testPrimaryMoveWithoutConflictNeedsNoResolution() {
        let snapshot = makeSnapshot(
            scope: .primary,
            children: [makeChild(name: "咖啡")]
        )
        let context = CategoryDeletionPolicy.SubmissionContext(
            targetSiblingNames: ["其他"]
        )
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .primary(.moveChildren(toParentID: UUID(), conflicts: [:]))
        )
        XCTAssertEqual(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: command, context: context
        ), [])
    }

    // MARK: - 预算冲突

    func testBudgetConflictDetectionMatchesAccountAndPeriod() {
        let account = UUID()
        let movedMonth = makeBudgetItem(accountID: account, period: "month")
        let movedWeek = makeBudgetItem(accountID: account, period: "week")
        let movedOtherAccount = makeBudgetItem(accountID: UUID(), period: "month")

        let targetMonth = BudgetConflictProbe(
            budgetID: UUID(), accountID: account, periodRaw: "month"
        )

        let conflicts = CategoryDeletionPolicy.budgetConflicts(
            moving: [movedMonth.conflictProbe, movedWeek.conflictProbe, movedOtherAccount.conflictProbe],
            intoTarget: [targetMonth]
        )
        XCTAssertEqual(conflicts, [movedMonth.conflictProbe])
    }

    func testUnresolvedBudgetConflictBlocksMoveSubmission() {
        let account = UUID()
        let snapshot = makeSnapshot(budgets: [makeBudgetItem(accountID: account, period: "month")])
        let context = CategoryDeletionPolicy.SubmissionContext(
            targetBudgetProbes: [BudgetConflictProbe(
                budgetID: UUID(), accountID: account, periodRaw: "month"
            )]
        )
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .secondary(.moveAll(toCategoryID: UUID(), budgetConflicts: [:]))
        )

        let blockers = CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: command, context: context
        )
        XCTAssertEqual(blockers, [.unresolvedBudgetConflicts(count: 1)])
    }

    func testResolvedBudgetConflictAllowsSubmission() {
        let account = UUID()
        let budget = makeBudgetItem(accountID: account, period: "month")
        let snapshot = makeSnapshot(budgets: [budget])
        let context = CategoryDeletionPolicy.SubmissionContext(
            targetBudgetProbes: [BudgetConflictProbe(
                budgetID: UUID(), accountID: account, periodRaw: "month"
            )]
        )
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .secondary(.moveAll(
                toCategoryID: UUID(),
                budgetConflicts: [budget.id: .mergeAmounts]
            ))
        )

        XCTAssertEqual(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: command, context: context
        ), [])
    }

    // MARK: - 收支类型异常

    func testTypeMismatchedTransactionsBlockAnyMove() {
        let snapshot = makeSnapshot(
            transactions: [makeTransactionItem(typeRaw: "income")]
        )
        let moveCommand = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .secondary(.moveAll(toCategoryID: UUID(), budgetConflicts: [:]))
        )
        XCTAssertEqual(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: moveCommand
        ), [.typeMismatchedTransactions(count: 1)])

        let deleteCommand = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .secondary(.deleteWithReferences)
        )
        XCTAssertEqual(CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot, command: deleteCommand
        ), [.typeMismatchedTransactions(count: 1)])
    }

    // MARK: - 冲突重命名

    func testRenamedChildAppendsIncreasingSuffix() {
        XCTAssertEqual(
            CategoryDeletionPolicy.renamedChild(baseName: "咖啡", takenNames: ["咖啡"]),
            "咖啡 2"
        )
        XCTAssertEqual(
            CategoryDeletionPolicy.renamedChild(
                baseName: "咖啡", takenNames: ["咖啡", "咖啡 2", "咖啡 3"]
            ),
            "咖啡 4"
        )
        XCTAssertEqual(
            CategoryDeletionPolicy.renamedChild(baseName: "咖啡", takenNames: ["其他"]),
            "咖啡"
        )
    }
}
