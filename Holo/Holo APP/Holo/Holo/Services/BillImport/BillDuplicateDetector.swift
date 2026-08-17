//
//  BillDuplicateDetector.swift
//  Holo
//
//  账单导入的疑似重复检测（第二层软检测 + 第三层跨渠道高置信拦截）
//  方案：docs/plans/2026-08-17-finance-bill-import-ai-plan.md §8
//
//  第一层（硬指纹 + 交易单号）在 FinanceRepository+Import 的导入流程里，
//  这里负责「账单 vs 已有交易（手动记录 / 其他渠道账单）」的软检测。
//
//  匹配只用最可靠的信号（§8 问题本质）：金额完全相等 + 收支类型相同，
//  时间上人记的维度不可靠——手动记录放宽到 ±2 天；其他账单导入的记录
//  （跨渠道双记，如微信绑卡支付同时出现在微信与银行账单）收紧到 ±1 天。
//  防误伤（同天两杯同价咖啡）：一对一配对消费已有记录，配不齐的整组
//  交给用户确认，绝不自动丢弃真实消费。
//

import Foundation
import CoreData

enum BillDuplicateDetector {

    /// 已有交易的轻量投影（避免整表对象驻留）
    struct ExistingEntry {
        let amount: Decimal
        let type: TransactionType
        let date: Date
        let note: String?
        let importSource: String?
    }

    struct DetectionResult {
        /// 配对成功、默认跳过的数据行号（1-based，与扫描/导入的行过滤口径一致）
        let autoSkipRowIndices: Set<Int>
        /// 配不齐但组内存在疑似对象、需用户确认的数据行号
        let reviewRowIndices: Set<Int>
        /// autoSkip 的明细（行号 → 已有交易摘要），供预览展示
        let autoSkipMatches: [Int: String]
    }

    /// 检测窗口：手动记录日期可能与账单差 1-2 天（补记/跨天/记账日滞后）
    static let manualWindowDays = 2
    /// 跨渠道（其他账单导入的记录）窗口收紧到 1 天
    static let importedWindowDays = 1

    // MARK: - 检测主入口

    /// 对账单数据行做疑似重复检测
    /// - Parameters:
    ///   - incoming: (行号, 金额, 类型, 日期)——行号为过滤后的 1-based 数据行号
    ///   - existing: 已有交易投影（日期范围外的调用方不必传入）
    static func detect(
        incoming: [(row: Int, amount: Decimal, type: TransactionType, date: Date)],
        existing: [ExistingEntry]
    ) -> DetectionResult {
        var autoSkip = Set<Int>()
        var review = Set<Int>()
        var matches: [Int: String] = [:]

        // 按（金额+类型）分组
        struct GroupKey: Hashable {
            let amount: String
            let type: String
        }
        var incomingGroups: [GroupKey: [(row: Int, date: Date)]] = [:]
        for item in incoming {
            let key = GroupKey(amount: item.amount.description, type: item.type.rawValue)
            incomingGroups[key, default: []].append((item.row, item.date))
        }

        // 已配对的 existing 下标集合（一对一消费）
        var consumedExisting = Set<Int>()
        let calendar = Calendar(identifier: .gregorian)

        for (key, incomingRows) in incomingGroups {
            // 该金额+类型下的已有记录
            let candidates = existing.enumerated().filter { _, e in
                e.amount.description == key.amount && e.type.rawValue == key.type
            }

            guard !candidates.isEmpty else { continue }

            var unresolvedRows: [(row: Int, date: Date, window: Int)] = incomingRows.map { row in
                (row.row, row.date, manualWindowDays)
            }

            // 第一轮：一对一配对（优先手动记录的宽窗口；跨渠道用紧窗口但可越过手动配对）
            // 贪心策略：incoming 按日期升序，每个找日期最近且未被消费的已有记录
            for itemDate in unresolvedRows.sorted(by: { $0.date < $1.date }) {
                var bestIndex: Int?
                var bestGap = Int.max
                for (index, entry) in candidates where !consumedExisting.contains(index) {
                    let gap = abs(calendar.dateComponents([.day], from: entry.date, to: itemDate.date).day ?? 99)
                    let window = entry.importSource == nil ? manualWindowDays : importedWindowDays
                    if gap <= window, gap < bestGap {
                        bestGap = gap
                        bestIndex = index
                    }
                }
                if let index = bestIndex {
                    consumedExisting.insert(index)
                    autoSkip.insert(itemDate.row)
                    let entry = candidates[index].element
                    matches[itemDate.row] = describeExisting(entry)
                }
            }

            // 第二轮：没配上但组内存在同额同向已有记录的 → 标黄问人（不自动跳）
            let matchedCount = unresolvedRows.filter { autoSkip.contains($0.row) }.count
            if matchedCount < incomingRows.count, candidates.count > 0 {
                // 组内已有记录全被配走但 incoming 还有剩余，或已有记录窗口不匹配：
                // 只要有同额同向的已有记录存在，剩余行都值得用户扫一眼
                for item in unresolvedRows where !autoSkip.contains(item.row) {
                    review.insert(item.row)
                }
            }
        }

        return DetectionResult(
            autoSkipRowIndices: autoSkip,
            reviewRowIndices: review,
            autoSkipMatches: matches
        )
    }

    private static func describeExisting(_ entry: ExistingEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let dateText = formatter.string(from: entry.date)
        let sourceText: String
        switch entry.importSource {
        case "wechat": sourceText = "微信账单"
        case "alipay": sourceText = "支付宝账单"
        case .some(let s) where s.hasPrefix("bank"): sourceText = "银行账单"
        case .some: sourceText = "账单导入"
        case nil: sourceText = "手动记录"
        }
        let amountText = NumberFormatter.currency.string(from: NSDecimalNumber(decimal: entry.amount)) ?? ""
        return "\(dateText) \(sourceText) \(amountText)"
    }

    // MARK: - 已有交易查询

    /// 查询日期范围内交易的轻量投影（后台 context 只读）
    static func fetchExistingEntries(from start: Date, to end: Date) -> [ExistingEntry] {
        let context = CoreDataStack.shared.newBackgroundContext()
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
        request.propertiesToFetch = ["amount", "type", "date", "note", "importSource"]

        let result = (try? context.performAndWait2 { try context.fetch(request) }) ?? []
        return result.map { tx in
            ExistingEntry(
                amount: tx.amountAsDecimal,
                type: tx.transactionType,
                date: tx.date,
                note: tx.note,
                importSource: tx.importSource
            )
        }
    }
}

// MARK: - 后台 context 的同步读取辅助

private extension NSManagedObjectContext {
    /// performAndWait 的 throwing 包装（只读查询用）
    func performAndWait2<T>(_ work: @escaping () throws -> T) throws -> T {
        var result: T!
        var thrown: Error?
        performAndWait {
            do {
                result = try work()
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        return result
    }
}
