//
//  DataExportService.swift
//  Holo
//
//  数据导出服务 — 支持 CSV（用户查看）和 JSON（完整备份）两种格式
//  CSV 采用 UTF-8 BOM 编码确保 Excel 中文正常显示
//  「包含小票图片」时打包为 ZIP：数据文件 + receipts/ 目录（图片按交易日期命名）
//

import Foundation
import CoreData
import ZIPFoundation

// MARK: - DataExportService

/// 数据导出服务（单例；测试可注入独立容器 context）
@MainActor
class DataExportService {

    static let shared = DataExportService()
    private let repository: FinanceRepository
    private let context: NSManagedObjectContext
    init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
        self.repository = FinanceRepository(context: context)
    }

    // MARK: - 票根导出计划

    /// 一次「包含小票图片」导出的完整计划：图片命名 + 与交易的对应关系
    struct ReceiptExportPlan {
        /// 交易 id → 小票文件名列表（按 sortOrder 顺序）
        let fileNamesByTransactionID: [UUID: [String]]
        /// 待写入压缩包的图片（zip 内路径 → JPEG 数据）
        let images: [(path: String, data: Data)]
        var isEmpty: Bool { images.isEmpty }
    }

    /// 构建指定范围内交易的小票导出计划（单测直接取计划验「小票」列；主路径走 generateExportFile）
    func makeReceiptPlan(dateRange: ClosedRange<Date>? = nil) async throws -> ReceiptExportPlan {
        buildReceiptPlan(for: try await fetchTransactions(in: dateRange))
    }

    /// 为待导出交易构建小票打包计划：文件名 `receipt_日期_时分_序号.jpg`，重名自动加后缀
    private func buildReceiptPlan(for transactions: [Transaction]) -> ReceiptExportPlan {
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyyMMdd_HHmm"
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")

        var usedNames = Set<String>()
        var fileNamesByTransactionID: [UUID: [String]] = [:]
        var images: [(path: String, data: Data)] = []

        for tx in transactions {
            var names: [String] = []
            for (index, attachment) in tx.receiptAttachments.enumerated() {
                guard let data = attachment.imageData, !data.isEmpty else { continue }
                let base = "receipt_\(nameFormatter.string(from: tx.date))_\(index + 1)"
                var name = "\(base).jpg"
                var suffix = 2
                while usedNames.contains(name) {
                    name = "\(base)_\(suffix).jpg"
                    suffix += 1
                }
                usedNames.insert(name)
                names.append(name)
                images.append(("receipts/\(name)", data))
            }
            if !names.isEmpty {
                fileNamesByTransactionID[tx.id] = names
            }
        }
        return ReceiptExportPlan(fileNamesByTransactionID: fileNamesByTransactionID, images: images)
    }
    
    // MARK: - CSV 导出
    
    /**
     导出交易记录为 CSV 字符串

     CSV 列顺序：日期, 时间, 类型, 金额, 一级分类, 二级分类, 账户, 备注, 标签, 分期[, 小票]
     金额始终为正数，类型字段区分收入/支出；分期列为 "期次/总数"（非分期行留空），
     导入侧据此无损还原分期归组。
     传入 receiptPlan 时追加「小票」列（ZIP 包内图片文件名，多张分号分隔），
     导入侧按表头特征列匹配，未知列自动忽略，不影响再导入。

     - Parameters:
       - dateRange: 日期范围（nil = 全部）
       - receiptPlan: 小票打包计划（nil = 不含小票列，保持既有 10 列格式）
     - Returns: CSV 格式的字符串
     */
    func exportToCSV(dateRange: ClosedRange<Date>? = nil, receiptPlan: ReceiptExportPlan? = nil) async throws -> String {
        let transactions = try await fetchTransactions(in: dateRange)

        var csv = ""
        // 表头
        csv += "日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签,分期"
        if receiptPlan != nil { csv += ",小票" }
        csv += "\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        dateFormatter.locale = Locale(identifier: "zh_CN")
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        for tx in transactions {
            guard let category = tx.category, let account = tx.account else { continue }
            let dateStr = dateFormatter.string(from: tx.date)
            let timeStr = timeFormatter.string(from: tx.date)
            let typeStr = tx.transactionType == .expense ? "支出" : "收入"
            let amount = abs(tx.amount.doubleValue)

            // 查找一级分类名称
            let (primaryName, subName) = categoryNames(for: category)

            let accountName = account.name
            let note = escapeCSVField(tx.note ?? "")
            let tags = tx.tags?.joined(separator: ";") ?? ""
            // 分期列：还原 "期次/总数"（导入侧 parseColumnValue 识别同款写法）
            let installment = tx.installmentGroupId != nil && tx.installmentTotal > 0
                ? "\(tx.installmentIndex)/\(tx.installmentTotal)"
                : ""

            csv += "\(dateStr),\(timeStr),\(typeStr),\(String(format: "%.2f", amount)),\(escapeCSVField(primaryName)),\(escapeCSVField(subName)),\(escapeCSVField(accountName)),\(note),\(escapeCSVField(tags)),\(installment)"
            if let receiptPlan {
                let receiptNames = receiptPlan.fileNamesByTransactionID[tx.id] ?? []
                csv += ",\(escapeCSVField(receiptNames.joined(separator: ";")))"
            }
            csv += "\n"
        }
        
        return csv
    }
    
    // MARK: - JSON 导出
    
    /**
     导出完整备份为 JSON 数据

     包含全部交易、分类、账户信息，可用于完整恢复

     - Parameters:
       - dateRange: 日期范围（nil = 全部）
       - receiptPlan: 小票打包计划（非 nil 时每笔交易 DTO 附 receipts 文件名数组）
     - Returns: JSON 格式的 Data
     */
    func exportToJSON(dateRange: ClosedRange<Date>? = nil, receiptPlan: ReceiptExportPlan? = nil) async throws -> Data {
        let transactions = try await fetchTransactions(in: dateRange)
        let categories = try await repository.getAllCategories()
        let accounts = try await repository.getAllAccounts()

        // 转换为 DTO
        let txDTOs = transactions.compactMap { tx -> TransactionDTO? in
            guard let category = tx.category, let account = tx.account else { return nil }
            return TransactionDTO(
                id: tx.id.uuidString,
                amount: tx.amount.doubleValue,
                type: tx.type,
                categoryName: category.name,
                accountName: account.name,
                accountId: account.id.uuidString,
                categoryId: category.id.uuidString,
                date: tx.date,
                note: tx.note,
                tags: tx.tags,
                createdAt: tx.createdAt,
                updatedAt: tx.updatedAt,
                receipts: receiptPlan?.fileNamesByTransactionID[tx.id]
            )
        }

        let catDTOs = categories.map { cat -> CategoryDTO in
            CategoryDTO(
                id: cat.id.uuidString,
                name: cat.name,
                icon: cat.icon,
                color: cat.color,
                type: cat.type,
                isDefault: cat.isDefault,
                isSystem: cat.isSystem,
                sortOrder: Int(cat.sortOrder),
                parentId: cat.parentId?.uuidString
            )
        }

        let accDTOs = accounts.map { acc -> AccountDTO in
            AccountDTO(
                id: acc.id.uuidString,
                name: acc.name,
                type: acc.type,
                isDefault: acc.isDefault,
                icon: acc.customIcon,
                color: acc.color,
                initialBalance: acc.initialBalance.doubleValue,
                sortOrder: Int(acc.sortOrder),
                isArchived: acc.isArchived,
                notes: acc.notes,
                createdAt: acc.createdAt,
                updatedAt: acc.updatedAt
            )
        }
        
        let backup = HoloBackup(
            version: HoloBackup.currentVersion,
            exportDate: Date(),
            transactions: txDTOs,
            categories: catDTOs,
            accounts: accDTOs
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }
    
    // MARK: - 文件生成
    
    /**
     生成导出文件并保存到临时目录

     - Parameters:
       - format: 导出格式
       - dateRange: 日期范围
       - includeReceipts: 是否包含小票图片（有小票时产物为 ZIP：数据文件 + receipts/ 目录；
         范围内没有任何小票时退回纯数据文件，行为与不勾选一致）
     - Returns: 文件 URL（用于 ShareSheet 分享）
     */
    func generateExportFile(format: ExportFormat, dateRange: ClosedRange<Date>? = nil,
                            includeReceipts: Bool = false) async throws -> URL {
        if includeReceipts {
            let plan = buildReceiptPlan(for: try await fetchTransactions(in: dateRange))
            if !plan.isEmpty {
                return try await generateArchive(format: format, dateRange: dateRange, plan: plan)
            }
        }
        return try await generatePlainFile(format: format, dateRange: dateRange)
    }

    /// 纯数据文件（既有路径）：HOLO_日期.csv / .json
    private func generatePlainFile(format: ExportFormat, dateRange: ClosedRange<Date>?) async throws -> URL {
        let timestamp = Self.exportTimestamp()
        let fileName = "HOLO_\(timestamp).\(format.fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        switch format {
        case .csv:
            let csvString = try await exportToCSV(dateRange: dateRange)
            // 使用 UTF-8 BOM 头确保 Excel 正确识别中文编码
            let bom = "\u{FEFF}"
            let data = (bom + csvString).data(using: .utf8)!
            try data.write(to: fileURL)

        case .json:
            let jsonData = try await exportToJSON(dateRange: dateRange)
            try jsonData.write(to: fileURL)
        }

        return fileURL
    }

    /// 含小票压缩包：HOLO_日期.zip（数据文件在根目录 + receipts/ 图片目录）
    private func generateArchive(format: ExportFormat, dateRange: ClosedRange<Date>?,
                                 plan: ReceiptExportPlan) async throws -> URL {
        let timestamp = Self.exportTimestamp()
        let dataFileName = "HOLO_\(timestamp).\(format.fileExtension)"
        let dataFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(dataFileName)

        switch format {
        case .csv:
            let csvString = try await exportToCSV(dateRange: dateRange, receiptPlan: plan)
            let bom = "\u{FEFF}"
            try (bom + csvString).data(using: .utf8)!.write(to: dataFileURL)
        case .json:
            let jsonData = try await exportToJSON(dateRange: dateRange, receiptPlan: plan)
            try jsonData.write(to: dataFileURL)
        }

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HOLO_\(timestamp).zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: dataFileName, relativeTo: FileManager.default.temporaryDirectory)
        for image in plan.images {
            let data = image.data
            try archive.addEntry(with: image.path, type: .file,
                                 uncompressedSize: Int64(data.count)) { position, chunkSize in
                let start = Int(position)
                let end = min(start + chunkSize, data.count)
                return data.subdata(in: start..<end)
            }
        }
        return zipURL
    }

    /// 导出文件名时间戳（本地短日期，斜杠替换为连字符）
    private static func exportTimestamp() -> String {
        DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
    }
    
    // MARK: - CSV 模板生成
    
    /**
     生成导入模板 CSV 文件
     
     包含表头和 2 条示例数据，方便用户理解格式要求
     
     - Returns: 模板文件 URL
     */
    func generateImportTemplate() -> URL {
        let fileName = "HOLO_导入模板.csv"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var csv = ""
        csv += "日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签,分期\n"
        csv += "2026/03/14,12:30,支出,35.50,餐饮,午餐,微信,公司食堂,工作餐,\n"
        csv += "2026/03/14,09:00,收入,8500.00,工资收入,工资,银行卡,3月工资,,\n"
        
        let bom = "\u{FEFF}"
        try? (bom + csv).data(using: .utf8)?.write(to: fileURL)
        
        return fileURL
    }
    
    // MARK: - 私有方法
    
    /// 按日期范围查询交易，按日期升序排列（导出时自然顺序）
    private func fetchTransactions(in dateRange: ClosedRange<Date>?) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        
        if let range = dateRange, range.lowerBound != Date.distantPast {
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                range.lowerBound as NSDate,
                range.upperBound as NSDate
            )
        }
        
        return try context.fetch(request)
    }
    
    /**
     获取分类的一级+二级名称
     
     - 若该分类是二级子分类（parentId != nil），查找其父级名称
     - 若该分类是一级分类（parentId == nil），二级名称为空
     
     - Returns: (一级分类名, 二级分类名)
     */
    private func categoryNames(for category: Category) -> (String, String) {
        if let parentId = category.parentId {
            // 是二级子分类，查找父级
            let context = CoreDataStack.shared.viewContext
            let request = Category.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", parentId as CVarArg)
            request.fetchLimit = 1
            if let parent = try? context.fetch(request).first {
                return (parent.name, category.name)
            }
            return (category.name, "")
        } else {
            // 是一级分类
            return (category.name, "")
        }
    }
    
    /// CSV 字段转义：包含逗号、引号、换行时用双引号包裹
    private func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
