//
//  ImportPreviewViewModel.swift
//  Holo
//
//  导入预览 ViewModel — 管理解析、匹配、编辑确认与导入
//

import SwiftUI
import Combine

/// String 的 Identifiable 包装，用于 .sheet(item:) 绑定
struct MatchKeyWrapper: Identifiable, Equatable {
    let id: String
    init(_ key: String) { self.id = key }
    static func == (lhs: MatchKeyWrapper, rhs: MatchKeyWrapper) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ImportPreviewViewModel: ObservableObject {

    // MARK: - 输入

    let previewData: ImportPreviewData
    let onComplete: (BatchImportResult) -> Void
    private let dismiss: () -> Void

    // MARK: - 解析状态

    @Published var fieldMapping: FieldMapping
    @Published var items: [ImportTransactionItem] = []
    @Published var parseFailures: [(index: Int, error: String)] = []
    @Published var parseWarnings: [ParseWarning] = []
    @Published var confirmedFallbackDateRowIndexes: Set<Int> = []
    /// 日期解析失败被阻断的行索引（0-based，对应 data.rows）
    @Published var blockedRowIndexes: Set<Int> = []

    // MARK: - 匹配状态

    @Published var categoryMatchResults: [CategoryMatchResult] = []
    @Published var uniqueMatchResults: [CategoryMatchResult] = []
    @Published var categoryImportPlan: ImportCategoryPlan = .empty
    @Published var matchStats: (exact: Int, synonym: Int, fuzzy: Int, unmatched: Int) = (0, 0, 0, 0)

    // MARK: - UI 状态

    @Published var progress: ImportProgress = .idle
    @Published var editingMatchKey: MatchKeyWrapper? = nil
    @Published var showFieldMappingEditor: Bool = false
    @Published var isParsing: Bool = false

    /// 所有分类（用于 CategoryMatchEditor）
    @Published var allCategories: [Category] = []

    // MARK: - 计算属性

    var parsedItemCount: Int { items.count }

    /// 将新建的排前面，已存在的排后面
    var sortedUniqueMatchResults: [CategoryMatchResult] {
        uniqueMatchResults.sorted { lhs, rhs in
            lhs.willCreateOriginalCategory && !rhs.willCreateOriginalCategory
        }
    }

    var blockingWarnings: [ParseWarning] {
        parseWarnings.filter { $0.severity == .blocking }
    }

    var hasUnconfirmedBlockingWarnings: Bool {
        parseWarnings.contains { $0.isBlocking }
    }

    var hasUnconfirmedMappings: Bool {
        uniqueMatchResults.contains { $0.needsConfirmation }
    }

    var canImport: Bool {
        parsedItemCount > 0
            && !hasUnconfirmedBlockingWarnings
            && !isImporting
    }

    var isImporting: Bool {
        if case .importing = progress { return true }
        return false
    }

    var importButtonText: String {
        if case .importing(let current, let total) = progress {
            return "导入中 \(current)/\(total)"
        }
        return "导入 \(parsedItemCount) 条"
    }

    // MARK: - 初始化

    init(
        previewData: ImportPreviewData,
        onComplete: @escaping (BatchImportResult) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.previewData = previewData
        self.onComplete = onComplete
        self.dismiss = dismiss
        self.fieldMapping = previewData.fieldMapping
    }

    // MARK: - 解析

    func performPreParse() {
        isParsing = true
        let data = previewData
        let mapping = fieldMapping
        let confirmed = confirmedFallbackDateRowIndexes

        DispatchQueue.global(qos: .userInitiated).async {
            let (items, failures, warnings) = DataImportService.shared.convertToImportItems(
                data: data,
                mapping: mapping,
                confirmedFallbackDateRows: confirmed
            )
            let blockedIndexes = Set(
                warnings.filter { $0.isBlocking }.map { $0.rowIndex - 2 }
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.items = items
                self.parseFailures = failures
                self.parseWarnings = warnings
                self.blockedRowIndexes = blockedIndexes
                self.isParsing = false
                await self.performCategoryMatching()
            }
        }
    }

    /// 用户确认对某行使用今天作为兜底日期
    func confirmFallbackDate(rowIndex: Int) {
        let dataIndex = rowIndex - 2
        confirmedFallbackDateRowIndexes.insert(dataIndex)
        performPreParse()
    }

    /// 更新字段映射（全量重新解析）
    func updateFieldMapping(_ mapping: FieldMapping) {
        fieldMapping = mapping
        // 全量清空，重新解析
        items = []
        parseFailures = []
        parseWarnings = []
        blockedRowIndexes = []
        categoryMatchResults = []
        uniqueMatchResults = []
        categoryImportPlan = .empty
        matchStats = (0, 0, 0, 0)
        performPreParse()
    }

    // MARK: - 分类匹配

    @MainActor
    private func performCategoryMatching() async {
        guard let categories = try? await FinanceRepository.shared.getAllCategories() else {
            return
        }
        self.allCategories = categories

        categoryMatchResults = CategoryMatcherService.shared.batchMatchCategories(
            items: items,
            categories: categories
        )
        categoryImportPlan = ImportCategoryPlanner.makePlan(
            incoming: importCategoryDescriptors(from: items),
            existing: existingCategoryDescriptors(from: categories)
        )
        matchStats = CategoryMatcherService.shared.generateMatchStatistics(results: categoryMatchResults)
        uniqueMatchResults = CategoryMatcherService.shared.deduplicateResults(categoryMatchResults)
    }

    private func importCategoryDescriptors(from items: [ImportTransactionItem]) -> [ImportCategoryDescriptor] {
        items.map {
            ImportCategoryDescriptor(
                typeRaw: $0.type.rawValue,
                primaryName: $0.primaryCategory,
                subName: $0.subCategory
            )
        }
    }

    private func existingCategoryDescriptors(from categories: [Category]) -> [ImportCategoryDescriptor] {
        categories.compactMap { category in
            if category.isTopLevel {
                return ImportCategoryDescriptor(
                    typeRaw: category.type,
                    primaryName: category.name,
                    subName: nil
                )
            }

            guard let parentId = category.parentId,
                  let parent = categories.first(where: { $0.id == parentId }) else {
                return nil
            }

            return ImportCategoryDescriptor(
                typeRaw: category.type,
                primaryName: parent.name,
                subName: category.name
            )
        }
    }

    /// 更新某个分类匹配结果（用户手动选择了已有分类）
    func updateMatch(uniqueKey: String, newCategory: Category) {
        // 更新 uniqueMatchResults
        if let idx = uniqueMatchResults.firstIndex(where: { $0.uniqueKey == uniqueKey }) {
            uniqueMatchResults[idx].matchedCategory = newCategory
            uniqueMatchResults[idx].matchType = .exact
            uniqueMatchResults[idx].confidence = 1.0
            uniqueMatchResults[idx].isManuallyModified = true
            uniqueMatchResults[idx].confirmedCreateNew = false
        }

        // 更新所有 categoryMatchResults 中匹配的条目
        for i in categoryMatchResults.indices where categoryMatchResults[i].uniqueKey == uniqueKey {
            categoryMatchResults[i].matchedCategory = newCategory
            categoryMatchResults[i].matchType = .exact
            categoryMatchResults[i].confidence = 1.0
            categoryMatchResults[i].isManuallyModified = true
            categoryMatchResults[i].confirmedCreateNew = false
        }

        // 记录学习映射
        let result = uniqueMatchResults.first { $0.uniqueKey == uniqueKey }
        if let result {
            let parentName: String
            if let parentId = newCategory.parentId,
               let parent = allCategories.first(where: { $0.id == parentId }) {
                parentName = parent.name
            } else {
                parentName = newCategory.name
            }

            CategoryLearnedMapping.record(
                candidate: result.originalSub,
                type: result.type,
                primaryCategory: result.originalPrimary,
                targetPrimary: parentName,
                targetSub: newCategory.name
            )
        }

        // 刷新统计
        matchStats = CategoryMatcherService.shared.generateMatchStatistics(results: categoryMatchResults)
        objectWillChange.send()
    }

    /// 确认创建新分类（unmatched 时使用）
    func confirmCreateNew(uniqueKey: String) {
        if let idx = uniqueMatchResults.firstIndex(where: { $0.uniqueKey == uniqueKey }) {
            uniqueMatchResults[idx].confirmedCreateNew = true
        }
        for i in categoryMatchResults.indices where categoryMatchResults[i].uniqueKey == uniqueKey {
            categoryMatchResults[i].confirmedCreateNew = true
        }
        matchStats = CategoryMatcherService.shared.generateMatchStatistics(results: categoryMatchResults)
        objectWillChange.send()
    }

    /// 批量确认所有模糊匹配
    func confirmAllFuzzyMatches() {
        for i in uniqueMatchResults.indices where uniqueMatchResults[i].matchType == .fuzzy && uniqueMatchResults[i].needsConfirmation {
            uniqueMatchResults[i].isConfirmed = true
        }
        for i in categoryMatchResults.indices where categoryMatchResults[i].matchType == .fuzzy && categoryMatchResults[i].needsConfirmation {
            categoryMatchResults[i].isConfirmed = true
        }
        matchStats = CategoryMatcherService.shared.generateMatchStatistics(results: categoryMatchResults)
        objectWillChange.send()
    }

    // MARK: - 导入

    func performImport() {
        guard !items.isEmpty else { return }

        progress = .importing(current: 0, total: items.count)

        Task {
            let result = await FinanceRepository.shared.batchImportTransactionsWithMatchResults(
                items,
                matchResults: categoryMatchResults
            ) { current, total in
                Task { @MainActor in
                    self.progress = .importing(current: current, total: total)
                }
            }

            progress = .completed(result)
            dismiss()
            onComplete(result)
        }
    }

    // MARK: - 获取匹配结果

    func matchResult(forKey key: String) -> CategoryMatchResult? {
        uniqueMatchResults.first { $0.uniqueKey == key }
    }

    /// 获取同类型的所有分类（用于 CategoryMatchEditor）
    func categoriesForMatch(_ matchResult: CategoryMatchResult) -> [Category] {
        allCategories.filter { $0.type == matchResult.type.rawValue }
    }
}
