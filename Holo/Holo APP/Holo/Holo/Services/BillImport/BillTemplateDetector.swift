//
//  BillTemplateDetector.swift
//  Holo
//
//  账单确定性识别（微信/支付宝固定格式）+ 通用表头自动探测
//  方案：docs/plans/2026-08-17-finance-bill-import-ai-plan.md §3
//
//  设计原则（§2）：识别与探测全部走确定性规则，不依赖 AI；
//  AI 只处理规则识别不了的银行账单列语义（BillFieldMappingAI）。
//

import Foundation

enum BillTemplateDetector {

    /// 探测窗口：账单封面说明最多约 24 行，60 行余量足够
    static let probeWindow = 60

    struct ProbeResult {
        /// 表头行索引（0-based，相对整个文件）
        let headerLineIndex: Int
        /// 表头列名（已切分）
        let headers: [String]
        /// 识别出的模板；未识别时为 .generic（走 AI 列映射）
        let template: ImportTemplate
        /// 表头之前的非空说明行原文（账单头信息，供展示与银行名提取）
        let preambleLines: [String]
        /// 从账单头识别出的银行名（仅银行账单）
        let bankName: String?
    }

    // MARK: - 表头探测

    /// 在文件前若干行中定位表头行并识别模板。
    /// 表头行 = 第一个「列数 ≥3 且含至少两个记账字段关键词」的行；其前的行视为账单头说明。
    static func probe(lines: [String], splitLine: (String) -> [String]) -> ProbeResult? {
        var headerCandidate: (index: Int, headers: [String])? = nil
        var preamble: [String] = []

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let fields = splitLine(line)
            if headerCandidate == nil && fields.count >= 3 && headerScore(fields) >= 2 {
                headerCandidate = (index, fields)
                // 表头之后的行不再进入探测判断
                if index >= lines.count - 1 { break }
                continue
            }
            if headerCandidate == nil {
                preamble.append(line)
            }
        }

        guard let header = headerCandidate else { return nil }

        let contextText = (preamble.joined(separator: "\n") + "\n" + header.headers.joined(separator: ","))
        let template = recognizeTemplate(contextText: contextText, headers: header.headers)

        return ProbeResult(
            headerLineIndex: header.index,
            headers: header.headers,
            template: template,
            preambleLines: Array(preamble.prefix(12)),
            bankName: template == .generic ? extractBankName(from: preamble) : nil
        )
    }

    /// 表头关键词计分：命中两类以上才认定为表头
    private static func headerScore(_ fields: [String]) -> Int {
        // 英文导出表头常见首字母大写（Date/Amount），探测规则需与通用字段映射保持大小写不敏感。
        let normalized = fields.map { normalizeName($0).lowercased() }
        var score = 0
        if normalized.contains(where: { $0.contains("日期") || $0.contains("时间") || $0.contains("date") }) { score += 1 }
        if normalized.contains(where: { $0.contains("金额") || $0.contains("发生额") || $0.contains("amount") }) { score += 1 }
        if normalized.contains(where: { $0.contains("对方") || $0.contains("商品") || $0.contains("摘要") || $0.contains("商户") }) { score += 1 }
        if normalized.contains(where: { $0.contains("状态") }) { score += 1 }
        if normalized.contains(where: { $0.contains("单号") || $0.contains("流水") || $0.contains("凭证") }) { score += 1 }
        return score
    }

    // MARK: - 模板识别

    /// 依据账单头标志字符串 + 表头特征识别微信/支付宝模板；识别不了返回 .generic
    private static func recognizeTemplate(contextText: String, headers: [String]) -> ImportTemplate {
        let normalizedSet = Set(headers.map { normalizeName($0) })

        // 标志字符串：微信/支付宝导出文件的封面必有这些字样
        if contextText.contains("微信支付账单") || contextText.contains("微信支付账单明细") {
            // 交叉验证表头特征，防止误判
            if normalizedSet.contains("交易对方") && normalizedSet.contains(normalizeName("收/支")) {
                return .wechatBill
            }
        }
        if contextText.contains("支付宝") && (contextText.contains("交易流水") || contextText.contains("账单明细")) {
            if normalizedSet.contains("交易对方") && normalizedSet.contains(normalizeName("收/支")) {
                return .alipayBill
            }
        }
        return .generic
    }

    // MARK: - 微信/支付宝固定列映射

    /// 微信账单表头（官方导出固定顺序，这里按列名匹配以容忍版本差异）
    static func wechatFieldMapping(headers: [String]) -> FieldMapping {
        FieldMapping(
            dateIndex: matchColumn(headers, "交易时间"),
            timeIndex: nil,
            typeIndex: matchColumn(headers, "收/支"),
            amountIndex: matchColumn(headers, "金额(元)"),
            primaryCategoryIndex: nil,
            subCategoryIndex: nil,
            accountIndex: matchColumn(headers, "支付方式"),
            noteIndex: matchColumn(headers, "备注"),
            descriptionIndex: nil,
            merchantIndex: matchColumn(headers, "商品"),
            tagsIndex: nil,
            counterpartyIndex: matchColumn(headers, "交易对方"),
            statusIndex: matchColumn(headers, "当前状态"),
            refIndex: matchColumn(headers, "交易单号"),
            incomeAmountIndex: nil,
            expenseAmountIndex: nil
        )
    }

    /// 支付宝账单表头（官方导出固定顺序；无「支付方式」列，整份默认映射到支付宝账户）
    static func alipayFieldMapping(headers: [String]) -> FieldMapping {
        FieldMapping(
            dateIndex: matchColumn(headers, "交易创建时间") ?? matchColumn(headers, "付款时间"),
            timeIndex: nil,
            typeIndex: matchColumn(headers, "收/支"),
            amountIndex: matchColumn(headers, "金额(元)"),
            primaryCategoryIndex: nil,
            subCategoryIndex: nil,
            accountIndex: nil,
            noteIndex: matchColumn(headers, "备注"),
            descriptionIndex: nil,
            merchantIndex: matchColumn(headers, "商品名称"),
            tagsIndex: nil,
            counterpartyIndex: matchColumn(headers, "交易对方"),
            statusIndex: matchColumn(headers, "交易状态"),
            refIndex: matchColumn(headers, "交易号"),
            incomeAmountIndex: nil,
            expenseAmountIndex: nil
        )
    }

    /// 微信「交易类型」列（转账/红包/商户消费等）：用于判断是否资金流转类交易
    static func wechatTransactionTypeIndex(headers: [String]) -> Int? {
        matchColumn(headers, "交易类型")
    }

    // MARK: - 账单行过滤规则（状态 / 不计收支）

    /// 非成功状态关键词：命中即默认跳过该行（退款/关闭/失败等）
    private static let failedStatusKeywords = ["退款", "关闭", "失败", "撤销", "待付款", "处理中"]

    /// 判断一行账单是否应被状态规则跳过
    /// - Returns: 跳过原因（nil = 保留）
    static func skipReason(forRow fields: [String], mapping: FieldMapping) -> String? {
        if let statusIdx = mapping.statusIndex, statusIdx < fields.count {
            let status = fields[statusIdx].trimmingCharacters(in: .whitespaces)
            if !status.isEmpty, failedStatusKeywords.contains(where: { status.contains($0) }) {
                return "状态「\(status)」"
            }
        }
        if let typeIdx = mapping.typeIndex, typeIdx < fields.count {
            let direction = fields[typeIdx].trimmingCharacters(in: .whitespaces)
            if direction.contains("不计收支") {
                return "不计收支"
            }
        }
        return nil
    }

    // MARK: - 银行名提取（银行账单头）

    private static let bankKeywords: [(keyword: String, name: String)] = [
        ("工商银行", "工商银行"), ("中国工商银行", "工商银行"),
        ("农业银行", "农业银行"), ("中国农业银行", "农业银行"),
        ("建设银行", "建设银行"), ("中国建设银行", "建设银行"),
        ("中国银行", "中国银行"),
        ("交通银行", "交通银行"),
        ("招商银行", "招商银行"), ("浦发银行", "浦发银行"), ("中信银行", "中信银行"),
        ("光大银行", "光大银行"), ("民生银行", "民生银行"), ("平安银行", "平安银行"),
        ("兴业银行", "兴业银行"), ("广发银行", "广发银行"), ("华夏银行", "华夏银行"),
        ("邮储银行", "邮储银行"), ("邮政储蓄", "邮储银行"),
        ("北京银行", "北京银行"), ("宁波银行", "宁波银行"), ("上海银行", "上海银行"),
        ("农商银行", "农商银行"), ("渣打银行", "渣打银行"), ("花旗银行", "花旗银行"),
    ]

    /// 从账单头说明行提取银行名
    static func extractBankName(from preambleLines: [String]) -> String? {
        let text = preambleLines.joined(separator: "\n")
        // 长名优先，避免「中国工商银行」被「工商银行」截断误提取
        for entry in bankKeywords.sorted(by: { $0.keyword.count > $1.keyword.count }) {
            if text.contains(entry.keyword) { return entry.name }
        }
        return nil
    }

    // MARK: - 列名归一化与匹配

    /// 列名归一化：全角→半角、去所有空白，容忍「金额（元）」与「金额(元)」等差异
    static func normalizeName(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            if let halfwidth = fullwidthToHalfwidth[scalar] {
                result.append(halfwidth)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static let fullwidthToHalfwidth: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        // U+FF01-U+FF5E 全角区 → U+0021-U+007E 半角区
        if let startFull = Unicode.Scalar(0xFF01), let startHalf = Unicode.Scalar(0x21) {
            for offset in 0...(0xFF5E - 0xFF01) {
                if let full = Unicode.Scalar(0xFF01 + offset), let half = Unicode.Scalar(0x21 + offset) {
                    map[full] = half
                }
            }
        }
        // 全角空格
        if let fullSpace = Unicode.Scalar(0x3000), let halfSpace = Unicode.Scalar(0x20) {
            map[fullSpace] = halfSpace
        }
        return map
    }()

    /// 按归一化列名精确匹配列索引
    static func matchColumn(_ headers: [String], _ target: String) -> Int? {
        let normalizedTarget = normalizeName(target)
        return headers.firstIndex { normalizeName($0) == normalizedTarget }
    }
}
