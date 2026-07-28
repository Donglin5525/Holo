//
//  HoloDiscoverTool.swift
//  Holo
//
//  数据探查工具：在 Agent 写 dynamicPlan 前，先告诉模型「这个用户实际有哪些数据」。
//
//  解决问题：模型此前只能看静态 schema（habit.daily 有 value/habit 字段），
//  不知道用户的习惯叫什么名字、是什么类型，导致把"体重"猜到 profile 上空转 10 轮。
//  discover 返回实例级清单（习惯名/类型/单位、健康可用类型），让模型基于事实规划查询。
//
//  本工具是确定性数据访问（读 Core Data / Repository），不调用 LLM。
//  与 finance/habit/health 等工具同一层级，遵循 HoloDataTool 协议。
//

import Foundation

/// 数据探查工具。
/// 唯一 query：list。按域返回用户实例级数据清单。
/// 供 Agent 在规划 dynamicPlan 前调用，避免盲猜数据归属。
struct HoloDiscoverTool: HoloDataTool {
    let descriptor = HoloToolDescriptor(
        name: "discover",
        description: "数据探查：列出用户实际拥有的数据（习惯名称/类型/单位、健康可用类型、财务数据量）。写 dynamicPlan 前先调用，避免猜错数据归属",
        supportedQueries: ["list"],
        supportedTimeRanges: [],
        outputMetrics: [
            "discover.habit.count",
            "discover.health.available_types",
            "discover.finance.has_data"
        ],
        sensitivityPolicy: "normal"
        // 不提供 dynamicCatalog：discover 返回的是元数据清单，不是聚合查询
    )

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        guard request.query == "list" else {
            return .invalid(reason: "discover 仅支持 query=list")
        }
        let domain = request.parameters["domain"] ?? "all"
        let allowed = ["habit", "health", "finance", "all"]
        guard allowed.contains(domain) else {
            return .invalid(reason: "domain 仅支持 \(allowed.joined(separator: ","))")
        }
        return .valid
    }

    func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
        let domain = request.parameters["domain"] ?? "all"
        let now = Date()
        var events: [HoloEvidenceEvent] = []
        var metrics: [HoloMetric] = []
        var warnings: [HoloToolWarning] = []

        // 习惯域：实例清单（核心）。读 Core Data，无权限风险。
        // 本次事故根因修复点：让模型看到"用户有个叫体重的测量型习惯(kg)"。
        if domain == "habit" || domain == "all" {
            let habitResult = await discoverHabits(now: now)
            events.append(contentsOf: habitResult.events)
            metrics.append(contentsOf: habitResult.metrics)
            if let note = habitResult.note {
                warnings.append(HoloToolWarning(code: "DISCOVER_HABIT", message: note))
            }
        }

        // 健康域：可用类型清单（静态枚举 + 轻量提示）。
        // 不主动触发 HealthKit 读取（避免锁屏/授权弹窗），只告诉模型"健康域支持哪些类型"。
        if domain == "health" || domain == "all" {
            let healthResult = discoverHealthTypes(now: now)
            events.append(contentsOf: healthResult.events)
            metrics.append(contentsOf: healthResult.metrics)
        }

        // 财务域：数据量提示（是否有交易/账户数据）。
        if domain == "finance" || domain == "all" {
            let financeResult = await discoverFinance(now: now)
            events.append(contentsOf: financeResult.events)
            metrics.append(contentsOf: financeResult.metrics)
        }

        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: descriptor.name,
            status: events.isEmpty ? .empty : .success,
            coverage: nil,
            metrics: metrics,
            events: events,
            warnings: warnings,
            error: nil,
            sensitivity: .normal
        )
    }

    // MARK: - Habit 探查

    private struct DomainDiscovery {
        var events: [HoloEvidenceEvent]
        var metrics: [HoloMetric]
        var note: String?
    }

    /// 探查用户有哪些习惯，返回全量数据概况（总记录数 + 最早/最晚记录日期 + 近30天天数）。
    ///
    /// 设计要点：探查窗口不限固定30天——否则用户问"全年"时只看到近30天数据，会误判"数据不足"。
    /// discover 的职责是如实呈现数据全貌（有哪些习惯、各多少条、覆盖什么时段），
    /// 让模型据此判断某个时间范围（如全年）是否有足够数据可分析。
    /// "数据够不够"是模型基于真实 dynamic_query 结果判断的，discover 不替它下结论。
    private func discoverHabits(now: Date) async -> DomainDiscovery {
        // 先在 async 上下文拿习惯元信息（name/type/unit/polarity），再进 MainActor 读全量记录。
        let toolRecords = await HoloDefaultHabitDataSource().habits(timeRange: nil)

        // 直接读 Core Data 全量记录算概况，不依赖 dailyCounts 的窗口限制。
        let habits: [(habit: HoloHabitToolRecord, total: Int, earliest: Date?, latest: Date?, recent30: Int)] = await MainActor.run {
            let repo = HabitRepository.shared
            repo.loadActiveHabits()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: today) ?? today

            return toolRecords.map { habit in
                guard let uuid = UUID(uuidString: habit.id),
                      let managed = repo.activeHabits.first(where: { $0.id == uuid }) else {
                    return (habit, 0, nil, nil, 0)
                }
                let allRecords = repo.getAllRecords(for: managed)
                let total = allRecords.count
                let earliest = allRecords.map(\.date).min()
                let latest = allRecords.map(\.date).max()
                let recent30 = allRecords.filter { $0.date >= thirtyDaysAgo }.count
                return (habit, total, earliest, latest, recent30)
            }
        }

        guard !habits.isEmpty else {
            return DomainDiscovery(
                events: [],
                metrics: [HoloMetric(metricKey: "discover.habit.count", value: 0, unit: "个",
                                     baselineValue: nil, comparison: nil)],
                note: "用户没有任何活跃习惯；涉及习惯的查询会无数据"
            )
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var events: [HoloEvidenceEvent] = []
        for item in habits {
            let habit = item.habit
            let typeText = habit.isMeasureType ? "测量型" : "打卡计数型"
            let unitText = habit.unit?.isEmpty == false ? habit.unit! : "次"
            let polarityText = habit.polarity == .negative ? "负向" : "正向"
            // excerpt 是模型判断的关键：总记录数 + 覆盖时段 + 近30天活跃度，一次给全。
            // 模型据此能判断"全年有15条覆盖1-7月"→ 足以分析全年趋势，而不是只看近30天。
            let earliestText = item.earliest.map { dateFormatter.string(from: $0) } ?? "无"
            let latestText = item.latest.map { dateFormatter.string(from: $0) } ?? "无"
            let excerpt = "\(habit.name)｜\(typeText)｜单位\(unitText)｜\(polarityText)｜共\(item.total)条记录｜\(earliestText)至\(latestText)｜近30天\(item.recent30)条"
            events.append(HoloEvidenceEvent(
                id: "discover-habit-\(habit.id)",
                occurredAt: now,
                metricKey: "discover.habit.item",
                metricValue: Double(item.total),
                excerpt: excerpt,
                timeRange: nil
            ))
        }

        let note = "共 \(habits.count) 个习惯；写 dynamic_query 时 source=\"habit.daily\"，"
            + "用 habit 字段 contains 匹配名称；测量型(体重/体脂)取 value，打卡型取 count。"
            + "excerpt 里的是全量记录概况，请按用户问的时间范围判断是否足够分析"
        return DomainDiscovery(
            events: events,
            metrics: [HoloMetric(metricKey: "discover.habit.count", value: Double(habits.count), unit: "个",
                                 baselineValue: nil, comparison: nil)],
            note: note
        )
    }

    // MARK: - Health 探查（静态，不触发 HealthKit）

    /// 只返回健康域支持的类型清单，不读 HealthKit（避免锁屏/授权问题）。
    /// 模型据此知道"健康数据有 步数/睡眠/站立/活动 四类"，具体有无数据要靠 health 工具查。
    private func discoverHealthTypes(now: Date) -> DomainDiscovery {
        let kinds = HoloHealthMetricKind.allCases
        let kindNames = kinds.map(\.displayLabel).joined(separator: "、")
        let excerpt = "健康数据支持类型：\(kindNames)；具体有无数据需用 health 工具查询"
        let event = HoloEvidenceEvent(
            id: "discover-health-types",
            occurredAt: now,
            metricKey: "discover.health.available_types",
            metricValue: Double(kinds.count),
            excerpt: excerpt,
            timeRange: nil
        )
        let metric = HoloMetric(metricKey: "discover.health.available_types",
                                value: Double(kinds.count), unit: "类",
                                baselineValue: nil, comparison: nil)
        return DomainDiscovery(events: [event], metrics: [metric], note: nil)
    }

    // MARK: - Finance 探查（轻量，判断有无数据）

    /// 探查财务是否有数据。用近30天交易行数判断，避免全量读取。
    private func discoverFinance(now: Date) async -> DomainDiscovery {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: end) ?? end
        let range = HoloAgentTimeRange(label: "近30天", start: start, end: end)

        let rows = await HoloDefaultFinanceDataSource().queryRows(timeRange: range, parameters: [:])
        let hasData = !rows.isEmpty
        let excerpt = hasData
            ? "财务有数据（近30天 \(rows.count) 条交易记录）；可用 finance 工具查询"
            : "财务近30天无交易记录"
        let event = HoloEvidenceEvent(
            id: "discover-finance-summary",
            occurredAt: now,
            metricKey: "discover.finance.has_data",
            metricValue: hasData ? 1 : 0,
            excerpt: excerpt,
            timeRange: range
        )
        let metric = HoloMetric(metricKey: "discover.finance.has_data",
                                value: hasData ? 1 : 0, unit: nil,
                                baselineValue: nil, comparison: nil)
        return DomainDiscovery(events: [event], metrics: [metric], note: nil)
    }
}
