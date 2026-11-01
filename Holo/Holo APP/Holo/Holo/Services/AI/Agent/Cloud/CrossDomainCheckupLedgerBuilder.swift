//
//  CrossDomainCheckupLedgerBuilder.swift
//  Holo
//
//  全景体检台账（2026-11-01 东林拍板：跨域洞察改全景版）：
//  深度分析的「全域都用起来」不靠模型自觉——程序先把各领域本期/上期体检指标
//  与按天对齐的同变候选算好，随快照上云注入 <cross_domain_checkup>，模型负责
//  读片、判断与表达（与 FinanceEvidenceLedgerBuilder 同一范式，v26 判断法推广）。
//  窗口：本期近 windowDays 天、上期再往前 windowDays 天；口径与快照数据源同一条
//  路（HoloDefaultCrossDomainDataSource），语义零漂移。
//

import Foundation

enum CrossDomainCheckupLedgerBuilder {

    static func build(now: Date = Date(), windowDays: Int = 30) async -> String? {
        let cal = Calendar.current
        // 与 finance_evidence_ledger 同一窗口（EvidenceLedgerWindows 单一真相源）：上期取数上界=本期起点
        let window = EvidenceLedgerWindows.make(now: now, windowDays: windowDays, calendar: cal)
        let currentStart = window.currentStart
        let currentEnd = window.currentEnd
        let baselineStart = window.baselineStart
        let baselineEnd = window.baselineLastDay
        let fetchRange = HoloAgentTimeRange(label: "体检取数窗口", start: baselineStart, end: currentEnd)

        let source = HoloDefaultCrossDomainDataSource()
        async let financeRows = source.rows(source: "finance.transactions", timeRange: fetchRange)
        async let habitRows = source.rows(source: "habit.daily", timeRange: fetchRange)
        async let taskRows = source.rows(source: "task.daily", timeRange: fetchRange)
        async let thoughtRows = source.rows(source: "thought.daily", timeRange: fetchRange)
        async let sleepRows = source.rows(source: "health.sleep", timeRange: fetchRange)
        async let stepsRows = source.rows(source: "health.steps", timeRange: fetchRange)
        async let goalRows = source.rows(source: "goal.progress.daily", timeRange: fetchRange)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        func dayKey(_ date: Date) -> String { df.string(from: date) }
        func isInCurrent(_ date: Date) -> Bool { date >= currentStart && date <= currentEnd }

        struct Bucket {
            var current: [HoloQueryRow] = []
            var baseline: [HoloQueryRow] = []
        }
        func split(_ rows: [HoloQueryRow]) -> Bucket {
            var b = Bucket()
            for r in rows {
                if isInCurrent(r.occurredAt) { b.current.append(r) }
                else { b.baseline.append(r) }
            }
            return b
        }
        func num(_ row: HoloQueryRow, _ field: String) -> Double? {
            if case .number(let v)? = row.fields[field] { return v }
            return nil
        }
        func text(_ row: HoloQueryRow, _ field: String) -> String? {
            if case .text(let v)? = row.fields[field] { return v }
            return nil
        }
        func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

        let finance = await financeRows
        let habits = await habitRows
        let tasks = await taskRows
        let thoughts = await thoughtRows
        let sleep = await sleepRows
        let steps = await stepsRows
        let goals = await goalRows

        var lines: [String] = []
        lines.append("【窗口】本期 \(df.string(from: currentStart)) ~ \(df.string(from: currentEnd))（\(windowDays) 天）；上期（环比基线）\(df.string(from: baselineStart)) ~ \(df.string(from: baselineEnd))（\(windowDays) 天）。口径：与快照同数据源（统计读源），金额 CNY；财务的分类贡献/大额/分期/已知风险另见同窗口的 finance_evidence_ledger，两份台账同源同窗、数字可互相印证。")
        lines.append("【使用规则】本台账是程序算好的体检结果，数字可直接引用；各领域结论必须有本台账或工具查询支撑。没记录的领域必须明说「无记录」，不得编造。对比上一期叫「环比」；「同比」仅用于与去年同期比较。")

        var series = DailySeries()
        var domainLines: [String] = []

        // ———— 财务（简版：总额/笔数/分类变动 top3；完整结构看 finance_evidence_ledger） ————
        let fb = split(finance)
        func financeStats(_ rows: [HoloQueryRow], into daily: inout [String: Double]) -> (expense: Double, income: Double, count: Int) {
            var e = 0.0, i = 0.0, c = 0
            for r in rows {
                let amount = num(r, "amount") ?? 0
                if text(r, "type") == "expense" {
                    e += amount
                    c += 1
                    daily[dayKey(r.occurredAt), default: 0] += amount
                } else if text(r, "type") == "income" {
                    i += amount
                }
            }
            return (e, i, c)
        }
        let fbc = financeStats(fb.baseline, into: &series.spendBaseline)
        let fc = financeStats(fb.current, into: &series.spend)
        if fc.count > 0 || fbc.count > 0 {
            func catMap(_ rows: [HoloQueryRow]) -> [String: Double] {
                var m: [String: Double] = [:]
                for r in rows where text(r, "type") == "expense" {
                    let name = FinanceEvidenceLedgerBuilder.familyName(text(r, "category") ?? "未分类")
                    m[name, default: 0] += num(r, "amount") ?? 0
                }
                return m
            }
            let cm = catMap(fb.current), bm = catMap(fb.baseline)
            // 分步计算避免长链式表达式让编译器类型推断超时
            var moving: [(String, Double, Double)] = []
            for k in Set(cm.keys).union(bm.keys) {
                let base = bm[k] ?? 0
                let cur = cm[k] ?? 0
                if abs(cur - base) >= 100 { moving.append((k, base, cur)) }
            }
            moving.sort { abs($0.2 - $0.1) > abs($1.2 - $1.1) }
            moving = Array(moving.prefix(3))
            var line = "  财务：总支出从上期 \(fmt(fbc.expense)) 元变为本期 \(fmt(fc.expense)) 元（\(fbc.count) 笔→\(fc.count) 笔）；总收入 \(fmt(fbc.income)) 元→\(fmt(fc.income)) 元"
            if !moving.isEmpty {
                line += "。分类变动最大：" + moving.map { "\($0.0) \(fmt($0.1))→\(fmt($0.2)) 元" }.joined(separator: "、")
            }
            domainLines.append(line + "。")
        } else {
            domainLines.append("  财务：本期与上期均无交易记录。")
        }

        // ———— 健康（睡眠/步数日聚合；只报时长，不判睡眠质量） ————
        func dailyValues(_ rows: [HoloQueryRow], into daily: inout [String: Double]) -> [Double] {
            var perDay: [String: Double] = [:]
            for r in rows {
                guard let v = num(r, "value"), v > 0 else { continue }
                perDay[dayKey(r.occurredAt)] = v
            }
            for (d, v) in perDay { daily[d] = v }
            return Array(perDay.values)
        }
        let slb = split(sleep)
        let sleepB = dailyValues(slb.baseline, into: &series.sleepBaseline)
        let sleepC = dailyValues(slb.current, into: &series.sleep)
        let sleepBAvg = sleepB.isEmpty ? 0 : sleepB.reduce(0, +) / Double(sleepB.count)
        let sleepCAvg = sleepC.isEmpty ? 0 : sleepC.reduce(0, +) / Double(sleepC.count)
        if !sleepC.isEmpty || !sleepB.isEmpty {
            domainLines.append("  健康·睡眠：日均时长上期 \(fmt(sleepBAvg)) 小时→本期 \(fmt(sleepCAvg)) 小时（本期有记录 \(sleepC.count) 天，其中不足 6 小时 \(sleepC.filter { $0 < 6 }.count) 天）。只能评估时长，睡眠质量无阶段数据。")
        } else {
            domainLines.append("  健康·睡眠：本期与上期均无记录。")
        }
        let stb = split(steps)
        let stepsB = dailyValues(stb.baseline, into: &series.stepsBaseline)
        let stepsC = dailyValues(stb.current, into: &series.steps)
        let stepsBAvg = stepsB.isEmpty ? 0 : stepsB.reduce(0, +) / Double(stepsB.count)
        let stepsCAvg = stepsC.isEmpty ? 0 : stepsC.reduce(0, +) / Double(stepsC.count)
        if !stepsC.isEmpty || !stepsB.isEmpty {
            domainLines.append("  健康·步数：日均步数上期 \(Int(stepsBAvg.rounded())) 步→本期 \(Int(stepsCAvg.rounded())) 步（本期有记录 \(stepsC.count) 天）。")
        }

        // ———— 习惯（逐习惯达标天数与计数/测量总量；达标=按各自目标/上限判定） ————
        // 按天矩阵的「达标习惯数」只数每日打卡型正向习惯（value>0 即当天完成）；
        // 每周型/测量型/负向型不在矩阵里逐日判——它们的达标口径是周期级的
        //（见下方 evaluatePerformance），逐日套每日目标会把维生素写成「达标 0 天」
        //（2026-11-01 复查意见必修 1 实锤）。
        let hb = split(habits)
        for r in hb.current where text(r, "type") == "check" && text(r, "polarity") == "positive" && (num(r, "value") ?? 0) > 0 {
            series.habitsMet[dayKey(r.occurredAt), default: 0] += 1
        }

        // 习惯体检：复用周期回放同款 HabitRepository.evaluatePerformance（完成天数/
        // 控制天数/累计值口径与 App 一致），本期/上期各评一次，不在台账里另写判定。
        // 上期上界取本期起点（零点上界按排他处理）——与 MemoryInsightContextBuilder
        // .previousPeriodWindow 同一口径，落在前一天会丢掉上期最后一天。窗口下界不早于
        // 习惯创建日：中途新建的习惯不拿建之前的空白天数稀释完成率，建之前的上期记为未建。
        let habitEntries: [HabitCheckupEntry] = await MainActor.run {
            let repo = HabitRepository.shared
            return repo.activeHabits.map { habit in
                let createdDay = cal.startOfDay(for: habit.createdAt)
                return HabitCheckupEntry(
                    current: repo.evaluatePerformance(for: habit, in: max(currentStart, createdDay)...currentEnd),
                    previous: createdDay < currentStart
                        ? repo.evaluatePerformance(for: habit, in: max(baselineStart, createdDay)...currentStart)
                        : nil,
                    isMeasure: habit.isMeasureType,
                    frequency: habit.habitFrequency,
                    targetCount: habit.targetCountValue
                )
            }
        }
        if habitEntries.isEmpty {
            domainLines.append("  习惯：本期无活跃习惯。")
        } else {
            var habitLines = habitEntries.prefix(10).map { "    " + habitLine($0) }
            let dormant = habitEntries.dropFirst(10)
            if !dormant.isEmpty {
                habitLines.append("    其余 \(dormant.count) 个习惯略（需要时可用工具查 habit.daily）")
            }
            domainLines.append("  习惯（完成天数与 App 同口径；每周/每月型另给周期目标与实际频次，测量型给测量天数与均值，负向型按每日上限计控制天数）：")
            domainLines.append(contentsOf: habitLines)
        }

        // ———— 任务 / 想法 / 目标 ————
        let tb = split(tasks)
        func taskStats(_ rows: [HoloQueryRow], into daily: inout [String: Double]) -> (total: Double, high: Double, days: Int) {
            var total = 0.0, high = 0.0, days = 0
            for r in rows {
                guard let v = num(r, "value") else { continue }
                total += v
                high += num(r, "highPriorityValue") ?? 0
                daily[dayKey(r.occurredAt), default: 0] += v
                days += 1
            }
            return (total, high, days)
        }
        let tbc = taskStats(tb.baseline, into: &series.tasksDoneBaseline)
        let tc = taskStats(tb.current, into: &series.tasksDone)
        if tc.days > 0 || tbc.days > 0 {
            domainLines.append("  任务：完成总数 \(Int(tbc.total.rounded())) 个→\(Int(tc.total.rounded())) 个（本期有完成记录 \(tc.days) 天，其中高优 \(Int(tc.high.rounded())) 个）。")
        } else {
            domainLines.append("  任务：本期与上期均无完成记录。")
        }

        let thb = split(thoughts)
        func thoughtStats(_ rows: [HoloQueryRow], into daily: inout [String: Double]) -> (total: Double, days: Int) {
            var total = 0.0, days = 0
            for r in rows {
                guard let v = num(r, "value") else { continue }
                total += v
                daily[dayKey(r.occurredAt), default: 0] += v
                days += 1
            }
            return (total, days)
        }
        let thbc = thoughtStats(thb.baseline, into: &series.thoughtsBaseline)
        let thc = thoughtStats(thb.current, into: &series.thoughts)
        if thc.days > 0 || thbc.days > 0 {
            domainLines.append("  想法：记录 \(Int(thbc.total.rounded())) 条→\(Int(thc.total.rounded())) 条（本期记录 \(thc.days) 天）。主题分布不在本台账，可用工具查 thought 数据集。")
        } else {
            domainLines.append("  想法：本期与上期均无记录。")
        }

        let gb = split(goals)
        if let newest = gb.current.max(by: { $0.occurredAt < $1.occurredAt }),
           let oldest = gb.current.min(by: { $0.occurredAt < $1.occurredAt }),
           let fv = num(oldest, "value"), let lv = num(newest, "value") {
            domainLines.append("  目标：活跃目标关联任务进度 \(percentText(fv))→\(percentText(lv))（本期起点→最新）。")
        } else if !gb.baseline.isEmpty {
            domainLines.append("  目标：本期无进度记录（上期有）。")
        } else {
            domainLines.append("  目标：本期与上期均无进度记录。")
        }

        lines.append("【各领域体检·本期 vs 上期】（程序计算；「→」左为上期右为本期）")
        lines.append(contentsOf: domainLines)

        // ———— 按天对齐同变候选（程序预筛，只报并发，不报因果） ————
        lines.append("【同变候选】（程序按天对齐计算的相关系数，仅代表同向/反向变化，绝不代表因果；跨域发现从下面挑 2-3 组，并用工具核验后再下结论）")
        let candidates = series.correlationCandidates()
        if candidates.isEmpty {
            lines.append("  对齐天数不足（<10 天）或相关性都太弱，本窗口没有值得点名的同变候选。")
        } else {
            for c in candidates {
                lines.append(String(format: "  %@ 与 %@：r=%+.2f（%@，对齐 %d 天，相关性%@）",
                    c.left, c.right, c.r, c.r >= 0 ? "同向变化" : "反向变化", c.n, c.strength))
            }
        }
        lines.append("  对照提示：计数型负向习惯（如记支数/次数的戒断类）可与 finance.transactions 的 _search 关键词消费对照——记录量与购买量差多少倍，是「漏记」还是「囤货」值得点名核对。")

        return lines.joined(separator: "\n")
    }

    // MARK: - 习惯体检行

    /// 一条习惯的体检行：`名称（周期目标）：本期 …；上期 …`。
    /// evaluatePerformance 的完成率分母是窗口天数——每日型直接可读；每周/每月型
    /// 读成完成率会把「每周 3 次全做到」写成「完成率 43%」，所以改给实际周频次对周目标。
    /// 测量型（体重等）的 totalValue 是逐日测量值之和，没有「累计」语义，只给测量天数与均值。
    static func habitLine(_ entry: HabitCheckupEntry) -> String {
        var head = entry.current.habitName
        if let target = entry.targetCount, entry.frequency != .daily, !entry.isMeasure,
           entry.current.polarity == .positive {
            // 台账写给模型读：周期名用固定中文，不走随系统语言变化的 displayName
            head += "（\(entry.frequency == .weekly ? "每周" : "每月")目标 \(target) 次）"
        }
        let previous = entry.previous.map { describe($0, entry) } ?? "习惯还没建立"
        return "\(head)：本期 \(describe(entry.current, entry))；上期 \(previous)"
    }

    private static func describe(_ p: HabitPerformanceSnapshot, _ entry: HabitCheckupEntry) -> String {
        let unit = p.unit ?? "次"
        if p.polarity == .negative {
            if p.successRule == .stayBelowTarget, let limit = p.targetValue {
                var t = "每日上限 \(number(limit)) \(unit)，守住 \(p.controlledDays ?? 0)/\(p.totalDays) 天"
                if let over = p.overLimitDays, over > 0 { t += "（超限 \(over) 天）" }
                if let total = p.totalValue, total > 0 {
                    t += "，累计 \(number(total)) \(unit)，日均 \(number(total / Double(max(p.totalDays, 1)))) \(unit)"
                }
                return t
            }
            return "没发生 \(p.controlledDays ?? 0)/\(p.totalDays) 天（发生 \(p.overLimitDays ?? 0) 天）"
        }
        if entry.isMeasure {
            guard p.completedDays > 0, let total = p.totalValue else { return "无测量记录" }
            return "测量 \(p.completedDays) 天，均值 \(number(total / Double(p.completedDays))) \(p.unit ?? "")"
        }
        var t = "完成 \(p.completedDays)/\(p.totalDays) 天"
        switch entry.frequency {
        case .daily:
            t += "（\(Int((p.completionRate * 100).rounded()))%）"
        case .weekly:
            t += "，平均每周 \(number(Double(p.completedDays) * 7 / Double(max(p.totalDays, 1)))) 次"
        case .monthly:
            t += "，平均每月 \(number(Double(p.completedDays) * 30 / Double(max(p.totalDays, 1)))) 次"
        }
        if let total = p.totalValue, total > 0 {
            t += "，累计 \(number(total)) \(unit)"
        }
        return t
    }

    /// 整数不带小数点，其余保留一位
    private static func number(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        return rounded.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    // MARK: - 私有工具

    private static func percentText(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))%" : String(format: "%.1f%%", v)
    }
}

/// 习惯体检行的原料：本期/上期表现（上期 nil = 上期时习惯还没建）+ 判读所需的习惯形态。
struct HabitCheckupEntry {
    let current: HabitPerformanceSnapshot
    let previous: HabitPerformanceSnapshot?
    let isMeasure: Bool
    let frequency: HabitFrequency
    let targetCount: Int?
}

/// 按天对齐矩阵：日期键 → 当日值。基线列只做体检对比，不进相关计算。
/// internal 供单测锁定预筛口径（对齐天数/强度阈值/取前三）。
struct DailySeries {
    var spend: [String: Double] = [:]
    var spendBaseline: [String: Double] = [:]
    var sleep: [String: Double] = [:]
    var sleepBaseline: [String: Double] = [:]
    var steps: [String: Double] = [:]
    var stepsBaseline: [String: Double] = [:]
    var tasksDone: [String: Double] = [:]
    var tasksDoneBaseline: [String: Double] = [:]
    var thoughts: [String: Double] = [:]
    var thoughtsBaseline: [String: Double] = [:]
    var habitsMet: [String: Double] = [:]

    struct Candidate {
        let left: String, right: String, r: Double, n: Int, strength: String
    }

    /// 本期日序列参与两两 Pearson；对齐 ≥10 天、|r|≥0.35 才入选，取最强三条
    func correlationCandidates() -> [Candidate] {
        let series: [(String, [String: Double])] = [
            ("每日支出", spend), ("睡眠时长", sleep), ("步数", steps),
            ("完成任务数", tasksDone), ("想法条数", thoughts), ("达标习惯数", habitsMet),
        ].filter { $0.1.count >= 10 }
        var out: [Candidate] = []
        for i in 0..<series.count {
            for j in (i + 1)..<series.count {
                let (a, b) = (series[i].1, series[j].1)
                let keys = Set(a.keys).intersection(b.keys)
                guard keys.count >= 10 else { continue }
                let xs = keys.map { a[$0]! }
                let ys = keys.map { b[$0]! }
                guard let r = pearson(xs, ys), r.isFinite, abs(r) >= 0.35 else { continue }
                let strength = abs(r) >= 0.7 ? "强" : (abs(r) >= 0.5 ? "中等" : "弱")
                out.append(Candidate(left: series[i].0, right: series[j].0, r: r, n: keys.count, strength: strength))
            }
        }
        return Array(out.sorted { abs($0.r) > abs($1.r) }.prefix(3))
    }

    private func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard n >= 2, xs.count == ys.count else { return nil }
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var cov = 0.0, vx = 0.0, vy = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - mx, dy = ys[i] - my
            cov += dx * dy
            vx += dx * dx
            vy += dy * dy
        }
        guard vx > 0, vy > 0 else { return nil }
        return cov / (vx.squareRoot() * vy.squareRoot())
    }
}
