//
//  ImportPreviewViewModel.swift
//  Holo
//
//  导入预览 ViewModel — 管理流式扫描、分类匹配预览、字段映射编辑、流式导入
//
//  v3 改造：从"全量持有 items"改为"持有扫描摘要"，支持几万条不爆内存。
//  扫描阶段用 scanCSV 流式遍历产出 ImportScanSummary；导入阶段用 streamImport 再次流式遍历写库。
//
//  v4 账单扩展（docs/plans/2026-08-17-finance-bill-import-ai-plan.md）：
//  扫描后对账单文件追加三段处理——软重复检测（本地自动）、AI 列映射（银行格式，
//  Plus）、AI 科目匹配（批量串行，Plus）。AI 结果以「覆盖表」形式在导入时应用，
//  管线本身不持有全量数据。AI 失败一律降级（手动映射/默认分类），不阻断导入。
//

import SwiftUI
import Combine

/// String 的 Identifiable 包装，用于 .sheet(item:) 绑定
struct MatchKeyWrapper: Identifiable, Equatable {
    let id: String
    init(_ key: String) { self.id = key }
    static func == (lhs: MatchKeyWrapper, rhs: MatchKeyWrapper) { lhs.id == rhs.id }
}

/// 账单导入的 AI 处理阶段
enum BillAIPhase: Equatable {
    case idle
    /// 规则识别不了列（银行格式），等待 AI 列映射（Plus 门槛由 Sheet 层把守）
    case needsColumnMapping
    case columnMapping
    /// 列映射就绪（或模板直出），等待/正在做科目匹配
    case readyForCategorization
    case columnMatching(done: Int, total: Int)
    case done
    /// AI 失败——降级为手动映射/默认分类，导入不受阻
    case degraded(String)
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

    // MARK: - 账单状态（AI 匹配 / 软检测 / 账户映射）

    @Published var aiPhase: BillAIPhase = .idle
    /// AI 科目匹配结果（对方名 → 匹配）
    @Published var categoryMatches: [String: BillImportAIService.CategoryMatch] = [:]
    /// 低置信度（<0.6）的对方名清单，预览页标黄提示
    @Published var lowConfidenceNames: [String] = []
    /// 软检测结果（金额+类型+日期窗口配对）
    @Published var duplicateResult: BillDuplicateDetector.DetectionResult?
    /// 账户映射（微信/支付宝的支付方式 → 用户账户名）
    @Published var accountMapping: [String: String] = [:]
    /// 银行账单：文件级默认账户
    @Published var defaultAccountName: String?
    /// 用户已有账户（账户映射卡片数据源）
    @Published var allAccounts: [Account] = []

    var isBillImport: Bool { scanSummary?.billInfo != nil }

    /// 应用 AI 匹配后的有效导入条数（排除软检测自动跳过）
    var effectiveImportCount: Int {
        let base = parsedItemCount
        if case .skipDuplicates = duplicatePolicy, let dup = duplicateResult {
            return max(0, base - dup.autoSkipRowIndices.count)
        }
        return base
    }

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
        effectiveImportCount > 0
            && !hasUnconfirmedBlockingWarnings
            && !isImporting
            && !isAIRunning
    }

    /// AI 列映射/科目匹配进行中时锁住导入按钮（避免边匹配边导入）
    var isAIRunning: Bool {
        if case .columnMapping = aiPhase { return true }
        if case .columnMatching = aiPhase { return true }
        return false
    }

    var isImporting: Bool {
        if case .importing = progress { return true }
        return false
    }

    var importButtonText: String {
        if case .importing(let current, let total) = progress {
            return "导入中 \(current)/\(total)"
        }
        return "导入 \(effectiveImportCount) 条"
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
                    self.handleBillPostScan(with: summary)
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

    // MARK: - 账单扫描后处理（软检测自动 + AI 状态判定 + 账户映射初值）

    private func handleBillPostScan(with summary: ImportScanSummary) {
        // 软检测是纯本地规则，自动执行（手动记录 vs 账单 / 跨渠道高置信）
        runDuplicateDetection(with: summary)

        guard let billInfo = summary.billInfo else {
            aiPhase = .idle
            return
        }

        // 账户映射初值：加载账户 + 简单名称匹配（精确/包含），未匹配的待用户处理
        Task { await self.prepareAccountMapping(channels: billInfo.paymentChannels, bankName: billInfo.bankName) }

        // 银行等未知格式：规则认不出金额列 → 需要 AI 列映射（Sheet 层把守 Plus）
        let mapping = summary.fieldMapping
        if mapping.amountIndex == nil && mapping.incomeAmountIndex == nil {
            aiPhase = .needsColumnMapping
        } else {
            aiPhase = .readyForCategorization
        }
    }

    private func runDuplicateDetection(with summary: ImportScanSummary) {
        guard let projections = summary.billProjections, !projections.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let minDate = projections.map(\.date).min(),
                  let maxDate = projections.map(\.date).max() else { return }
            let window: TimeInterval = 3 * 86400
            let existing = BillDuplicateDetector.fetchExistingEntries(
                from: minDate.addingTimeInterval(-window),
                to: maxDate.addingTimeInterval(window)
            )
            let incoming = projections.map { (row: $0.row, amount: $0.amount, type: $0.type, date: $0.date) }
            let result = BillDuplicateDetector.detect(incoming: incoming, existing: existing)
            Task { @MainActor [weak self] in
                self?.duplicateResult = result
            }
        }
    }

    private func prepareAccountMapping(channels: [String], bankName: String?) async {
        guard let accounts = try? await FinanceRepository.shared.getAllAccounts() else { return }
        allAccounts = accounts
        let names = accounts.map(\.name)

        var mapping: [String: String] = [:]
        for channel in channels {
            // 微信「支付方式」精确匹配（零钱/零钱通/招商银行储蓄卡(1234)）
            if names.contains(channel) {
                mapping[channel] = channel
                continue
            }
            // 卡片式命名：账户名包含支付方式关键词（如"招行"匹配"招商银行储蓄卡(1234)"）
            if channel.contains("银行") || channel.contains("卡") {
                let bankKeyword = String(channel.prefix(4))  // 如"招商银行"
                if let hit = names.first(where: { $0.contains(bankKeyword) || bankKeyword.contains($0) }) {
                    mapping[channel] = hit
                }
            }
        }
        accountMapping = mapping

        // 银行账单：文件级默认账户（银行名匹配）
        if let bank = bankName {
            defaultAccountName = names.first(where: { $0.contains(bank) }) 
                ?? names.first(where: { bank.contains($0) })
        }
    }

    // MARK: - AI 列映射（银行格式；Sheet 层在 Plus 通过后调用）

    func performAIColumnMapping() async {
        guard let summary = scanSummary else { return }
        aiPhase = .columnMapping
        do {
            let accountNames = (try? await FinanceRepository.shared.getAllAccounts())?.map(\.name) ?? []
            let result = try await BillImportAIService.shared.mapColumns(
                headers: summary.headers,
                sampleRows: Array(summary.sampleRows.prefix(5)),
                accountNames: accountNames
            )
            if result.sourceType == "bank", let name = result.sourceName, !name.isEmpty {
                scanSummary?.billInfo?.bankName = name
                scanSummary?.billInfo?.sourceLabel = name
            }
            // 应用 AI 映射并重扫（摘要与新映射保持一致；重扫后 handleBillPostScan 会重算状态）
            updateFieldMapping(result.mapping)
        } catch {
            aiPhase = .degraded("AI 列映射失败：\(error.localizedDescription)。已切换为手动映射，请检查字段映射。")
        }
    }

    // MARK: - AI 科目匹配（批量串行；Sheet 层在 Plus 通过后调用）

    func performAICategorization() async {
        guard let summary = scanSummary, let billInfo = summary.billInfo else { return }
        let names = billInfo.counterpartyNames
        guard !names.isEmpty else {
            aiPhase = .done
            return
        }

        guard let categories = try? await FinanceRepository.shared.getAllCategories() else {
            aiPhase = .degraded("无法读取分类目录，账单将按默认分类导入")
            return
        }
        // v1：只按支出目录匹配（账单九成以上为支出；收入行应用时会被跳过保持默认分类）
        let expensePaths = expenseCategoryPaths(from: categories)
        guard !expensePaths.isEmpty else {
            aiPhase = .done
            return
        }

        aiPhase = .columnMatching(done: 0, total: names.count)

        // 串行分批（每批 ≤80 个名称；429 退避一次，失败该批放弃——降级为默认分类）
        var matches: [String: BillImportAIService.CategoryMatch] = [:]
        var lowConfidence: [String] = []
        let batchSize = 80
        var processed = 0
        outer: for start in stride(from: 0, to: names.count, by: batchSize) {
            let batch = Array(names[start..<min(start + batchSize, names.count)])
            var attempt = 0
            while true {
                do {
                    let results = try await BillImportAIService.shared.categorize(
                        itemNames: batch,
                        type: .expense,
                        categoryPaths: expensePaths
                    )
                    for match in results {
                        matches[match.name] = match
                        if match.categoryPath == nil && match.suggestedPrimary == nil {
                            continue  // 未匹配，保持默认分类
                        }
                        if match.confidence < 0.6 {
                            lowConfidence.append(match.name)
                        }
                    }
                    break
                } catch {
                    attempt += 1
                    if attempt >= 2 { continue outer }  // 该批放弃，走默认分类
                    try? await Task.sleep(nanoseconds: 5_000_000_000)  // 429 退避 5s
                }
            }
            processed += batch.count
            aiPhase = .columnMatching(done: processed, total: names.count)
        }

        categoryMatches = matches
        lowConfidenceNames = lowConfidence
        aiPhase = .done
    }

    private func expenseCategoryPaths(from categories: [Category]) -> [String] {
        let topLevels = categories.filter { $0.isTopLevel && $0.type == TransactionType.expense.rawValue }
        var paths: [String] = []
        for category in categories where !category.isTopLevel && category.type == TransactionType.expense.rawValue {
            guard let parentId = category.parentId,
                  let parent = topLevels.first(where: { $0.id == parentId }) else { continue }
            paths.append("\(parent.name)/\(category.name)")
        }
        return paths
    }

    /// 组装导入时的科目覆盖表：高置信匹配直接应用；
    /// 低置信的新分类建议不自动应用（用户导入后手动建，避免误建）
    var categoryOverridesForImport: [String: (primary: String, sub: String)] {
        var overrides: [String: (primary: String, sub: String)] = [:]
        for (name, match) in categoryMatches {
            if let path = match.categoryPath,
               let slash = path.firstIndex(of: "/") {
                let primary = String(path[..<slash])
                let sub = String(path[path.index(after: slash)...])
                overrides[name] = (primary, sub)
            }
        }
        return overrides
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
        duplicateResult = nil
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
        let billInfo = summary.billInfo
        let categoryOverrides = categoryOverridesForImport
        let accountOverrides = accountMapping
        let defaultAccount = defaultAccountName
        let skipRows: Set<Int>
        if case .skipDuplicates = policy, let dup = duplicateResult {
            skipRows = dup.autoSkipRowIndices
        } else {
            skipRows = []
        }

        Task {
            let result = await FinanceRepository.shared.streamImportTransactions(
                url: url,
                fieldMapping: mapping,
                detectedTemplate: template,
                headers: headers,
                expectedTotalRows: summary.totalRows,
                duplicatePolicy: policy,
                billInfo: billInfo,
                categoryOverrides: categoryOverrides,
                accountOverrides: accountOverrides,
                defaultAccountName: defaultAccount,
                skipRowIndices: skipRows
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
