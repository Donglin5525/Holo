//
//  CategoryDeletionPolicy.swift
//  Holo
//
//  分类删除治理的纯值类型核心：影响快照、用户决策指令、提交可用性规则。
//
//  无 Core Data 依赖：预检/执行的仓库层（FinanceRepository+CategoryDeletion.swift）
//  负责把 NSManagedObject 折叠成这里的值，UI 与测试只消费值；
//  弹层不允许长时间持有可失效的托管对象（开发方案 §4.2）。
//

import Foundation

// MARK: - 层级范围

/// 被删分类的层级：一级是分组容器（不直接挂账目），二级是账目归属
enum CategoryDeletionScope: String, Sendable, Equatable {
    case primary
    case secondary
}

// MARK: - 影响快照（方案 §4.1 单一事实源）

struct CategoryDeletionImpactSnapshot: Sendable, Equatable {
    let sourceCategoryID: UUID
    let sourceRevision: CategoryDeletionRevision
    let scope: CategoryDeletionScope
    /// 源分类的收支类型（交易类型异常判定的基准）
    let sourceTypeRaw: String
    /// 仅一级分类：名下子分类的引用明细
    let childCategories: [CategoryImpactItem]
    /// 仍有效的记账明细（源分类及子分类名下，含 iCloud 重复行归并口径）
    let liveTransactions: [TransactionImpactItem]
    /// 已在回收站、仍引用该分类家族的明细数（恢复契约依赖，单独计数）
    let recycledTransactionCount: Int
    let budgets: [BudgetImpactItem]
    let spendingProjects: [SpendingProjectImpactItem]
    /// 智能分类映射/归纳规则（按名称匹配源分类家族的条目）
    let learnedMappings: [LearnedMappingImpactItem]
    /// 预检即成立的硬阻塞，与用户后续选择无关
    let blockers: [CategoryDeletionBlocker]

    var isSecondary: Bool { scope == .secondary }

    var sourceFamilyIDs: Set<UUID> {
        Set([sourceCategoryID] + childCategories.map(\.id))
    }

    /// 名下是否挂任何用户数据；无引用分类走简单确认路径
    var hasReferences: Bool {
        !liveTransactions.isEmpty || !budgets.isEmpty
            || !spendingProjects.isEmpty || !learnedMappings.isEmpty
            || !childCategories.isEmpty
    }

    /// 是否必须走影响处理页：存在真实引用（账目/预算/固定支出/规则/任一子分类有引用）
    /// 或预检阻塞。只有「空子分类分组」的一级分类走简单确认（方案 §3.4 边界）。
    var requiresImpactFlow: Bool {
        !blockers.isEmpty || !liveTransactions.isEmpty || !budgets.isEmpty
            || !spendingProjects.isEmpty || !learnedMappings.isEmpty
            || childCategories.contains(where: \.hasReferences)
    }

    /// 明细合计（支出取绝对值展示）
    var liveTransactionTotal: Decimal {
        liveTransactions.reduce(Decimal(0)) { $0 + $1.signedAmount }
    }
}

/// 子分类影响条目（一级分类删除时的逐项去向单元）
struct CategoryImpactItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String
    let transactionTypeRaw: String
    let liveTransactionCount: Int
    let budgetCount: Int
    let spendingProjectCount: Int
    let learnedMappingCount: Int

    var hasReferences: Bool {
        liveTransactionCount > 0 || budgetCount > 0
            || spendingProjectCount > 0 || learnedMappingCount > 0
    }
}

/// 账目明细影响条目（展示用值快照，方案 §3.2：日期/名/账户/金额/导入与分期标记）
struct TransactionImpactItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let accountName: String?
    let signedAmount: Decimal
    let installmentText: String?
    let importSourceText: String?
    let typeRaw: String
}

struct BudgetImpactItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let accountID: UUID
    let amount: Decimal
    let periodRaw: String
    let accountName: String?

    /// 预算冲突探测探针（目标已有同账户+同周期预算时需要用户决策）
    var conflictProbe: BudgetConflictProbe {
        BudgetConflictProbe(budgetID: id, accountID: accountID, periodRaw: periodRaw)
    }
}

struct SpendingProjectImpactItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let kindRaw: String
    let amount: Decimal
    let frequencyRaw: String?
    let isPaused: Bool
}

/// 智能分类规则影响条目（精确映射与归纳规则共用）
struct LearnedMappingImpactItem: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Equatable {
        case exactMapping
        case inductionRule
    }

    /// mappingKey / ruleKey
    let id: String
    let kind: Kind
    /// 规则的人话描述（如「瑞幸咖啡 → 餐饮/咖啡」）
    let displayText: String
}

// MARK: - 阻塞项

enum CategoryDeletionBlocker: Sendable, Equatable, Hashable {
    /// 交易收支类型与分类不一致的旧数据异常：禁止静默转移，需先修复（方案 §3.4）
    case typeMismatchedTransactions(count: Int)
    /// 转移目标已有同账户+同周期预算，且用户尚未对冲突给出决策
    case unresolvedBudgetConflicts(count: Int)
    /// 一级迁移的目标父下已有同名子分类，冲突未显式解决
    case unresolvedChildConflicts(count: Int)
    /// 一级整组删除中仍有子分类未配置去向
    case childrenMissingDisposition(count: Int)
}

// MARK: - 版本指纹

/// 提交前重算比对，拦截「处理页开着时数据被 CloudKit 改掉」的过期提交（方案 §4.1）
struct CategoryDeletionRevision: Sendable, Equatable {
    let digest: String

    init(familyFingerprint: String, referenceSummary: String) {
        self.digest = "\(familyFingerprint)#\(referenceSummary)"
    }

    static func == (lhs: CategoryDeletionRevision, rhs: CategoryDeletionRevision) -> Bool {
        lhs.digest == rhs.digest
    }
}

// MARK: - 用户决策指令（方案 §4.2）

/// 预算冲突决策：目标已有同账户+同周期预算时二选一
enum BudgetConflictResolution: Sendable, Equatable {
    /// 金额相加并入目标预算，被转移预算就此移除（合并不可逆，影响页须告知）
    case mergeAmounts
    /// 目标预算不动，被转移预算随分类进入同一回收站批次
    case keepTarget
}

/// 同名子分类冲突决策（一级迁移时目标父下已有同名子分类）
enum ChildConflictResolution: Sendable, Equatable {
    /// 冲突子分类的账目改挂已有同名分类，冲突行进入回收站批次
    case mergeIntoExisting
    /// 保留两个：冲突子分类自动重命名为唯一名（加序号后缀）
    case keepBothRenamed
}

/// 二级分类删除时名下引用的去向
enum SecondaryCategoryDisposition: Sendable, Equatable {
    /// 保留账目与关联配置，转移到目标二级分类；budgetConflicts 覆盖探测到的全部冲突
    case moveAll(toCategoryID: UUID, budgetConflicts: [UUID: BudgetConflictResolution])
    /// 账目、预算、固定支出与分类一并进入同一回收站批次
    case deleteWithReferences
}

/// 一级分类删除时子分类的去向
enum PrimaryCategoryDisposition: Sendable, Equatable {
    /// 保留子分类，整体迁移到目标一级分类；conflicts 覆盖全部同名冲突
    case moveChildren(toParentID: UUID, conflicts: [UUID: ChildConflictResolution])
    /// 删除整个分组：每个子分类各自配置去向（与二级删除同一套决策）
    case disposeChildren([UUID: SecondaryCategoryDisposition])
}

enum CategoryDeletionDisposition: Sendable, Equatable {
    case secondary(SecondaryCategoryDisposition)
    case primary(PrimaryCategoryDisposition)
}

/// 执行请求：ID + 值类型指令 + 预期版本，不携带托管对象（方案 §4.2）
struct CategoryDeletionCommand: Sendable, Equatable {
    let sourceCategoryID: UUID
    let expectedRevision: CategoryDeletionRevision
    let disposition: CategoryDeletionDisposition

    init(sourceCategoryID: UUID,
         expectedRevision: CategoryDeletionRevision,
         disposition: CategoryDeletionDisposition) {
        self.sourceCategoryID = sourceCategoryID
        self.expectedRevision = expectedRevision
        self.disposition = disposition
    }
}

// MARK: - 转移目标候选

/// 转移目标的值快照（选择器与候选过滤都只碰值）
struct CategoryMoveCandidate: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String
    let transactionTypeRaw: String
    let isSystem: Bool
    let parentID: UUID?
    let parentName: String?
}

/// 预算冲突探针：同账户+同周期即冲突
struct BudgetConflictProbe: Sendable, Equatable {
    let budgetID: UUID
    let accountID: UUID
    let periodRaw: String
}

// MARK: - 策略规则

/// 纯函数规则层：删除资格、转移目标过滤、提交可用性
enum CategoryDeletionPolicy {

    /// UI 删除入口的统一判断（方案 D1）：isDefault 只表示预设来源，不限制删除；
    /// 只有系统内部不变量（isSystem，如「待分类」/「余额调整」）不可删
    static func isDeletable(isSystem: Bool) -> Bool {
        !isSystem
    }

    /// 转移目标资格（方案 §4.3）：必须是同收支类型的二级分类，
    /// 不在源家族内；系统分类不放行，「待分类」例外（主动选择的安全暂存位）
    static func moveTargetCandidates(
        from candidates: [CategoryMoveCandidate],
        sourceFamilyIDs: Set<UUID>,
        sourceTypeRaw: String,
        pendingCategoryNames: Set<String>
    ) -> [CategoryMoveCandidate] {
        candidates.filter { candidate in
            candidate.parentID != nil
                && candidate.transactionTypeRaw == sourceTypeRaw
                && !sourceFamilyIDs.contains(candidate.id)
                && (!candidate.isSystem || pendingCategoryNames.contains(candidate.name))
        }
    }

    /// 选定目标后补充的决策上下文（由仓库按目标分类现查）
    struct SubmissionContext: Sendable, Equatable {
        /// 目标分类名下的现有预算探针（探测同周期冲突）
        let targetBudgetProbes: [BudgetConflictProbe]
        /// 一级迁移：目标父下现有子分类名（探测同名冲突）
        let targetSiblingNames: [String]

        init(targetBudgetProbes: [BudgetConflictProbe] = [],
             targetSiblingNames: [String] = []) {
            self.targetBudgetProbes = targetBudgetProbes
            self.targetSiblingNames = targetSiblingNames
        }
    }

    /// 预算冲突探测：同账户+同周期即冲突
    static func budgetConflicts(
        moving probes: [BudgetConflictProbe],
        intoTarget targetProbes: [BudgetConflictProbe]
    ) -> [BudgetConflictProbe] {
        let targetKeys = Set(targetProbes.map { "\($0.accountID.uuidString)|\($0.periodRaw)" })
        return probes.filter { targetKeys.contains("\($0.accountID.uuidString)|\($0.periodRaw)") }
    }

    /// 一级迁移的同名冲突探测：返回目标父下已存在的同名子分类名
    static func childNameConflicts(
        childNames: [String],
        targetSiblingNames: [String]
    ) -> [String] {
        let siblings = Set(targetSiblingNames)
        return childNames.filter { siblings.contains($0) }
    }

    /// 冲突子分类自动重命名（keepBothRenamed 的落点名）：序号后缀递增到不冲突为止
    static func renamedChild(baseName: String, takenNames: Set<String>) -> String {
        if !takenNames.contains(baseName) { return baseName }
        var index = 2
        while takenNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    /// 提交可用性（方案 §6 Phase 1 验收）：返回空数组才允许提交
    static func submissionBlockers(
        snapshot: CategoryDeletionImpactSnapshot,
        command: CategoryDeletionCommand,
        context: SubmissionContext = SubmissionContext()
    ) -> [CategoryDeletionBlocker] {
        var blockers = snapshot.blockers

        // 收支类型异常的旧数据：任何转移类处理都被禁止
        let mismatched = snapshot.liveTransactions
            .filter { $0.typeRaw != snapshot.sourceTypeRaw }
            .count
        if mismatched > 0 {
            blockers.append(.typeMismatchedTransactions(count: mismatched))
        }

        // 层级与指令错配：直接按未配置处理，执行器会拦截
        switch (snapshot.scope, command.disposition) {
        case (.secondary, .secondary), (.primary, .primary):
            break
        default:
            blockers.append(.childrenMissingDisposition(count: 1))
            return blockers
        }

        switch command.disposition {
        case .secondary(.moveAll(let targetID, let conflictResolutions)):
            if targetID == snapshot.sourceCategoryID {
                blockers.append(.unresolvedBudgetConflicts(count: snapshot.budgets.count))
                break
            }
            let conflicts = budgetConflicts(
                moving: snapshot.budgets.map(\.conflictProbe),
                intoTarget: context.targetBudgetProbes
            )
            let unresolved = conflicts.filter { conflictResolutions[$0.budgetID] == nil }
            if !unresolved.isEmpty {
                blockers.append(.unresolvedBudgetConflicts(count: unresolved.count))
            }

        case .secondary(.deleteWithReferences):
            break

        case .primary(.moveChildren(let targetParentID, let conflictResolutions)):
            let conflicts = childNameConflicts(
                childNames: snapshot.childCategories.map(\.name),
                targetSiblingNames: context.targetSiblingNames
            )
            let conflictChildIDs = snapshot.childCategories
                .filter { conflicts.contains($0.name) }
                .map(\.id)
            let unresolved = conflictChildIDs.filter { conflictResolutions[$0] == nil }
            if !unresolved.isEmpty {
                blockers.append(.unresolvedChildConflicts(count: unresolved.count))
            }
            if targetParentID == snapshot.sourceCategoryID {
                blockers.append(.unresolvedChildConflicts(
                    count: max(unresolved.count, 1)
                ))
            }

        case .primary(.disposeChildren(let childDispositions)):
            let knownChildIDs = Set(snapshot.childCategories.map(\.id))
            let missing = knownChildIDs.subtracting(Set(childDispositions.keys))
            if !missing.isEmpty {
                blockers.append(.childrenMissingDisposition(count: missing.count))
            }
        }
        return blockers
    }
}
