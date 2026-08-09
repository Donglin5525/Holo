//
//  ImportPreviewViewModel.swift
//  Holo
//
//  导入预览 ViewModel — 管理流式扫描、分类匹配预览、字段映射编辑、流式导入
//
//  v3 改造：从"全量持有 items"改为"持有扫描摘要"，支持几万条不爆内存。
//  扫描阶段用 scanCSV 流式遍历产出 ImportScanSummary；导入阶段用 streamImport 再次流式遍历写库。
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

    /// CSV 文件 URL（扫描和导入都从这里流式读取）
    let fileURL: URL
    let onComplete: (BatchImportResult) -> Void
    private let dismiss: () -> Void

    // MARK: - 扫描状态

    /// 当前扫描摘要（流式产物，只含统计和样本）
    @Published var scanSummary: ImportScanSummary?
    /// 当前字段映射（可被用户编辑）
    @Published var fieldMapping: FieldMapping

    // MARK: - 解析警告（来自扫描）

    @Published var parseWarnings: [ParseWarning] = []
    @Published var topFailures: [(index: Int, error: String)] = []

    // MARK: - 匹配状态（基于已有分类的精确复用判断）

    @Published var categoryImportPlan: ImportCategoryPlan = .empty
    @Published var matchStats: (exact: Int, synonym: Int, fuzzy: Int, unmatched: Int) = (0, 0, 0, 0)
    @Published var allCategories: [Category] = []

    // MARK: - 重复导入策略

    @Published var duplicatePolicy: ImportDuplicatePolicy = .skipDuplicates

    // MARK: - UI 状态

    @Published var progress: ImportProgress = .idle
    @Published var showFieldMappingEditor: Bool = false
    @Published var isParsing: Bool = false

    // MARK: - 计算属性

    /// 可导入条数（扫描阶段算出的 parseableCount）
    var parsedItemCount: Int { scanSummary?.parseableCount ?? 0 }

    /// 总行数
    var totalRows: Int { scanSummary?.totalRows ?? 0 }

    /// 失败条数
    var failedCount: Int { scanSummary?.failedCount ?? 0 }

    var blockingWarnings: [ParseWarning] {
        parseWarnings.filter { $0.severity == .blocking }
    }

    var hasUnconfirmedBlockingWarnings: Bool {
        parseWarnings.contains { $0.isBlocking }
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
        fileURL: URL,
        onComplete: @escaping (BatchImportResult) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.onComplete = onComplete
        self.dismiss = dismiss
        // fieldMapping 在扫描完成后填充；先用空的占位
        self.fieldMapping = FieldMapping()
    }

    // MARK: - 扫描（阶段一）

    /// 流式扫描 CSV，产出摘要
    func performScan() {
        isParsing = true
        let url = fileURL
        let overrideMapping: FieldMapping? = scanSummary != nil ? fieldMapping : nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try DataImportService.shared.scanCSV(url: url, fieldMapping: overrideMapping)

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.scanSummary = summary
                    self.fieldMapping = summary.fieldMapping
                    self.parseWarnings = summary.warnings
                    self.topFailures = summary.topFailures
                    self.isParsing = false
                    await self.performCategoryMatching(with: summary)
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isParsing = false
                    self.progress = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 分类匹配（基于已有分类做精确复用判断）

    /// 用扫描摘要收集的 incoming 描述符 + 已有分类，算出真实的"复用 vs 新建"
    private func performCategoryMatching(with summary: ImportScanSummary) async {
        guard let categories = try? await FinanceRepository.shared.getAllCategories() else {
            // 拿不到分类列表，直接用扫描的原始计划（全部算新建）
            self.categoryImportPlan = summary.categoryPlan
            self.matchStats = (0, 0, 0, summary.categoryPlan.primaryCategoriesToCreate.count + summary.categoryPlan.subCategoriesToCreate.count)
            return
        }
        self.allCategories = categories

        let existingDescriptors = existingCategoryDescriptors(from: categories)
        // 直接用扫描期收集的 incoming 描述符，结合已有分类算精确复用
        categoryImportPlan = ImportCategoryPlanner.makePlan(
            incoming: summary.incomingDescriptors,
            existing: existingDescriptors
        )

        let newCount = categoryImportPlan.primaryCategoriesToCreate.count + categoryImportPlan.subCategoriesToCreate.count
        let reusedCount = summary.incomingDescriptors.count - newCount
        matchStats = (max(0, reusedCount), 0, 0, newCount)
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

    /// 用户确认所有日期解析失败的行使用今天日期
    func confirmAllDateFallbacks() {
        for i in parseWarnings.indices where parseWarnings[i].isBlocking {
            parseWarnings[i].isConfirmed = true
        }
    }

    // MARK: - 字段映射编辑

    /// 用户编辑字段映射后，重新流式扫描
    func updateFieldMapping(_ mapping: FieldMapping) {
        fieldMapping = mapping
        // 清空状态，重新扫描
        scanSummary = nil
        parseWarnings = []
        topFailures = []
        categoryImportPlan = .empty
        matchStats = (0, 0, 0, 0)
        performScan()
    }

    // MARK: - 导入（阶段二，流式写库）

    func performImport() {
        guard let summary = scanSummary, !isImporting else { return }

        progress = .importing(current: 0, total: summary.totalRows)

        let url = fileURL
        let mapping = fieldMapping
        let template = summary.detectedTemplate
        let headers = summary.headers
        let policy = duplicatePolicy

        Task {
            let result = await FinanceRepository.shared.streamImportTransactions(
                url: url,
                fieldMapping: mapping,
                detectedTemplate: template,
                headers: headers,
                expectedTotalRows: summary.totalRows,
                duplicatePolicy: policy
            ) { current, total in
                Task { @MainActor in
                    self.progress = .importing(current: current, total: total)
                }
            }

            // 记录批次（供撤回）
            if let batchId = result.batchId, result.successCount > 0 {
                ImportBatchRecordService.record(ImportBatchRecord(
                    id: batchId,
                    fileName: summary.fileName,
                    importedAt: Date(),
                    successCount: result.successCount,
                    failedCount: result.failedItems.count,
                    skippedDuplicateCount: result.skippedDuplicateCount,
                    newCategoriesCount: result.newCategoriesCount,
                    newAccountsCount: result.newAccountsCount
                ))
            }

            progress = .completed(result)
            dismiss()
            onComplete(result)
        }
    }
}
