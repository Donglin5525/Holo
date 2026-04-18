//
//  ImportExportModels.swift
//  Holo
//
//  数据导入导出功能的数据结构定义
//  包含导出格式、导入预览、字段映射、导入结果等
//

import Foundation
import CoreData

// MARK: - 导出格式

/// 支持的导出文件格式
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case json = "JSON"
    
    var id: String { rawValue }
    
    /// 文件扩展名
    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        }
    }
    
    /// 格式说明
    var description: String {
        switch self {
        case .csv: return "通用表格格式，Excel/Numbers 可直接打开"
        case .json: return "完整备份格式，含分类和账户数据"
        }
    }
    
    /// MIME 类型
    var mimeType: String {
        switch self {
        case .csv: return "text/csv"
        case .json: return "application/json"
        }
    }
}

// MARK: - 导出日期范围

/// 导出时的日期范围选项
enum ExportDateRange: String, CaseIterable, Identifiable {
    case all = "全部"
    case thisMonth = "本月"
    case lastThreeMonths = "近三个月"
    case lastSixMonths = "近半年"
    case thisYear = "今年"
    case custom = "自定义"
    
    var id: String { rawValue }
    
    /// 计算实际日期范围（custom 返回 nil，需要外部指定）
    var dateRange: ClosedRange<Date>? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .all:
            return Date.distantPast...now
        case .thisMonth:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return start...now
        case .lastThreeMonths:
            let start = cal.date(byAdding: .month, value: -3, to: now)!
            return start...now
        case .lastSixMonths:
            let start = cal.date(byAdding: .month, value: -6, to: now)!
            return start...now
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            return start...now
        case .custom:
            return nil
        }
    }
}

// MARK: - JSON 备份结构

/// JSON 完整备份的顶层结构
struct HoloBackup: Codable {
    let version: String
    let exportDate: Date
    let transactions: [TransactionDTO]
    let categories: [CategoryDTO]
    let accounts: [AccountDTO]

    static let currentVersion = "1.1"
}

/// 交易记录的数据传输对象（用于 JSON 序列化）
struct TransactionDTO: Codable {
    let id: String
    let amount: Double
    let type: String
    let categoryName: String
    let accountName: String
    let accountId: String?
    let categoryId: String?
    let date: Date
    let note: String?
    let tags: [String]?
    let createdAt: Date
    let updatedAt: Date

    // 兼容旧版 JSON（无 accountId/categoryId 字段时使用默认值）
    init(id: String, amount: Double, type: String, categoryName: String, accountName: String,
         accountId: String? = nil, categoryId: String? = nil,
         date: Date, note: String?, tags: [String]?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.amount = amount
        self.type = type
        self.categoryName = categoryName
        self.accountName = accountName
        self.accountId = accountId
        self.categoryId = categoryId
        self.date = date
        self.note = note
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        amount = try container.decode(Double.self, forKey: .amount)
        type = try container.decode(String.self, forKey: .type)
        categoryName = try container.decode(String.self, forKey: .categoryName)
        accountName = try container.decode(String.self, forKey: .accountName)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        date = try container.decode(Date.self, forKey: .date)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// 分类的数据传输对象
struct CategoryDTO: Codable {
    let id: String
    let name: String
    let icon: String
    let color: String
    let type: String
    let isDefault: Bool
    let isSystem: Bool?
    let sortOrder: Int
    let parentId: String?
}

/// 账户的数据传输对象
struct AccountDTO: Codable {
    let id: String
    let name: String
    let type: String
    let isDefault: Bool
    let icon: String?
    let color: String?
    let initialBalance: Double?
    let sortOrder: Int?
    let isArchived: Bool?
    let notes: String?
    let createdAt: Date?
    let updatedAt: Date?
}

// MARK: - 分类智能匹配

/// 分类匹配类型
enum CategoryMatchType {
    case exact       // 精确匹配（名称完全相同）
    case synonym     // 同义词匹配（如「早饭」→「早餐」）
    case fuzzy       // 模糊匹配（编辑距离相似）
    case unmatched   // 无匹配
}

/// 分类匹配结果
struct CategoryMatchResult {
    /// 原始一级分类名（来自 CSV）
    let originalPrimary: String
    /// 原始二级分类名（来自 CSV）
    let originalSub: String
    /// 匹配类型
    let matchType: CategoryMatchType
    /// 匹配到的分类（可能为 nil）
    var matchedCategory: Category?
    /// 候选分类列表（用于用户手动选择）
    var candidates: [Category]
    /// 匹配置信度（0.0 ~ 1.0）
    var confidence: Double
    /// 用户是否手动修改过
    var isManuallyModified: Bool

    /// 便捷属性：是否有匹配结果
    var hasMatch: Bool { matchedCategory != nil }

    /// 生成唯一标识（用于去重）
    var uniqueKey: String { "\(originalPrimary)|\(originalSub)" }
}

// MARK: - 导入相关

/// CSV 解析后的预览数据
struct ImportPreviewData {
    /// 原始表头
    let headers: [String]
    /// 解析出的所有行（每行为字段值数组）
    let rows: [[String]]
    /// 自动检测的字段映射
    var fieldMapping: FieldMapping
    /// 检测到的导入模板类型
    let detectedTemplate: ImportTemplate
    /// 文件名
    let fileName: String
}

/// 字段映射关系：HOLO 字段 → CSV 列索引
struct FieldMapping {
    /// 日期列索引
    var dateIndex: Int?
    /// 时间列索引（部分格式日期和时间分开）
    var timeIndex: Int?
    /// 交易类型列索引
    var typeIndex: Int?
    /// 金额列索引
    var amountIndex: Int?
    /// 一级分类列索引
    var primaryCategoryIndex: Int?
    /// 二级分类列索引
    var subCategoryIndex: Int?
    /// 账户列索引
    var accountIndex: Int?
    /// 备注/名称列索引
    var noteIndex: Int?
    /// 描述列索引（合并到 note）
    var descriptionIndex: Int?
    /// 商家列索引（合并到 note）
    var merchantIndex: Int?
    /// 标签列索引
    var tagsIndex: Int?
}

/// 导入模板类型（自动检测 CSV 来源）
enum ImportTemplate: String, CaseIterable, Identifiable {
    case holo = "HOLO"
    case moze = "MOZE"
    case generic = "通用 CSV"
    
    var id: String { rawValue }
    
    /// 模板说明
    var description: String {
        switch self {
        case .holo: return "HOLO 导出的 CSV 文件"
        case .moze: return "MOZE 记账 App 导出的 CSV"
        case .generic: return "其他格式，需手动确认映射"
        }
    }
}

/// 待导入的单条交易数据（解析后、写入前的中间结构）
struct ImportTransactionItem {
    let date: Date
    let type: TransactionType
    let amount: Decimal
    let primaryCategory: String
    let subCategory: String
    let accountName: String
    let note: String?
    let tags: [String]?
}

/// 批量导入结果
struct BatchImportResult {
    /// 成功导入条数
    let successCount: Int
    /// 失败条目（行号 + 错误原因）
    let failedItems: [(index: Int, error: String)]
    /// 新建的分类数量
    let newCategoriesCount: Int
    /// 新建的账户数量
    let newAccountsCount: Int
    
    /// 总条数
    var totalCount: Int { successCount + failedItems.count }
    /// 是否全部成功
    var isAllSuccess: Bool { failedItems.isEmpty }
}

/// 导入进度状态
enum ImportProgress: Equatable {
    case idle
    case parsing
    case previewing
    case importing(current: Int, total: Int)
    case completed(BatchImportResult)
    case failed(String)
    
    static func == (lhs: ImportProgress, rhs: ImportProgress) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.parsing, .parsing), (.previewing, .previewing):
            return true
        case let (.importing(lc, lt), .importing(rc, rt)):
            return lc == rc && lt == rt
        case let (.failed(lm), .failed(rm)):
            return lm == rm
        default:
            return false
        }
    }
}
