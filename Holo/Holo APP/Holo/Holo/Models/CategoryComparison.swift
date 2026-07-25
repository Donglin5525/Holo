//
//  CategoryComparison.swift
//  Holo
//
//  科目对比聚合模型：对比两个时间段的支出在各科目上的差异。
//  纯 Swift 实现，不依赖 Core Data，便于单元测试。
//

import Foundation

/// 科目对比的轻量输入（从 Transaction 映射而来）
struct CategoryComparisonInput {
    /// 交易关联的分类 ID，nil 表示未分类
    let categoryID: UUID?
    let amount: Decimal
}

/// 科目基础信息（调用方从 Category 构建字典提供，用于解析名称/层级/展示样式）
struct CategoryComparisonInfo {
    let id: UUID
    let name: String
    let icon: String
    let color: String
    /// nil = 一级科目，非 nil = 二级科目（指向所属一级科目）
    let parentID: UUID?
}

/// 二级科目对比项
struct SubCategoryComparison: Identifiable, Equatable {
    let id: UUID
    let name: String
    let currentAmount: Decimal
    let baselineAmount: Decimal

    /// 差额：本期 - 对比期（正数 = 多支出）
    var diff: Decimal { currentAmount - baselineAmount }
}

/// 一级科目对比项
struct CategoryComparisonItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let icon: String
    let color: String
    let currentAmount: Decimal
    let baselineAmount: Decimal
    /// 二级科目对比，按差额绝对值降序
    let subItems: [SubCategoryComparison]

    /// 差额：本期 - 对比期（正数 = 多支出）
    var diff: Decimal { currentAmount - baselineAmount }

    /// 相对对比期的变化百分比；对比期为 0 时返回 nil（UI 展示"新增"）
    var diffPercentage: Double? {
        guard baselineAmount > 0 else { return nil }
        return NSDecimalNumber(decimal: diff / baselineAmount * 100).doubleValue
    }
}

enum CategoryComparisonBuilder {
    /// 未分类分组使用的固定 ID
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    /// 对比列表排序方式
    enum SortOrder {
        /// 按差额绝对值降序（默认，最能看出两期差异）
        case diffDescending
        /// 按本期金额降序
        case amountDescending
        /// 按本期金额升序
        case amountAscending
    }

    /// 按指定方式重排对比项（一级与其二级子项同步排序）
    static func sorted(
        _ items: [CategoryComparisonItem],
        by order: SortOrder
    ) -> [CategoryComparisonItem] {
        func key(_ current: Decimal, _ diff: Decimal) -> Decimal {
            switch order {
            case .diffDescending: return abs(diff)
            case .amountDescending: return current
            case .amountAscending: return -current
            }
        }

        func sortSubs(_ subs: [SubCategoryComparison]) -> [SubCategoryComparison] {
            subs.sorted { lhs, rhs in
                let lhsKey = key(lhs.currentAmount, lhs.diff)
                let rhsKey = key(rhs.currentAmount, rhs.diff)
                if lhsKey != rhsKey { return lhsKey > rhsKey }
                return lhs.name < rhs.name
            }
        }

        return items
            .map { item in
                CategoryComparisonItem(
                    id: item.id,
                    name: item.name,
                    icon: item.icon,
                    color: item.color,
                    currentAmount: item.currentAmount,
                    baselineAmount: item.baselineAmount,
                    subItems: sortSubs(item.subItems)
                )
            }
            .sorted { lhs, rhs in
                let lhsKey = key(lhs.currentAmount, lhs.diff)
                let rhsKey = key(rhs.currentAmount, rhs.diff)
                if lhsKey != rhsKey { return lhsKey > rhsKey }
                return lhs.name < rhs.name
            }
    }

    /// 聚合两个时间段的交易，按一级科目对齐后输出对比结果，按差额绝对值降序
    /// - Parameters:
    ///   - current: 本期交易输入
    ///   - baseline: 对比期交易输入
    ///   - categories: 全量科目信息字典（id → info），用于解析层级与展示名称
    static func build(
        current: [CategoryComparisonInput],
        baseline: [CategoryComparisonInput],
        categories: [UUID: CategoryComparisonInfo]
    ) -> [CategoryComparisonItem] {
        let currentSums = sumByKey(current, categories: categories)
        let baselineSums = sumByKey(baseline, categories: categories)

        var topIDs = Set(currentSums.keys.map(\.top))
        topIDs.formUnion(baselineSums.keys.map(\.top))

        let items = topIDs.map { topID -> CategoryComparisonItem in
            let currentTotal = sumTop(topID, in: currentSums)
            let baselineTotal = sumTop(topID, in: baselineSums)
            let subItems = buildSubItems(
                topID: topID,
                currentSums: currentSums,
                baselineSums: baselineSums,
                categories: categories
            )
            let info = categories[topID]
            return CategoryComparisonItem(
                id: topID,
                name: info?.name ?? "未分类",
                icon: info?.icon ?? "questionmark",
                color: info?.color ?? "8E8E93",
                currentAmount: currentTotal,
                baselineAmount: baselineTotal,
                subItems: subItems
            )
        }

        return items.sorted { lhs, rhs in
            let lhsDiff = abs(lhs.diff)
            let rhsDiff = abs(rhs.diff)
            if lhsDiff != rhsDiff { return lhsDiff > rhsDiff }
            return lhs.name < rhs.name
        }
    }

    // MARK: - Private

    /// 聚合键：top = 一级科目 ID，sub = 二级科目 ID（直接记在一级科目上的交易为 nil）
    private struct GroupKey: Hashable {
        let top: UUID
        let sub: UUID?
    }

    private static func sumByKey(
        _ inputs: [CategoryComparisonInput],
        categories: [UUID: CategoryComparisonInfo]
    ) -> [GroupKey: Decimal] {
        var result: [GroupKey: Decimal] = [:]
        for input in inputs {
            let key = groupKey(for: input, categories: categories)
            result[key, default: 0] += input.amount
        }
        return result
    }

    private static func groupKey(
        for input: CategoryComparisonInput,
        categories: [UUID: CategoryComparisonInfo]
    ) -> GroupKey {
        guard let categoryID = input.categoryID, let info = categories[categoryID] else {
            return GroupKey(top: uncategorizedID, sub: nil)
        }
        if let parentID = info.parentID {
            return GroupKey(top: parentID, sub: categoryID)
        }
        return GroupKey(top: categoryID, sub: nil)
    }

    private static func sumTop(_ topID: UUID, in sums: [GroupKey: Decimal]) -> Decimal {
        sums.reduce(Decimal(0)) { partial, entry in
            entry.key.top == topID ? partial + entry.value : partial
        }
    }

    private static func buildSubItems(
        topID: UUID,
        currentSums: [GroupKey: Decimal],
        baselineSums: [GroupKey: Decimal],
        categories: [UUID: CategoryComparisonInfo]
    ) -> [SubCategoryComparison] {
        var subIDs = Set<UUID>()
        for key in currentSums.keys where key.top == topID {
            if let sub = key.sub { subIDs.insert(sub) }
        }
        for key in baselineSums.keys where key.top == topID {
            if let sub = key.sub { subIDs.insert(sub) }
        }

        let subItems = subIDs.map { subID -> SubCategoryComparison in
            let key = GroupKey(top: topID, sub: subID)
            return SubCategoryComparison(
                id: subID,
                name: categories[subID]?.name ?? "未分类",
                currentAmount: currentSums[key] ?? 0,
                baselineAmount: baselineSums[key] ?? 0
            )
        }

        return subItems.sorted { lhs, rhs in
            let lhsDiff = abs(lhs.diff)
            let rhsDiff = abs(rhs.diff)
            if lhsDiff != rhsDiff { return lhsDiff > rhsDiff }
            return lhs.name < rhs.name
        }
    }
}
