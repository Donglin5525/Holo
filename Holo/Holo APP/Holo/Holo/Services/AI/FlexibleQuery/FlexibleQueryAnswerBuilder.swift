//
//  FlexibleQueryAnswerBuilder.swift
//  Holo
//
//  灵活查询回答生成
//  第一阶段使用本地模板，后续可扩展 LLM 解释
//

import Foundation

nonisolated final class FlexibleQueryAnswerBuilder {
    /// 根据 Query Result 生成自然语言回答（本地模板）
    func answer(_ result: FlexibleQueryResult) -> String {
        switch result.status {
        case .success:
            return buildSuccessAnswer(result)
        case .empty:
            return buildEmptyAnswer(result)
        case .ambiguous:
            return "查询条件不够明确，你能再具体描述一下吗？"
        case .unsupported:
            return "这个问题暂时无法查询，我可以帮你分析一段时间的消费趋势。"
        case .failed:
            return "查询过程中出了点问题，请稍后再试。"
        }
    }

    // MARK: - Success

    private func buildSuccessAnswer(_ result: FlexibleQueryResult) -> String {
        let plan = result.plan

        switch plan.operation {
        case .findLatestTransaction, .findEarliestTransaction:
            return buildSingleTransactionAnswer(result, plan: plan)
        case .maxTransaction, .minTransaction:
            return buildSingleTransactionAnswer(result, plan: plan)
        case .countTransactions:
            return buildCountAnswer(result)
        case .sumAmount:
            return buildSumAnswer(result)
        case .listTransactions:
            return buildListAnswer(result)
        case .rankByDay:
            return "按天排行功能暂未开放。"
        }
    }

    // MARK: - Single Transaction

    private func buildSingleTransactionAnswer(
        _ result: FlexibleQueryResult,
        plan: FlexibleQueryPlan
    ) -> String {
        guard let evidence = result.matchedTransactions.first else {
            return "没有找到符合条件的记录。"
        }

        var parts: [String] = []

        // 主结果
        let dateStr = formatDate(evidence.date)
        let amountStr = FlexibleQueryFormatting.formatAmount(evidence.amount)
        var desc = "找到"
        if plan.operation == .findLatestTransaction {
            desc = "找到最近一笔"
        } else if plan.operation == .findEarliestTransaction {
            desc = "找到最早一笔"
        } else if plan.operation == .maxTransaction {
            desc = "找到金额最大的一笔"
        } else if plan.operation == .minTransaction {
            desc = "找到金额最小的一笔"
        }

        var detail = "\(desc)符合条件的记录：\(dateStr)，\(amountStr)"
        if let note = evidence.note, !note.isEmpty {
            detail += "，备注\"\(note)\""
        }
        if let cat = evidence.subCategory {
            detail += "，分类\"\(cat)\""
        }
        parts.append(detail)

        // 计算结果
        if let calc = result.calculationResult {
            parts.append(calc.valueText)
        }

        // 匹配依据说明
        if !plan.explanationHints.isEmpty {
            for hint in plan.explanationHints {
                switch hint {
                case .approximateConstraint(_, let reason):
                    parts.append("匹配依据：\(reason)")
                case .noExplicitRecord(let note):
                    parts.append(note)
                case .lowConfidenceMatch(_):
                    parts.append("注意：只有分类命中，备注未完全匹配")
                case .inferredCategory(let synonym, let target):
                    parts.append("\"\(synonym)\"推断为\"\(target)\"分类")
                }
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Count

    private func buildCountAnswer(_ result: FlexibleQueryResult) -> String {
        let count = result.summary.totalMatched
        let amountStr = result.summary.totalAmount.map { FlexibleQueryFormatting.formatAmount($0) }
        let countUnit = result.plan.averageUnit?.countLabel ?? "笔"
        let subject = querySubject(for: result.plan)

        var text = subject.map { "\($0)共 \(count) \(countUnit)" }
            ?? "找到 \(count) \(countUnit)符合条件的记录"
        if let amount = amountStr {
            text += "，总计 \(amount)"
        }
        if let averageText = averageText(for: result) {
            text += "，\(averageText)"
        }
        text += "。"

        if let dateRange = result.summary.dateRange {
            text += "时间范围：\(dateRange)。"
        }

        return text
    }

    // MARK: - Sum

    private func buildSumAnswer(_ result: FlexibleQueryResult) -> String {
        guard let total = result.summary.totalAmount else {
            return "没有找到符合条件的记录。"
        }

        let amountStr = FlexibleQueryFormatting.formatAmount(total)
        let countUnit = result.plan.averageUnit?.countLabel ?? "笔"
        let subject = querySubject(for: result.plan)
        var text = subject.map { "\($0)共 \(result.summary.totalMatched) \(countUnit)，合计 \(amountStr)" }
            ?? "符合条件的交易共 \(result.summary.totalMatched) \(countUnit)，合计 \(amountStr)"

        if let averageText = averageText(for: result) {
            text += "，\(averageText)"
        }
        text += "。"

        if let dateRange = result.summary.dateRange {
            text += "时间范围：\(dateRange)。"
        }

        return text
    }

    private func averageText(for result: FlexibleQueryResult) -> String? {
        guard result.calculationResult?.type == .averageAmount,
              let amount = result.calculationResult?.amount else {
            return nil
        }
        let unit = result.plan.averageUnit?.averageLabel ?? "每笔"
        return "平均\(unit) \(FlexibleQueryFormatting.formatAmount(amount))"
    }

    private func querySubject(for plan: FlexibleQueryPlan) -> String? {
        if let keyword = plan.filters.keywords.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return keyword
        }
        return plan.filters.categoryNames.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    // MARK: - List

    private func buildListAnswer(_ result: FlexibleQueryResult) -> String {
        if result.matchedTransactions.isEmpty {
            return "没有找到符合条件的记录。"
        }

        let count = result.matchedTransactions.count
        let total = result.summary.totalMatched

        var parts: [String] = []

        if total > count {
            parts.append("找到 \(total) 笔符合条件的记录，展示最近 \(count) 笔：")
        } else {
            parts.append("找到 \(count) 笔符合条件的记录：")
        }

        for evidence in result.matchedTransactions {
            let dateStr = formatDate(evidence.date)
            let amountStr = FlexibleQueryFormatting.formatAmount(evidence.amount)
            var line = "\(dateStr) \(amountStr)"
            if let note = evidence.note, !note.isEmpty {
                line += " \(note)"
            }
            parts.append(line)
        }

        if let totalAmount = result.summary.totalAmount {
            parts.append("合计：\(FlexibleQueryFormatting.formatAmount(totalAmount))")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Empty

    private func buildEmptyAnswer(_ result: FlexibleQueryResult) -> String {
        var text = result.emptyReason ?? "没有找到符合条件的记录。"

        if let followUp = result.followUpSuggestion {
            text += "\n\(followUp.question)"
        }

        return text
    }

    // MARK: - Date Format

    private func formatDate(_ dateStr: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"

        guard let date = input.date(from: dateStr) else { return dateStr }

        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.dateFormat = "yyyy年M月d日"

        return output.string(from: date)
    }
}
