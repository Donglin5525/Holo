//
//  DataImportService.swift
//  Holo
//
//  数据导入服务 — CSV 解析、智能字段映射、数据校验
//  支持 HOLO 自身格式和 MOZE 等第三方记账 App 的 CSV 导入
//

import Foundation

// MARK: - DataImportService

/// 数据导入服务（单例）
class DataImportService {
    
    static let shared = DataImportService()
    private init() {}
    
    // MARK: - CSV 解析
    
    /**
     解析 CSV 文件，返回预览数据
     
     支持的编码：UTF-8（含 BOM）、GBK
     自动检测分隔符：逗号、制表符
     
     - Parameter url: CSV 文件 URL
     - Returns: 解析后的预览数据（含自动字段映射）
     - Throws: 文件读取或解析错误
     */
    func parseCSV(url: URL) throws -> ImportPreviewData {
        // 读取文件内容（尝试多种编码）
        let content = try readFileContent(url: url)
        
        // 按行分割（处理 \r\n 和 \n 两种换行符）
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        guard lines.count >= 2 else {
            throw ImportError.emptyFile
        }
        
        // 解析表头
        let headers = parseCSVLine(lines[0])
        guard headers.count >= 3 else {
            throw ImportError.invalidFormat("表头列数不足，至少需要日期、类型、金额三列")
        }
        
        // 解析数据行
        var rows: [[String]] = []
        for i in 1..<lines.count {
            let fields = parseCSVLine(lines[i])
            // 列数对齐（不足的补空字符串，多余的截断）
            var aligned = fields
            while aligned.count < headers.count { aligned.append("") }
            if aligned.count > headers.count { aligned = Array(aligned.prefix(headers.count)) }
            rows.append(aligned)
        }
        
        // 检测模板类型并生成字段映射
        let template = detectTemplate(headers: headers)
        let mapping = generateFieldMapping(headers: headers, template: template)
        
        let fileName = url.lastPathComponent
        
        return ImportPreviewData(
            headers: headers,
            rows: rows,
            fieldMapping: mapping,
            detectedTemplate: template,
            fileName: fileName
        )
    }
    
    // MARK: - 数据转换
    
    /**
     将预览数据转换为可导入的交易条目
     
     根据字段映射，逐行解析日期、金额、类型、分类等字段
     跳过无法解析的行，记录错误信息
     
     - Parameters:
       - data: 预览数据
       - mapping: 字段映射关系
     - Returns: (成功解析的条目, 失败条目列表)
     */
    func convertToImportItems(
        data: ImportPreviewData,
        mapping: FieldMapping
    ) -> ([ImportTransactionItem], [(index: Int, error: String)]) {
        var items: [ImportTransactionItem] = []
        var failures: [(index: Int, error: String)] = []
        
        for (index, row) in data.rows.enumerated() {
            do {
                let item = try parseRow(row, mapping: mapping, template: data.detectedTemplate)
                items.append(item)
            } catch {
                failures.append((index: index + 2, error: error.localizedDescription))
            }
        }
        
        return (items, failures)
    }
    
    // MARK: - 模板检测
    
    /**
     根据表头自动检测 CSV 来源模板
     
     检测逻辑：
     - MOZE：包含「记录类型」「主类别」「子类别」
     - HOLO：包含「一级分类」「二级分类」
     - 其他：通用模板
     */
    private func detectTemplate(headers: [String]) -> ImportTemplate {
        let headerSet = Set(headers)
        
        // MOZE 特征：「记录类型」+「主类别」+「子类别」
        if headerSet.contains("记录类型") && headerSet.contains("主类别") && headerSet.contains("子类别") {
            return .moze
        }
        
        // HOLO 自身格式
        if headerSet.contains("一级分类") && headerSet.contains("二级分类") {
            return .holo
        }
        
        return .generic
    }
    
    // MARK: - 字段映射生成
    
    /**
     根据检测到的模板类型，生成字段映射
     
     映射策略：
     1. 优先按模板精确匹配
     2. 回退到模糊匹配（多种同义词）
     */
    private func generateFieldMapping(headers: [String], template: ImportTemplate) -> FieldMapping {
        switch template {
        case .moze:
            return mozeFieldMapping(headers: headers)
        case .holo:
            return holoFieldMapping(headers: headers)
        case .generic:
            return genericFieldMapping(headers: headers)
        }
    }
    
    /// MOZE 格式精确映射
    private func mozeFieldMapping(headers: [String]) -> FieldMapping {
        FieldMapping(
            dateIndex: headers.firstIndex(of: "日期"),
            timeIndex: headers.firstIndex(of: "时间"),
            typeIndex: headers.firstIndex(of: "记录类型"),
            amountIndex: headers.firstIndex(of: "金额"),
            primaryCategoryIndex: headers.firstIndex(of: "主类别"),
            subCategoryIndex: headers.firstIndex(of: "子类别"),
            accountIndex: headers.firstIndex(of: "账户"),
            noteIndex: headers.firstIndex(of: "名称"),
            descriptionIndex: headers.firstIndex(of: "描述"),
            merchantIndex: headers.firstIndex(of: "商家"),
            tagsIndex: headers.firstIndex(of: "标签")
        )
    }
    
    /// HOLO 自身格式映射
    private func holoFieldMapping(headers: [String]) -> FieldMapping {
        FieldMapping(
            dateIndex: headers.firstIndex(of: "日期"),
            timeIndex: headers.firstIndex(of: "时间"),
            typeIndex: headers.firstIndex(of: "类型"),
            amountIndex: headers.firstIndex(of: "金额"),
            primaryCategoryIndex: headers.firstIndex(of: "一级分类"),
            subCategoryIndex: headers.firstIndex(of: "二级分类"),
            accountIndex: headers.firstIndex(of: "账户"),
            noteIndex: headers.firstIndex(of: "备注"),
            descriptionIndex: nil,
            merchantIndex: nil,
            tagsIndex: headers.firstIndex(of: "标签")
        )
    }
    
    /// 通用格式模糊匹配
    private func genericFieldMapping(headers: [String]) -> FieldMapping {
        FieldMapping(
            dateIndex: fuzzyMatch(headers: headers, keywords: ["日期", "date", "时间", "交易日期", "记账日期"]),
            timeIndex: fuzzyMatch(headers: headers, keywords: ["时间", "time"]),
            typeIndex: fuzzyMatch(headers: headers, keywords: ["类型", "type", "收支类型", "交易类型", "记录类型"]),
            amountIndex: fuzzyMatch(headers: headers, keywords: ["金额", "amount", "数额", "交易金额"]),
            primaryCategoryIndex: fuzzyMatch(headers: headers, keywords: ["分类", "category", "类别", "一级分类", "主类别"]),
            subCategoryIndex: fuzzyMatch(headers: headers, keywords: ["子类别", "二级分类", "子分类"]),
            accountIndex: fuzzyMatch(headers: headers, keywords: ["账户", "account", "支付方式", "付款账户"]),
            noteIndex: fuzzyMatch(headers: headers, keywords: ["备注", "note", "说明", "名称", "描述"]),
            descriptionIndex: nil,
            merchantIndex: fuzzyMatch(headers: headers, keywords: ["商家", "merchant", "商户"]),
            tagsIndex: fuzzyMatch(headers: headers, keywords: ["标签", "tag", "tags"])
        )
    }
    
    /// 模糊匹配：在 headers 中查找第一个匹配任意关键词的列索引
    private func fuzzyMatch(headers: [String], keywords: [String]) -> Int? {
        for keyword in keywords {
            if let idx = headers.firstIndex(where: { $0.lowercased().contains(keyword.lowercased()) }) {
                return idx
            }
        }
        return nil
    }
    
    // MARK: - 金额清洗
    
    /**
     清洗金额字符串，移除常见干扰字符
     
     处理规则（按顺序执行）：
     1. 去除首尾空白
     2. 去除货币符号（¥ ￥ $ € £ 元 圆）
     3. 去除千分位逗号（仅当同时存在小数点时，如 "1,234.56"）
     4. 处理欧式小数（仅含一个逗号且无小数点时，"35,50" → "35.50"）
     5. 去除尾部中文单位（元 圆 块）
     
     - Parameter raw: 原始金额字符串
     - Returns: 清洗后的 Double 值（取绝对值），nil 表示无法解析
     */
    private func cleanAmount(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        
        // 去除货币符号
        let currencySymbols: [Character] = ["¥", "￥", "$", "€", "£"]
        while let first = s.first, currencySymbols.contains(first) {
            s.removeFirst()
        }
        
        // 去除尾部中文单位
        let trailingUnits: [Character] = ["元", "圆", "块"]
        while let last = s.last, trailingUnits.contains(last) {
            s.removeLast()
        }
        
        s = s.trimmingCharacters(in: .whitespaces)
        
        // 判断千分位逗号 vs 欧式小数逗号
        let hasDot = s.contains(".")
        let commaCount = s.filter { $0 == "," }.count
        
        if hasDot && commaCount > 0 {
            // 同时有点和逗号 → 逗号是千分位，直接去除
            s = s.replacingOccurrences(of: ",", with: "")
        } else if !hasDot && commaCount == 1 {
            // 只有一个逗号无小数点 → 可能是欧式小数（"35,50"）
            // 检查逗号后是否恰好 1-2 位数字
            let parts = s.split(separator: ",")
            if parts.count == 2 && parts[1].count <= 2 && parts[1].allSatisfy({ $0.isNumber }) {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                // 逗号后超过 2 位，当作千分位去除
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }
        
        guard let value = Double(s) else { return nil }
        return abs(value)
    }
    
    // MARK: - 类型智能识别
    
    /**
     根据类型字符串和金额正负，智能判断交易类型
     
     同义词映射：
     - 收入方向："收入" "收" "进" "入" "+" "income"
     - 支出方向："支出" "支" "出" "付" "-" "expense"
     - 无法判断时回退到金额正负：正数=收入，负数/零=支出
     
     - Parameters:
       - typeStr: CSV 中的类型字段值
       - rawAmount: 原始金额（含正负号）
       - template: 导入模板类型
     - Returns: 解析后的交易类型
     */
    private func normalizeTransactionType(
        _ typeStr: String,
        rawAmount: Double,
        template: ImportTemplate
    ) -> TransactionType {
        let lower = typeStr.lowercased().trimmingCharacters(in: .whitespaces)
        
        // 收入关键词（优先匹配长词避免误判）
        let incomeKeywords = ["收入", "income", "收", "进", "入"]
        // 支出关键词
        let expenseKeywords = ["支出", "expense", "支", "出", "付"]
        
        // MOZE 特殊处理：「记录类型」字段精确匹配
        if template == .moze {
            if lower.contains("收入") || rawAmount > 0 { return .income }
            return .expense
        }
        
        // 通用匹配
        for keyword in incomeKeywords {
            if lower.contains(keyword) { return .income }
        }
        for keyword in expenseKeywords {
            if lower.contains(keyword) { return .expense }
        }
        
        // 符号判断
        if lower == "+" { return .income }
        if lower == "-" { return .expense }
        
        // 回退：根据原始金额正负
        return rawAmount >= 0 ? .income : .expense
    }
    
    // MARK: - 单行解析
    
    /**
     解析单行数据为 ImportTransactionItem
     
     应用三层容错策略：
     1. cleanAmount — 清洗金额中的货币符号、千分位等
     2. normalizeTransactionType — 类型同义词智能匹配
     3. 默认值填充 — 分类/账户/日期缺失时使用合理默认值
     
     唯一仍会抛出错误的情况：金额列缺失或清洗后仍无法解析为数字
     */
    private func parseRow(
        _ row: [String],
        mapping: FieldMapping,
        template: ImportTemplate
    ) throws -> ImportTransactionItem {
        
        // --- 金额解析（唯一必填字段） ---
        guard let amountIdx = mapping.amountIndex else {
            throw ImportError.missingField("金额")
        }
        let rawAmountStr = row[safe: amountIdx] ?? ""
        
        // 先尝试清洗后解析
        guard let cleanedAmount = cleanAmount(rawAmountStr) else {
            throw ImportError.invalidValue("金额无法解析: \(rawAmountStr)")
        }
        guard cleanedAmount > 0 else {
            throw ImportError.invalidValue("金额为零")
        }
        let amount = Decimal(cleanedAmount)
        
        // 保留原始金额的正负号（用于类型推断）
        let originalDouble = Double(rawAmountStr.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) ?? 0
        
        // --- 日期解析（默认值：今天） ---
        var date = Date()
        if let dateIdx = mapping.dateIndex {
            let dateStr = row[safe: dateIdx] ?? ""
            let timeStr = mapping.timeIndex.flatMap { row[safe: $0] } ?? ""
            if let parsed = parseDate(dateStr: dateStr, timeStr: timeStr) {
                date = parsed
            }
            // 解析失败时静默使用今天，不再抛出错误
        }
        
        // --- 类型解析（智能同义词匹配 + 金额正负回退） ---
        let typeStr = mapping.typeIndex.flatMap { row[safe: $0] } ?? ""
        let txType = normalizeTransactionType(typeStr, rawAmount: originalDouble, template: template)
        
        // --- 分类解析（默认值：根据类型填充） ---
        let rawPrimary = mapping.primaryCategoryIndex.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
        let primaryCategory = rawPrimary.isEmpty ? (txType == .income ? "其他收入" : "其他") : rawPrimary
        
        let rawSub = mapping.subCategoryIndex.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
        let subCategory = rawSub.isEmpty ? primaryCategory : rawSub
        
        // --- 账户（默认值："现金"） ---
        let rawAccount = mapping.accountIndex.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
        let accountName = rawAccount.isEmpty ? "现金" : rawAccount
        
        // --- 备注（合并名称 + 商家 + 描述） ---
        var noteParts: [String] = []
        if let noteIdx = mapping.noteIndex, let v = row[safe: noteIdx], !v.trimmingCharacters(in: .whitespaces).isEmpty {
            noteParts.append(v.trimmingCharacters(in: .whitespaces))
        }
        if let merchantIdx = mapping.merchantIndex, let v = row[safe: merchantIdx], !v.trimmingCharacters(in: .whitespaces).isEmpty {
            noteParts.append(v.trimmingCharacters(in: .whitespaces))
        }
        if let descIdx = mapping.descriptionIndex, let v = row[safe: descIdx], !v.trimmingCharacters(in: .whitespaces).isEmpty {
            noteParts.append(v.trimmingCharacters(in: .whitespaces))
        }
        let note = noteParts.isEmpty ? nil : noteParts.joined(separator: " ")
        
        // --- 标签（允许为空） ---
        let tagsStr = mapping.tagsIndex.flatMap { row[safe: $0] } ?? ""
        let tags: [String]? = tagsStr.isEmpty ? nil : tagsStr.components(separatedBy: CharacterSet(charactersIn: ";,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        return ImportTransactionItem(
            date: date,
            type: txType,
            amount: amount,
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            accountName: accountName,
            note: note,
            tags: tags
        )
    }
    
    // MARK: - 日期解析
    
    /**
     支持多种日期格式的智能解析
     
     处理流程：
     1. 预处理中文日期（"2026年3月14日" → "2026/3/14"）
     2. 预处理紧凑格式（"20260314" → "2026/03/14"）
     3. 依次尝试主流日期+时间组合格式
     4. 尝试 ISO 8601
     5. 全部失败返回 nil
     
     - Parameters:
       - dateStr: 日期字符串
       - timeStr: 时间字符串（可为空）
     - Returns: 解析后的 Date，nil 表示所有格式均不匹配
     */
    private func parseDate(dateStr: String, timeStr: String) -> Date? {
        var cleanDate = dateStr.trimmingCharacters(in: .whitespaces)
        let cleanTime = timeStr.trimmingCharacters(in: .whitespaces)
        
        // --- 预处理：中文日期格式 ---
        // "2026年3月14日 12:30" → "2026/3/14 12:30"
        // "2026年03月14日"      → "2026/03/14"
        if cleanDate.contains("年") {
            cleanDate = cleanDate
                .replacingOccurrences(of: "年", with: "/")
                .replacingOccurrences(of: "月", with: "/")
                .replacingOccurrences(of: "日", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        
        // --- 预处理：紧凑纯数字格式 ---
        // "20260314" → "2026/03/14"
        if cleanDate.count == 8 && cleanDate.allSatisfy({ $0.isNumber }) {
            let y = cleanDate.prefix(4)
            let m = cleanDate.dropFirst(4).prefix(2)
            let d = cleanDate.dropFirst(6).prefix(2)
            cleanDate = "\(y)/\(m)/\(d)"
        }
        
        // 组合日期+时间
        let combined = cleanTime.isEmpty ? cleanDate : "\(cleanDate) \(cleanTime)"
        
        // 日期+时间组合格式列表
        let formats = [
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/M/d HH:mm",
            "yyyy/M/d HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy.MM.dd HH:mm",
            "yyyy.MM.dd HH:mm:ss",
            "yyyy/MM/dd",
            "yyyy/M/d",
            "yyyy-MM-dd",
            "yyyy.MM.dd",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "dd/MM/yyyy",
            "MMM dd, yyyy",
            "MMM d, yyyy",
            "dd MMM yyyy",
            "d MMM yyyy",
        ]
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: combined) {
                return date
            }
        }
        
        // 中文 locale 再试一遍（处理中文月份名等场景）
        formatter.locale = Locale(identifier: "zh_CN")
        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: combined) {
                return date
            }
        }
        
        // 尝试 ISO 8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: combined) {
            return date
        }
        
        return nil
    }
    
    // MARK: - 文件读取
    
    /// 尝试多种编码读取文件
    private func readFileContent(url: URL) throws -> String {
        // 先尝试 UTF-8
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            // 去除 BOM
            return content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        }
        
        // 尝试 GBK（中国用户常见）
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbkEncoding = String.Encoding(rawValue: cfEncoding)
        if let content = try? String(contentsOf: url, encoding: gbkEncoding) {
            return content
        }
        
        // 尝试 Latin1（兜底）
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            return content
        }
        
        throw ImportError.encodingError
    }
    
    // MARK: - CSV 行解析
    
    /// 解析单行 CSV（处理引号内的逗号和换行）
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - 导入错误

/// 导入过程中可能发生的错误
enum ImportError: LocalizedError {
    case emptyFile
    case invalidFormat(String)
    case missingField(String)
    case invalidValue(String)
    case encodingError
    case saveFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyFile: return "文件为空或仅包含表头"
        case .invalidFormat(let msg): return "格式错误：\(msg)"
        case .missingField(let field): return "缺少必要字段：\(field)"
        case .invalidValue(let msg): return msg
        case .encodingError: return "无法识别文件编码"
        case .saveFailed(let msg): return "保存失败：\(msg)"
        }
    }
}

// MARK: - Array 安全下标

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
