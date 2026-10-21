//
//  HoloCloudAnalysisSnapshotBuilder.swift
//  Holo
//
//  云端异步分析（二期 M2b）——设备侧快照聚合器。
//  发起云端分析时把各数据域的结构化行数据打成一份快照 JSON（与云端查询引擎
//  的 datasets 协议对齐：{version, generatedAt, datasets:{name:{fields,rows}}}）。
//  - 取数复用 HoloDefaultCrossDomainDataSource 的统一分发（与本地 Agent 工具同一条路，
//    语义零漂移）；字段定义直接引用各工具的静态 catalog，不另维护一份。
//  - 合规边界（2026-09-10 东林拍板方案 B，取代 2026-08-30 设计稿的「健康域不进快照」）：
//    健康域以日聚合摘要进快照，沿用 v2 隐私同意与快照即焚通道；涉健康的问题不再
//    依赖本地轨道（本地分析多轮工具调用易失败，云端一次上送更可靠）。
//  - 体积控制：默认近 180 天窗口 + 单数据集行数上限，超出按时间倒序截断，
//    适配后端 2MB 快照限制。
//

import Foundation

nonisolated enum HoloCloudAnalysisSnapshotBuilder {

    struct Snapshot: Encodable {
        struct FieldDef: Encodable {
            let name: String
            let type: String
            let unit: String?
            /// 字段语义说明（如 text =「备注、说明和标签合并文本」）。
            /// 云端把它拼进工具目录，模型才知道备注类字段查什么、怎么查。
            let description: String
        }
        struct Dataset: Encodable {
            let fields: [FieldDef]
            let rows: [[String: JSONValue]]
            /// S03 完整性元数据（2026-10-04 体检）：截断前总行数；
            /// 与 rows.count 不同 = 该数据集发生过截断。旧后端忽略此字段（增量安全）。
            var totalRows: Int? = nil
            /// 快照内最老一行的发生时间（ISO8601）——截断发生时即「真实覆盖下界」，
            /// 更早的数据未进入快照，云端据此不得把截断明细冒充全量
            var coveredFrom: String? = nil
        }
        /// 冻结回答任务（AnalysisAnswerTaskV1，2026-09-19 提示词方案 P1）：
        /// 用户选择的场景、主时间范围与回答清单随快照上云，后端注入 system
        /// prompt 作为权威范围——「用户改写问句仍保留所选场景」「九月只算九月」
        /// 的同一真相源。旧后端只读 datasets，忽略此字段；nil 时不编码该键。
        struct AnswerTask: Encodable {
            struct TimeRangePayload: Encodable {
                let label: String
                /// Unix 秒（与后端 timeRange 归一约定一致）
                let start: Double
                let end: Double
            }
            let scenarioID: String
            let userQuestion: String
            let questionKind: String
            let primaryTimeRange: TimeRangePayload?
            let answerChecklist: [String]
        }
        let version: Int
        let generatedAt: Date
        let historyDays: Int
        let datasets: [String: Dataset]
        var answerTask: AnswerTask? = nil
        /// S2 融合版（2026-10-18）：财务确定性台账文本——后端注入
        /// <finance_evidence_ledger>，v26 判断法的「唯一事实真相」。旧后端忽略。
        var financeEvidenceLedger: String? = nil
        /// 02 契约 §10 最小装载清单（时刻可靠性/账户语义/合并行/补偿类目/未来行）。
        var financeSemantics: [String: String]? = nil
        /// 报告融合理解（ADR-08）：PersonalSituationBrief 个人情境背景投影，
        /// 与财务 S2 T03 共用契约；空背景=正常分析；旧后端忽略。关闭时为 nil。
        var personalSituationBrief: HoloPersonalSituationBrief? = nil
        /// 目标闭环（2026-10-20 最终规格 §6.4）：目标分析范围，由代码冻结，模型不得改写；
        /// 后端白名单校验后原样回显进结果。旧后端忽略；nil 时不编码该键。
        var goalScope: HoloAgentGoalScope? = nil
        /// 目标闭环 §6.3：该目标的统一事实快照（结果 / 执行 / 限制 / 覆盖 / 资金演算），
        /// 确定性数字的唯一来源——后端注入冻结块并入白名单；模型解释，不重算。
        var goalReview: GoalEvaluationSnapshot? = nil
    }

    enum JSONValue: Encodable {
        case number(Double)
        case text(String)
        case boolean(Bool)

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let v): try c.encode(v)
            case .text(let v): try c.encode(v)
            case .boolean(let v): try c.encode(v)
            }
        }
    }

    static let defaultHistoryDays = 180
    static let maxRowsPerDataset = 2_000

    /// 进快照的数据目录：引用各工具静态定义（字段不脱节）。
    /// 健康域自 2026-09-10 起纳入（东林拍板方案 B）：沿用 v2 隐私同意（健康与活动摘要），
    /// 走快照密文 + 完成即焚通道；仅日聚合行，不含分钟级原始样本。
    static var snapshotCatalogs: [HoloDataCatalog] {
        [
            HoloFinanceTool.dynamicCatalog,
            HoloAgentDynamicCatalogs.task,
            HoloAgentDynamicCatalogs.habit,
            HoloAgentDynamicCatalogs.thought,
            HoloAgentDynamicCatalogs.goal,
            HoloAgentDynamicCatalogs.memory,
            HoloAgentDynamicCatalogs.conversation,
            HoloAgentDynamicCatalogs.anniversary,
            HoloAgentDynamicCatalogs.insight,
            HoloAgentDynamicCatalogs.profile,
            HoloHealthTool.dynamicCatalog,
        ]
    }

    /// 快照时间值：带本地时区偏移的完整时刻（2026-09-21T22:40:00+08:00）。
    /// 带偏移前缀即用户本地日期，云端 day/month/weekend 按前缀切桶与 iOS 本地
    /// 日历同构；此前 withFullDate 把时刻截成纯日期（时段分析无数据）且按 UTC
    /// 输出，东八区凌晨交易会被切进前一天。
    /// 问句时间词 → 冻结窗口（解析器与本地 Agent 同源：最近一周/近 N 天/本月/上月/
    /// 今年…）。end 截到当前时刻：「今年/本月」等含未来段的语义，已发生统计只能算
    /// 到快照截止，与快照窗口对齐。解析不出返回 nil。（internal 供单测锁定口径）
    static func resolvedQuestionTimeRange(question: String, now: Date) -> Snapshot.AnswerTask.TimeRangePayload? {
        guard let scope = HoloAgentTimeSemanticResolver.resolve(question, referenceDate: now),
              let start = scope.timeRange.start,
              let end = scope.timeRange.end else { return nil }
        return Snapshot.AnswerTask.TimeRangePayload(
            label: "问句指定：\(scope.matchedText)",
            start: start.timeIntervalSince1970.rounded(),
            end: min(end, now).timeIntervalSince1970.rounded()
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// 聚合快照并序列化为 JSON Data（PUT body 直接使用）。
    /// scenario/userQuestion：显式场景发送时冻结为 AnswerTaskV1（时间默认窗
    /// 按 `AnalysisScenario.defaultRangeDays`，用户问句里自己指定的时间由后端
    /// 以「用户原话优先」覆盖）；nil = 常规深度分析，不带任务元数据。
    /// goalScope/goalReview：目标回顾（§6.4）——范围与事实由代码冻结，只装载与该目标
    /// 判断相关的数据集（财务/习惯/任务按绑定决定），不把全部生活记录当默认上下文。
    static func buildJSON(
        now: Date = Date(),
        historyDays: Int = defaultHistoryDays,
        maxRows: Int = maxRowsPerDataset,
        scenario: AnalysisScenario? = nil,
        userQuestion: String? = nil,
        goalScope: HoloAgentGoalScope? = nil,
        goalReview: GoalEvaluationSnapshot? = nil
    ) async throws -> Data {
        let start = Calendar.current.date(byAdding: .day, value: -historyDays, to: now) ?? now
        let range = HoloAgentTimeRange(label: "云端分析快照窗口", start: start, end: now)
        let source = HoloDefaultCrossDomainDataSource()

        // 报告融合理解（ADR-08）：个人情境背景投影（开关关闭时为空 brief，不下发）
        let situationBrief = await HoloUnderstandingContextBuilder.brief(
            question: userQuestion ?? "",
            now: now
        )

        let goalDatasetFilter = goalReview.map(Self.relevantDatasetNames(for:))
        var datasets: [String: Snapshot.Dataset] = [:]
        for catalog in snapshotCatalogs {
            for schema in catalog.datasets {
                if let goalDatasetFilter, !goalDatasetFilter.contains(schema.name) { continue }
                let rows = await source.rows(source: schema.name, timeRange: range)
                guard !rows.isEmpty else { continue }
                let sorted = rows.sorted { $0.occurredAt > $1.occurredAt }
                let limited = Array(sorted.prefix(maxRows))
                datasets[schema.name] = Snapshot.Dataset(
                    fields: schema.fields.map {
                        Snapshot.FieldDef(name: $0.name, type: $0.type.rawValue, unit: $0.unit, description: $0.description)
                    },
                    rows: limited.map { row in
                        var fields: [String: JSONValue] = [
                            "id": .text(row.id),
                            "occurredAt": .text(isoFormatter.string(from: row.occurredAt)),
                        ]
                        for (name, value) in row.fields {
                            switch value {
                            case .number(let v): fields[name] = .number(v)
                            case .text(let v): fields[name] = .text(v)
                            case .date(let v): fields[name] = .text(isoFormatter.string(from: v))
                            case .boolean(let v): fields[name] = .boolean(v)
                            }
                        }
                        if !row.excerpt.isEmpty { fields["excerpt"] = .text(row.excerpt) }
                        return fields
                    },
                    // S03：如实携带总量与覆盖下界，2000 行截断不再是黑箱
                    totalRows: rows.count,
                    coveredFrom: limited.last.map { isoFormatter.string(from: $0.occurredAt) }
                )
            }
        }
        let answerTask: Snapshot.AnswerTask?
        if let goalScope {
            // 目标回顾：范围由代码冻结（观察窗 [start, min(endExclusive, cutoff))），
            // 回答清单即规格 §3.3 的五件事；不解析问句时间词、不走场景默认窗
            let windowEnd = min(goalScope.windowEndExclusive, goalScope.snapshotCutoffAt)
            answerTask = Snapshot.AnswerTask(
                scenarioID: AnalysisScenario.goal.rawValue,
                userQuestion: userQuestion ?? AnalysisScenario.goal.question,
                questionKind: "diagnosis",
                primaryTimeRange: Snapshot.AnswerTask.TimeRangePayload(
                    label: "目标回顾窗口",
                    start: goalScope.windowStart.timeIntervalSince1970.rounded(),
                    end: windowEnd.timeIntervalSince1970.rounded()
                ),
                answerChecklist: Self.goalReviewChecklist
            )
        } else if let scenario {
            let question = (userQuestion?.isEmpty == false) ? userQuestion! : scenario.question
            answerTask = Snapshot.AnswerTask(
                scenarioID: scenario.rawValue,
                userQuestion: question,
                questionKind: scenario.answerTaskKind,
                // 用户改写问句里的时间词优先于场景默认窗——「用户说的时间永远最准」
                primaryTimeRange: Self.resolvedQuestionTimeRange(question: question, now: now)
                    ?? scenario.defaultRangeDays.map { days in
                        let rangeStart = now.addingTimeInterval(-Double(days) * 86_400)
                        return Snapshot.AnswerTask.TimeRangePayload(
                            label: "最近\(days)天",
                            start: rangeStart.timeIntervalSince1970.rounded(),
                            end: now.timeIntervalSince1970.rounded()
                        )
                    },
                answerChecklist: scenario.answerChecklist
            )
        } else if let question = userQuestion, !question.isEmpty {
            // 自由问句同样冻结时间窗：此前只有场景卡带窗，聊天打字问「最近一周」
            // 时任务窗缺失，云端退回快照默认窗（180 天）全窗分析（2026-09-24 实锤）。
            // 解析不出时间词则不带窗，保持默认窗语义，不瞎猜。
            answerTask = Snapshot.AnswerTask(
                scenarioID: "",
                userQuestion: question,
                questionKind: "general",
                primaryTimeRange: Self.resolvedQuestionTimeRange(question: question, now: now),
                answerChecklist: []
            )
        } else {
            answerTask = nil
        }
        // S2 融合版：财务数据集在场时生成确定性台账（本地预计算，不受快照行数限制）
        var financeLedger: String? = nil
        var financeSemantics: [String: String]? = nil
        if datasets.keys.contains("finance.transactions") {
            let built = await FinanceEvidenceLedgerBuilder.build(now: now)
            financeLedger = built?.ledger
            financeSemantics = built?.semantics
        }
        let snapshot = Snapshot(
            version: 1,
            generatedAt: now,
            historyDays: historyDays,
            datasets: datasets,
            answerTask: answerTask,
            financeEvidenceLedger: financeLedger,
            financeSemantics: financeSemantics,
            personalSituationBrief: situationBrief.isEmpty ? nil : situationBrief,
            goalScope: goalScope,
            goalReview: goalReview
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    // MARK: - 目标回顾（§3.3 / §6.4）

    /// 报告优先回答的五件事（随快照冻结进回答清单；模型逐项回答，缺证据明确说不能判断）
    static let goalReviewChecklist: [String] = [
        "当初想达到什么、这轮按哪个计划执行",
        "行动做了多少、结果变化多少、限制有没有被突破，各自来源与观测时间",
        "差距主要在哪里：执行没跟上、方法未见效、负担或环境变化、限制冲突，还是证据暂缺",
        "哪些原因有证据、哪些只是待确认线索；最需要用户补的关键问题是什么",
        "下一步继续什么、建议改什么、预期观察什么、何时复查",
    ]

    /// 只装载与该目标判断相关的数据集：财务（ledger 结果或预算限制）、习惯（习惯绑定/限制）、
    /// 任务（任务绑定）、目标自身进度。健康/想法等与本目标无关的记录不进快照（§6.4）。
    static func relevantDatasetNames(for review: GoalEvaluationSnapshot) -> Set<String> {
        var names: Set<String> = ["goal.progress.daily"]
        if review.result.sourceKind == .ledger || review.constraints.contains(where: { $0.kind == .budget }) || review.fundPlan != nil {
            names.insert("finance.transactions")
        }
        if review.execution.contains(where: { $0.entityType == .habit }) || review.constraints.contains(where: { $0.kind == .habitLimit })
            || review.result.sourceKind == .habit {
            names.insert("habit.daily")
        }
        if review.execution.contains(where: { $0.entityType == .task }) {
            names.insert("task.daily")
        }
        return names
    }
}
