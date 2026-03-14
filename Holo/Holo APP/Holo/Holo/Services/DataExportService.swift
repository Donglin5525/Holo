//
//  DataExportService.swift
//  Holo
//
//  数据导出服务 — 支持 CSV（用户查看）和 JSON（完整备份）两种格式
//  CSV 采用 UTF-8 BOM 编码确保 Excel 中文正常显示
//

import Foundation
import CoreData

// MARK: - DataExportService

/// 数据导出服务（单例）
@MainActor
class DataExportService {
    
    static let shared = DataExportService()
    private let repository = FinanceRepository.shared
    private init() {}
    
    // MARK: - CSV 导出
    
    /**
     导出交易记录为 CSV 字符串
     
     CSV 列顺序：日期, 时间, 类型, 金额, 一级分类, 二级分类, 账户, 备注, 标签
     金额始终为正数，类型字段区分收入/支出
     
     - Parameter dateRange: 日期范围（nil = 全部）
     - Returns: CSV 格式的字符串
     */
    func exportToCSV(dateRange: ClosedRange<Date>? = nil) async throws -> String {
        let transactions = try await fetchTransactions(in: dateRange)
        
        var csv = ""
        // 表头
        csv += "日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        dateFormatter.locale = Locale(identifier: "zh_CN")
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        for tx in transactions {
            let dateStr = dateFormatter.string(from: tx.date)
            let timeStr = timeFormatter.string(from: tx.date)
            let typeStr = tx.transactionType == .expense ? "支出" : "收入"
            let amount = abs(tx.amount.doubleValue)
            
            // 查找一级分类名称
            let (primaryName, subName) = categoryNames(for: tx.category)
            
            let accountName = tx.account.name
            let note = escapeCSVField(tx.note ?? "")
            let tags = tx.tags?.joined(separator: ";") ?? ""
            
            csv += "\(dateStr),\(timeStr),\(typeStr),\(String(format: "%.2f", amount)),\(escapeCSVField(primaryName)),\(escapeCSVField(subName)),\(escapeCSVField(accountName)),\(note),\(escapeCSVField(tags))\n"
        }
        
        return csv
    }
    
    // MARK: - JSON 导出
    
    /**
     导出完整备份为 JSON 数据
     
     包含全部交易、分类、账户信息，可用于完整恢复
     
     - Parameter dateRange: 日期范围（nil = 全部）
     - Returns: JSON 格式的 Data
     */
    func exportToJSON(dateRange: ClosedRange<Date>? = nil) async throws -> Data {
        let transactions = try await fetchTransactions(in: dateRange)
        let categories = try await repository.getAllCategories()
        let accounts = try await repository.getAllAccounts()
        
        // 转换为 DTO
        let txDTOs = transactions.map { tx -> TransactionDTO in
            TransactionDTO(
                id: tx.id.uuidString,
                amount: tx.amount.doubleValue,
                type: tx.type,
                categoryName: tx.category.name,
                accountName: tx.account.name,
                date: tx.date,
                note: tx.note,
                tags: tx.tags,
                createdAt: tx.createdAt,
                updatedAt: tx.updatedAt
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
                sortOrder: Int(cat.sortOrder),
                parentId: cat.parentId?.uuidString
            )
        }
        
        let accDTOs = accounts.map { acc -> AccountDTO in
            AccountDTO(
                id: acc.id.uuidString,
                name: acc.name,
                type: acc.type,
                isDefault: acc.isDefault
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
     - Returns: 文件 URL（用于 ShareSheet 分享）
     */
    func generateExportFile(format: ExportFormat, dateRange: ClosedRange<Date>? = nil) async throws -> URL {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
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
        csv += "日期,时间,类型,金额,一级分类,二级分类,账户,备注,标签\n"
        csv += "2026/03/14,12:30,支出,35.50,餐饮,午餐,微信,公司食堂,工作餐\n"
        csv += "2026/03/14,09:00,收入,8500.00,工资收入,工资,银行卡,3月工资,\n"
        
        let bom = "\u{FEFF}"
        try? (bom + csv).data(using: .utf8)?.write(to: fileURL)
        
        return fileURL
    }
    
    // MARK: - 私有方法
    
    /// 按日期范围查询交易，按日期升序排列（导出时自然顺序）
    private func fetchTransactions(in dateRange: ClosedRange<Date>?) async throws -> [Transaction] {
        let context = CoreDataStack.shared.viewContext
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
