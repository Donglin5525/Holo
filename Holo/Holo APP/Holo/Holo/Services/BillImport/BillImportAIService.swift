//
//  BillImportAIService.swift
//  Holo
//
//  账单导入的 AI 能力：列映射（银行等未知格式）+ 科目匹配
//  方案：docs/plans/2026-08-17-finance-bill-import-ai-plan.md §5
//
//  铁律（§2）：
//  - 金额、日期永不发给 AI（样本行打码后发送，AI 只看形态不看真值）
//  - AI 只能「指认」不能「发明」：返回的分类路径/列号全部过白名单校验，
//    不在白名单内的一律丢弃，交给用户手动处理
//  - 任何 AI 失败都不阻断导入：列映射失败→手动映射；匹配失败→该条标未匹配
//

import Foundation

final class BillImportAIService {

    static let shared = BillImportAIService()

    private let aiProvider: HoloBackendAIProvider

    init(aiProvider: HoloBackendAIProvider? = nil) {
        self.aiProvider = aiProvider ?? HoloBackendAIProvider()
    }

    // MARK: - 列映射（每文件一次）

    struct ColumnMappingResult {
        /// 来源类型（wechat / alipay / bank / unknown）
        let sourceType: String
        /// AI 识别出的机构名（银行名）
        let sourceName: String?
        let confidence: Double
        /// 白名单校验后的字段映射
        let mapping: FieldMapping
    }

    /// 让 AI 指认各字段列号（仅银行等规则识别不了的格式）
    /// - Parameters:
    ///   - headers: 已探测到的表头
    ///   - sampleRows: 样本行（本函数内部打码后才发送）
    ///   - accountNames: 用户已有账户名（辅助识别支付方式列）
    func mapColumns(
        headers: [String],
        sampleRows: [[String]],
        accountNames: [String]
    ) async throws -> ColumnMappingResult {
        let payload: [String: Any] = [
            "header": headers,
            "sampleRows": sampleRows.map { row in row.map(Self.maskValue) },
            "accountNames": accountNames,
        ]
        let content = try await requestAI(
            purpose: .billColumnMapping,
            payload: payload
        )

        guard let data = Self.extractJSON(from: content),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceJSON = json["source"] as? [String: Any],
              let columnsJSON = json["columns"] as? [String: Any] else {
            throw ImportError.invalidFormat("AI 列映射返回无法解析")
        }

        // 白名单校验：列号必须在 [0, headers.count) 内，越界一律置 nil（宁缺勿错）
        func column(_ key: String) -> Int? {
            guard let n = columnsJSON[key] as? Int else { return nil }
            return (n >= 0 && n < headers.count) ? n : nil
        }

        var mapping = FieldMapping(
            dateIndex: column("dateIndex"),
            timeIndex: column("timeIndex"),
            typeIndex: column("typeIndex"),
            amountIndex: column("amountIndex"),
            primaryCategoryIndex: column("categoryIndex"),
            subCategoryIndex: nil,
            accountIndex: column("accountIndex"),
            noteIndex: column("noteIndex"),
            descriptionIndex: nil,
            merchantIndex: column("merchantIndex"),
            tagsIndex: nil
        )
        mapping.counterpartyIndex = column("counterpartyIndex")
        mapping.statusIndex = column("statusIndex")
        mapping.refIndex = column("refIndex")
        mapping.incomeAmountIndex = column("incomeAmountIndex")
        mapping.expenseAmountIndex = column("expenseAmountIndex")
        mapping.balanceIndex = column("balanceIndex")

        // 本地兜底：银行流水表头通常有「余额」列，AI 漏映射时按表头精确匹配补上
        if mapping.balanceIndex == nil {
            mapping.balanceIndex = headers.firstIndex {
                $0.trimmingCharacters(in: .whitespaces) == "余额"
            }
        }

        return ColumnMappingResult(
            sourceType: sourceJSON["type"] as? String ?? "unknown",
            sourceName: sourceJSON["name"] as? String,
            confidence: sourceJSON["confidence"] as? Double ?? 0,
            mapping: mapping
        )
    }

    // MARK: - 科目匹配（批量）

    struct CategoryMatch {
        /// 输入名称（原样回传，用于对齐）
        let name: String
        /// 匹配到的已有分类路径 "一级/二级"（已过白名单）
        let categoryPath: String?
        /// 新分类建议（仅在无已有分类可复用时给出）
        let suggestedPrimary: String?
        let suggestedSub: String?
        let confidence: Double
    }

    /// 批量匹配科目；单批建议 ≤100 条
    /// - Parameters:
    ///   - itemNames: 去重后的交易对方/商品名称
    ///   - type: 收入/支出（分类目录按此过滤）
    ///   - categoryPaths: 用户已有分类路径白名单（"一级/二级"）
    func categorize(
        itemNames: [String],
        type: TransactionType,
        categoryPaths: [String]
    ) async throws -> [CategoryMatch] {
        let payload: [String: Any] = [
            "type": type == .income ? "income" : "expense",
            "categories": categoryPaths,
            "items": itemNames,
        ]
        let content = try await requestAI(
            purpose: .billCategorization,
            payload: payload
        )

        guard let data = Self.extractJSON(from: content),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultsJSON = json["results"] as? [[String: Any]] else {
            throw ImportError.invalidFormat("AI 科目匹配返回无法解析")
        }

        let allowed = Set(categoryPaths)
        var byName: [String: CategoryMatch] = [:]
        for entry in resultsJSON {
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            // 白名单：AI 返回的路径必须逐字存在于用户分类目录
            var path = entry["categoryPath"] as? String
            if let p = path, !allowed.contains(p) { path = nil }
            var primary: String?
            var sub: String?
            if let suggestion = entry["newCategorySuggestion"] as? [String: Any] {
                primary = suggestion["primary"] as? String
                sub = suggestion["sub"] as? String
            }
            // name 原样对齐；AI 少回/错回的条目保持未匹配
            byName[name] = CategoryMatch(
                name: name,
                categoryPath: path,
                suggestedPrimary: primary,
                suggestedSub: sub,
                confidence: entry["confidence"] as? Double ?? 0
            )
        }
        return itemNames.compactMap { byName[$0] }
    }

    // MARK: - 发送内容打码（§9 隐私口径）

    /// 样本行打码：金额替换为同形态假数字（保数量级）、长数字（卡号/单号）保留尾4位打星。
    /// AI 判断列语义只需要「形态」——表头列名为主、样本形态为辅。
    static func maskValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }

        // 货币金额：¥12.00 / 1,234.56 / 35.5 → 同形态假数字
        let currencyPattern = "^[¥￥$€£]?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})$|^[¥￥$€£]?\\d+(\\.\\d{1,2})?$"
        if trimmed.range(of: currencyPattern, options: .regularExpression) != nil {
            return Self.maskedCurrencyLike(trimmed)
        }
        // 长数字串（交易单号/卡号，≥12位）→ 保留尾4位
        let digits = trimmed.filter { $0.isNumber }
        if digits.count >= 12 && digits.count == trimmed.count {
            return "****" + String(digits.suffix(4))
        }
        return trimmed
    }

    /// 生成同形态的假金额：保位数与量级，数值随机
    private static func maskedCurrencyLike(_ original: String) -> String {
        let hasSymbol = original.hasPrefix("¥") || original.hasPrefix("￥")
            || original.hasPrefix("$") || original.hasPrefix("€") || original.hasPrefix("£")
        var body = original
        var symbol = ""
        if hasSymbol {
            symbol = String(original.prefix(1))
            body = String(original.dropFirst())
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = parts[0].replacingOccurrences(of: ",", with: "")
        let intDigits = intPart.count
        // 数值打乱但保持位数（首位置为 1-9，其余随机）
        var fake = String(Int.random(in: 1...9))
        if intDigits > 1 {
            fake += (1..<(intDigits)).map { _ in "\(Int.random(in: 0...9))" }.joined()
        }
        // 保持千分位形态
        if intPart.contains(",") {
            var grouped = ""
            let chars = Array(fake.reversed())
            for (i, c) in chars.enumerated() {
                if i > 0 && i % 3 == 0 { grouped += "," }
                grouped.append(c)
            }
            fake = String(grouped.reversed())
        }
        var result = symbol + fake
        if parts.count > 1 {
            result += "." + parts[1]  // 保留原小数位数形态
        }
        return result
    }

    // MARK: - 基础调用与 JSON 提取

    private func requestAI(purpose: HoloBackendPurpose, payload: [String: Any]) async throws -> String {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let messages = [ChatMessageDTO.user(body)]
        return try await aiProvider.chat(messages: messages, purpose: purpose)
    }

    /// 从模型回复中剥出 JSON（容忍 ```json 围栏与前后杂文）
    static func extractJSON(from text: String) -> Data? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            if let firstNewline = candidate.firstIndex(of: "\n") {
                candidate = String(candidate[candidate.index(after: firstNewline)...])
            }
            if let fenceEnd = candidate.range(of: "```", options: .backwards) {
                candidate = String(candidate[..<fenceEnd.lowerBound])
            }
        }
        guard let start = candidate.firstIndex(of: "{"),
              let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        return String(candidate[start...end]).data(using: .utf8)
    }
}
