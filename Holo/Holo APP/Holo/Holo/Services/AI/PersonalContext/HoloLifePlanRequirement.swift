//
//  HoloLifePlanRequirement.swift
//  Holo
//
//  R4 情境需求与安排覆盖（方案 2026-09-23 §3.5/§3.8/§4.2 R4）。
//
//  - 覆盖是程序侧确定性计算（对象/事项/区间/频次/执行方/承诺状态六维），
//    模型只解释结果，不计算覆盖。
//  - 三态纪律（§2.4）：「问了没答复」是 asked、「约好了」是 committed、
//    「实际做了」是 performed——不可互相替代。
//  - 无记录 = 「未查到安排」（不是现实中「没有安排」）；某维缺失保持该维未知。
//  - 效果映射四类（§2.6）：covered→skip、partial→adjust、缺口→add、歧义→choice。
//  - 增量提案只生成不改业务对象；用户接受后沿现有 repository 原子提交（§3.8）。
//
//  纯逻辑（Foundation），可 standalone 编译。
//

import Foundation

// MARK: - 情境需求（规划期临时值，§3.8 SituationRequirementV1）

nonisolated struct HoloLifeSituationRequirement: Equatable, Sendable {
    /// 稳定键：责任命题 + 情境类型 + 时间窗 + 事项（§3.8）。
    /// 行程日期变化 → 键变化 → 旧提案失效（A14）。
    var requirementKey: String
    /// 依据的关系候选（contextID）。
    var relationContextIDs: [String]
    /// 适用区间（本地日半开）。
    var intervalStart: Date
    var intervalEnd: Date
    /// 需要完成的事项（喂食/换水/浇水…）。
    var dutyItems: [String]
    /// 支撑证据（evidenceRefs ID）。
    var evidenceRefs: [String]

    /// requirementKey 稳定生成（不依赖自然语言标题变体：「猫的事」=「照顾宠物」）。
    static func stableKey(
        responsibilityStatement: String,
        situationType: String,
        intervalStart: Date,
        intervalEnd: Date,
        dutyItems: [String]
    ) -> String {
        let duty = dutyItems.map { normalizedDuty($0) }.sorted().joined(separator: "|")
        let identity = [
            normalizedDuty(responsibilityStatement),
            normalizedDuty(situationType),
            String(Int(intervalStart.timeIntervalSince1970)),
            String(Int(intervalEnd.timeIntervalSince1970)),
            duty,
        ].joined(separator: "§")
        return "req-\(HoloContextSuppressionKeys.stableDigest(identity))"
    }

    /// 事项归一：去空白/「给…换水」→「换水」类动词短语归并（首版：取末两字动词倾向的
    /// 简单归一——完整归一由 R2 关系层 mention 归并提供，这里只保证同输入同输出）。
    static func normalizedDuty(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

// MARK: - 安排声明（用户后续消息/记录解析出的安排事实，S5）

nonisolated struct HoloLifeArrangementClaim: Equatable, Sendable {
    /// 承诺状态三态（§2.4；不可互相替代）。
    enum Commitment: String, Equatable, Sendable {
        /// 问了但没答复。
        case asked
        /// 明确约好（频次/事项/日期齐全才算）。
        case committed
        /// 实际发生（喂过/浇过）。
        case performed
    }

    /// 频次（某维未知保持 nil，不默认每天）。
    enum Frequency: Equatable, Sendable {
        /// 每天（覆盖区间内全部天）。
        case daily
        /// 只来一次/若干次（未覆盖区间全部天）。
        case once
        /// 频次未知。
        case unknown
    }

    /// 覆盖起始日（本地日零点）。
    var startDay: Date
    /// 覆盖结束日（含当日）。
    var endDayInclusive: Date
    /// 承诺的事项（喂食/换水…；与 dutyItems 匹配用归一化比较）。
    var dutyItems: [String]
    /// 频次。
    var frequency: Frequency
    /// 执行方（朋友/物业…；nil = 未提及）。
    var executor: String?
    /// 承诺状态。
    var commitment: Commitment

    init(
        startDay: Date,
        endDayInclusive: Date,
        dutyItems: [String],
        frequency: HoloLifeArrangementClaim.Frequency,
        executor: String? = nil,
        commitment: HoloLifeArrangementClaim.Commitment
    ) {
        self.startDay = startDay
        self.endDayInclusive = endDayInclusive
        self.dutyItems = dutyItems
        self.frequency = frequency
        self.executor = executor
        self.commitment = commitment
    }
}

// MARK: - 覆盖评估

nonisolated struct HoloLifeCoverageAssessment: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        /// 未查到任何安排记录（≠现实中没有安排）。
        case unknown
        /// 部分覆盖（某些天/事项有安排，其余未覆盖或待核实）。
        case partial
        /// 区间内全部事项有明确安排（committed/performed 且频次明确覆盖全区间）。
        case covered
        /// 明确反证（用户纠正没有该责任）。
        case contradicted
        /// 责任不适用（来源失效/命题撤回）。
        case notApplicable
    }

    var status: Status
    /// 已覆盖的本地日（partial 时给出确切覆盖范围；A10：1—3 号）。
    var coveredDays: [Date]
    /// 覆盖到的天数（诊断/文案用）。
    var coveredDayCount: Int { coveredDays.count }
    /// 哪些维度未知/待核实的说明（频次未知/事项不明/执行方未确认…）。
    var unknownDimensions: [String]
    /// 维度化待核实提示（A09：「已约一次，是否覆盖日常照料还需确认」）。
    var pendingVerificationText: String?
}

// MARK: - 覆盖计算器（程序侧确定性规则）

nonisolated enum HoloLifeArrangementCoverageCalculator {
    /// 六维覆盖计算（对象/事项/区间/频次/执行方/承诺状态；§3.5）。
    /// - Important: 无 claims = unknown（「未查到」）；asked 不算安排（A11）；
    ///   频次未知不算全区间覆盖（A09）；committed/performed + daily 才逐日覆盖。
    static func assess(
        requirement: HoloLifeSituationRequirement,
        claims: [HoloLifeArrangementClaim],
        calendar: Calendar
    ) -> HoloLifeCoverageAssessment {
        // 反证/撤回由上游（关系层 suppression）先处理；这里只见有效 claims。
        let effective = claims.filter { $0.commitment != .asked }
        let hasAskedOnly = !claims.isEmpty && effective.isEmpty
        if effective.isEmpty {
            if hasAskedOnly {
                // asked ≠ committed：问过没答复不算安排，但如实交代（A11）。
                return HoloLifeCoverageAssessment(
                    status: .unknown,
                    coveredDays: [],
                    unknownDimensions: ["已询问但尚未得到答复"],
                    pendingVerificationText: "已问过，等对方确认后才能算有安排"
                )
            }
            return HoloLifeCoverageAssessment(
                status: .unknown,
                coveredDays: [],
                unknownDimensions: ["未查到本次安排的记录"],
                pendingVerificationText: nil
            )
        }

        // 需求区间逐日展开（本地日）。
        let requirementDays = localDays(
            from: requirement.intervalStart, to: requirement.intervalEnd, calendar: calendar
        )
        let requiredDuties = Set(requirement.dutyItems.map(HoloLifeSituationRequirement.normalizedDuty))

        // 逐日判断：某天的全部必需事项是否被 committed/performed 且频次覆盖的声明满足。
        var coveredDays: [Date] = []
        var unknownDimensions: Set<String> = []
        for day in requirementDays {
            var dayCovered = true
            for duty in requiredDuties {
                let satisfying = effective.contains { claim in
                    let claimDuties = Set(claim.dutyItems.map(HoloLifeSituationRequirement.normalizedDuty))
                    guard claimDuties.contains(duty) else { return false }
                    guard !(day < claim.startDay), !(day > claim.endDayInclusive) else { return false }
                    if claim.frequency == .daily { return true }
                    // once：仅声明首日视作安排日（保守），其余天待核实。
                    if claim.frequency == .once { return calendar.isDate(day, inSameDayAs: claim.startDay) }
                    // unknown 频次：不算覆盖，记待核实维度。
                    return false
                }
                if !satisfying {
                    dayCovered = false
                    let hasUnknownFrequencyMatch = effective.contains { claim in
                        Set(claim.dutyItems.map(HoloLifeSituationRequirement.normalizedDuty)).contains(duty)
                            && !(day < claim.startDay) && !(day > claim.endDayInclusive)
                            && claim.frequency == .unknown
                    }
                    if hasUnknownFrequencyMatch {
                        unknownDimensions.insert("频次未知（是否覆盖每天待确认）")
                    }
                }
            }
            if dayCovered { coveredDays.append(day) }
        }

        if coveredDays.count == requirementDays.count {
            return HoloLifeCoverageAssessment(
                status: .covered,
                coveredDays: coveredDays,
                unknownDimensions: Array(unknownDimensions).sorted(),
                pendingVerificationText: nil
            )
        }
        if coveredDays.isEmpty {
            // 区间内没有任何一天被明确覆盖：仍是 partial 或 unknown 取决于是否有匹配事项的声明。
            let anyDutyMatch = effective.contains { claim in
                !Set(claim.dutyItems.map(HoloLifeSituationRequirement.normalizedDuty))
                    .intersection(requiredDuties).isEmpty
            }
            if !anyDutyMatch {
                return HoloLifeCoverageAssessment(
                    status: .unknown,
                    coveredDays: [],
                    unknownDimensions: ["未查到与所需事项匹配的安排"],
                    pendingVerificationText: nil
                )
            }
            return HoloLifeCoverageAssessment(
                status: .partial,
                coveredDays: [],
                unknownDimensions: Array(unknownDimensions).sorted(),
                pendingVerificationText: pendingText(for: unknownDimensions)
            )
        }
        return HoloLifeCoverageAssessment(
            status: .partial,
            coveredDays: coveredDays,
            unknownDimensions: Array(unknownDimensions).sorted(),
            pendingVerificationText: nil
        )
    }

    private static func pendingText(for dimensions: Set<String>) -> String? {
        if dimensions.contains("频次未知（是否覆盖每天待确认）") {
            return "已约过，是否覆盖这几天的日常照料还需确认"
        }
        return nil
    }

    /// 本地日序列（半开区间 → 当日零点列表）。
    static func localDays(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        var days: [Date] = []
        var current = startDay
        while current < endDay {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }
}

// MARK: - 效果映射（§2.6 四类）

nonisolated enum HoloLifeEffectMapper {
    /// 覆盖状态 → HoloContextPlanEffect.kind 白名单。
    /// covered→skip（不重复建任务）；partial→adjust（调整核实范围）；
    /// unknown→add（补缺口）；contradicted/notApplicable→skip（不提）。
    static func effectKind(for status: HoloLifeCoverageAssessment.Status) -> String {
        switch status {
        case .covered: return "skip"
        case .partial: return "adjust"
        case .unknown: return "add"
        case .contradicted, .notApplicable: return "skip"
        }
    }
}

// MARK: - 增量提案（§3.8 IncrementalMatterProposalV1；提案，非自动业务对象）

nonisolated struct HoloLifeIncrementalProposal: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        /// 新增任务（覆盖缺口新天）。
        case addTask
        /// 调整既有任务（范围/日期变化）。
        case adjustTask
        /// 完成既有任务（现实已覆盖）。
        case completeTask
    }

    /// 幂等键：matterID + logicalActionKey + before/after 摘要。
    /// 同键重复提交只生效一次（A19 重试不重复执行）。
    var proposalKey: String
    var matterID: UUID
    var targetTaskID: UUID?
    /// 逻辑动作键：不依赖自然语言标题（「猫的事」=「照顾宠物」同键）。
    var logicalActionKey: String
    /// 乐观锁：执行前核对当前修订，不匹配即失败重算（A14/A19）。
    var expectedMatterRevision: Int
    var expectedTaskRevision: Int?
    var action: Action
    var before: String?
    var after: String
    /// 支撑效果（evidence 链）。
    var reasonEffectID: String?

    static func stableProposalKey(
        matterID: UUID,
        logicalActionKey: String,
        before: String?,
        after: String
    ) -> String {
        let identity = [
            matterID.uuidString,
            HoloLifeSituationRequirement.normalizedDuty(logicalActionKey),
            before.map(HoloLifeSituationRequirement.normalizedDuty) ?? "-",
            HoloLifeSituationRequirement.normalizedDuty(after),
        ].joined(separator: "§")
        return "prop-\(HoloContextSuppressionKeys.stableDigest(identity))"
    }
}

// MARK: - 提案幂等登记（内存版；持久化沿 Matter 领域既有回执通道）

nonisolated struct HoloLifeProposalLedger {
    private(set) var appliedProposalKeys: Set<String> = []

    mutating func apply(_ proposal: HoloLifeIncrementalProposal) -> Bool {
        guard !appliedProposalKeys.contains(proposal.proposalKey) else {
            return false
        }
        appliedProposalKeys.insert(proposal.proposalKey)
        return true
    }

    public init() {}
}
