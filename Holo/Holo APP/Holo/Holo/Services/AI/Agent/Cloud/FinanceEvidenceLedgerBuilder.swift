//
//  FinanceEvidenceLedgerBuilder.swift
//  Holo
//
//  S2 融合版（2026-10-18，方案 docs/finance/plans/2026-10-17-HoloAI深度洞察升级与财务试评/06）：
//  深度分析的「深入」来自程序先算好的判断原料——确定性台账（本期/上期对比、分类
//  贡献、大额事件、分期承诺全景、已确认事实与已知风险）随快照上云，后端注入
//  <finance_evidence_ledger>，模型按 v26 判断法直接采用，不再从明细行里自己挖。
//  口径与行文纪律（方向箭头式/不假设合同条款）与 02 契约 §4/§10 一致。
//

import Foundation
import CoreData

enum FinanceEvidenceLedgerBuilder {

    /// Holo 原生餐饮类目为独立一级（早餐/午餐/晚餐…），导入历史在「餐饮/」下——
    /// 两套并存（F15），跨期比较必须家族归并；未列一级原样保留。
    static let foodFamily: Set<String> = ["餐饮", "早餐", "午餐", "晚餐", "夜宵", "饮品", "超市", "水果", "咖啡", "啤酒"]

    static func familyName(_ primary: String) -> String {
        foodFamily.contains(primary) ? "餐饮" : primary
    }

    /// 台账窗口：本期近 180 天、上期前 180 天（本地直查，不受快照行数限制）。
    static func build(now: Date = Date()) async -> (ledger: String, semantics: [String: String])? {
        let cal = Calendar.current
        let currentEnd = now
        let currentStart = cal.date(byAdding: .day, value: -179, to: cal.startOfDay(for: now)) ?? now
        let baselineEnd = cal.date(byAdding: .day, value: -1, to: currentStart) ?? now
        let baselineStart = cal.date(byAdding: .day, value: -179, to: baselineEnd) ?? now

        guard let current = try? await FinanceRepository.shared.getStatisticsTransactions(from: currentStart, to: currentEnd),
              let baseline = try? await FinanceRepository.shared.getStatisticsTransactions(from: baselineStart, to: baselineEnd) else {
            return nil
        }
        // 台账只服务财务判断；两窗合计为空说明没有可用财务记录
        guard !current.isEmpty || !baseline.isEmpty else { return nil }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        // —— 总览（方向箭头式行文：方向由程序写死，模型不判方向）——
        func stats(_ rows: [Transaction]) -> (expense: Double, income: Double, count: Int) {
            var e = 0.0, i = 0.0, c = 0
            for r in rows {
                if r.transactionType == .expense { e += r.amount.doubleValue; c += 1 }
                else if r.transactionType == .income { i += r.amount.doubleValue }
            }
            return (e, i, c)
        }
        let cs = stats(current), bs = stats(baseline)
        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
        func deltaLine(_ name: String, _ cur: Double, _ base: Double) -> String {
            let d = cur - base
            let dir = d >= 0 ? "增加" : "减少"
            var line = "\(name)从上期的 \(fmt(base)) 元变为本期的 \(fmt(cur)) 元（\(dir) \(fmt(abs(d))) 元"
            if base > 0 {
                line += String(format: "，%+.1f%%", d / base * 100)
            }
            return line + "）"
        }
        var lines: [String] = []
        lines.append("【窗口】本期 \(df.string(from: currentStart)) ~ \(df.string(from: currentEnd))；上期（对比基线）\(df.string(from: baselineStart)) ~ \(df.string(from: baselineEnd))。口径：统计读源（排除对账调整与未来行），金额 CNY。")
        lines.append(deltaLine("总支出", cs.expense, bs.expense) + "；支出笔数从 \(bs.count) 笔变为 \(cs.count) 笔。")
        lines.append(deltaLine("总收入", cs.income, bs.income))

        // —— 分类贡献（家族归并，差额绝对值 top8）——
        func familyStats(_ rows: [Transaction]) -> [String: Double] {
            var m: [String: Double] = [:]
            for r in rows where r.transactionType == .expense {
                let k = familyName(r.category?.name ?? "未分类")
                m[k, default: 0] += r.amount.doubleValue
            }
            return m
        }
        let cf = familyStats(current), bf = familyStats(baseline)
        var deltas: [(String, Double, Double, Double)] = []
        for k in Set(cf.keys).union(bf.keys) {
            deltas.append((k, (cf[k] ?? 0) - (bf[k] ?? 0), bf[k] ?? 0, cf[k] ?? 0))
        }
        deltas.sort { abs($0.1) > abs($1.1) }
        lines.append("【分类贡献】（家族归并口径，上期→本期差额，按绝对额排序；正=增加）")
        for (k, d, b, c) in deltas.prefix(8) where abs(d) >= 100 {
            lines.append("  \(k)：从 \(fmt(b)) 元变为 \(fmt(c)) 元（\(d >= 0 ? "增加" : "减少") \(fmt(abs(d))) 元）")
        }

        // —— 本期单笔大额（一次性事件候选）——
        let big = current
            .filter { $0.transactionType == .expense && $0.amount.doubleValue >= 2000 }
            .sorted { $0.amount.doubleValue > $1.amount.doubleValue }
            .prefix(6)
        if !big.isEmpty {
            lines.append("【本期单笔≥2000元】（一次性事件候选，与日常结构分开看）")
            for t in big {
                let note = (t.note ?? t.remark ?? "").prefix(20)
                lines.append("  \(df.string(from: t.date)) \(fmt(t.amount.doubleValue)) 元 \(t.category?.name ?? "未分类") \(note)")
            }
        }

        // —— 分期承诺全景（本地全量期次行，含未来）——
        var installmentLines: [String] = []
        var futureCount = 0
        var mergedCount = 0
        var midnightCount = 0
        let context = CoreDataStack.shared.newBackgroundContext()
        await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            req.predicate = NSPredicate(format: "installmentTotal > 0 AND deletedAt == nil")
            if let rows = try? context.fetch(req) {
                // 组近似：(总期数, 金额) 聚类；组内金额差 ≤2 元视为同组
                var groups: [[NSManagedObject]] = []
                for r in rows {
                    let rt = (r.value(forKey: "installmentTotal") as? Int) ?? 0
                    let ra = (r.value(forKey: "amount") as? Decimal).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
                    let gi = groups.firstIndex { g in
                        let gt = (g[0].value(forKey: "installmentTotal") as? Int) ?? 0
                        let ga = (g[0].value(forKey: "amount") as? Decimal).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
                        return gt == rt && abs(ga - ra) <= 2
                    }
                    if let gi { groups[gi].append(r) }
                    else { groups.append([r]) }
                }
                if !groups.isEmpty {
                    installmentLines.append("【分期承诺全景】（各期等额聚类，含未来期；未来期=承诺不是已花）")
                    for g in groups.sorted(by: { l, r in
                        (l[0].value(forKey: "date") as? Date ?? .distantPast) < (r[0].value(forKey: "date") as? Date ?? .distantPast)
                    }) {
                        let total = (g[0].value(forKey: "installmentTotal") as? Int) ?? 0
                        let perPeriod = (g[0].value(forKey: "amount") as? Decimal).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
                        let dates = g.compactMap { $0.value(forKey: "date") as? Date }
                        let sumAll = g.reduce(0.0) { acc, r in
                            acc + ((r.value(forKey: "amount") as? Decimal).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0)
                        }
                        let span = dates.isEmpty ? "" : "\(df.string(from: dates.min()!))~\(df.string(from: dates.max()!))"
                        installmentLines.append("  \(total)期×\(fmt(perPeriod))元/期：在库\(g.count)行（\(span)），在库合计 \(fmt(sumAll)) 元（=月供×\(g.count)期；合同本金与利率未提供，不得假设利息成本）")
                        futureCount += g.filter { ($0.value(forKey: "date") as? Date ?? .distantPast) > now }.count
                    }
                }
            }
        }
        lines.append(contentsOf: installmentLines)

        // —— 数据事实（供 financeSemantics 与风险段）——
        for t in current {
            let text = (t.note ?? "") + (t.remark ?? "")
            if text.contains("当日") && text.contains("笔合并") { mergedCount += 1 }
            let comps = cal.dateComponents([.hour, .minute], from: t.date)
            if comps.hour == 0 && comps.minute == 0 { midnightCount += 1 }
        }

        // —— 已确认事实与已知风险（程序检测，模型必须逐条处理）——
        var facts: [String] = []
        if !current.isEmpty {
            let midnightShare = Double(midnightCount) / Double(max(current.count, 1))
            if midnightShare >= 0.05 {
                facts.append(String(format: "本期 %.0f%% 的行付款时刻为 00:00 整（补记/手动记账默认时刻）——时段与夜间类判断不可做，除非另有依据。", midnightShare * 100))
            }
        }
        if mergedCount > 0 {
            facts.append("本期有 \(mergedCount) 行为「当日多笔合并」（一行金额=当日多笔消费）——笔数与笔均类结论须声明此限制。")
        }
        if futureCount > 0 {
            facts.append("库中存在 \(futureCount) 行未来分期承诺（已发生统计均不含未来期）；未来期是承诺不是已花。")
        }
        facts.append("预算数据未进本台账：不得宣称超预算或达成预算，除非本轮工具另行查得。")
        if !facts.isEmpty {
            lines.append("【已确认事实与已知风险】（逐条处理：纳入报告说明影响与动作，或一句话说明为何不影响主判断；不许静默忽略）")
            for (i, f) in facts.enumerated() { lines.append("  \(i + 1). \(f)") }
        }

        let semantics: [String: String] = [
            "timestampReliability": current.isEmpty ? "unknown" : String(format: "midnight00Share=%.2f", Double(midnightCount) / Double(max(current.count, 1))),
            "accountSemantics": "native",
            "mergedRowCount": String(mergedCount),
            "reimbursementCategories": "unknown",
            "futureRowCount": String(futureCount),
        ]
        return (lines.joined(separator: "\n"), semantics)
    }
}
