//
//  GoalWorkshopValidator.swift
//  Holo
//
//  目标共创响应校验器：字段/引用/日期/重复项/预算规则（方案 §2.2 客户端校验）
//
//  只做判定，不改状态。GoalWorkshopSessionV1.apply(_:) 在转移前调用本校验器；
//  任何失败发生在变更之前，revision 不前进。失败后由协调器做一次受控重试，
//  仍失败则保留会话并展示可编辑初稿或错误，不写业务数据。
//

import Foundation

enum GoalWorkshopValidationError: Error, Equatable {
    case sessionIDMismatch(expected: UUID, actual: UUID)
    /// 迟到/重复响应：会话 revision 已前进
    case staleResponse(sessionRevision: Int, responseRevision: Int)
    case unsupportedSchemaVersion(Int)
    case unknownKind(String)
    /// kind 与字段载荷不匹配（如 question 带了 options）
    case kindPayloadMismatch(String)
    case phaseRejectsKind(GoalWorkshopPhase, GoalWorkshopResponseV1.Kind)
    case questionBudgetExhausted
    case emptyTitle
    case emptySuccessEvidence
    case duplicateRouteIDs([String])
    case duplicateActionIDs([String])
    case danglingRecommendedOption(String)
    case danglingFirstAction(String)
    case invalidDateText(String)
    /// 模型不得自行关联既有习惯（须用户在确认页操作）
    case unauthorizedHabitReference
    /// 模型不得代答用户事实/授权记录（§2.1 客户端维护）
    case forbiddenFactProvenance(GoalWorkshopFactProvenance)
    case optionsCountOutOfBounds(Int)
    // 目标闭环 v2
    /// 引用了授权候选之外的对象（"habit:<uuid>" / "account:<uuid>"）
    case unauthorizedCandidateReference(String)
    /// 引用了本草案内不存在/类型不符的习惯草案 id
    case danglingHabitDraftReference(String)
    /// 枚举字段取值不在契约内
    case unknownEnumValue(field: String, value: String)
    /// 金额/数量/天数越界
    case valueOutOfBounds(field: String)
}

enum GoalWorkshopValidator {

    /// 严格 yyyy-MM-dd（用户时区）：位数不足、非法日历日、带时间均失败
    static let strictDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static func isValidStrictDay(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        guard let date = strictDayFormatter.date(from: text) else { return false }
        // ICU 严格模式仍把 "/" 当 "-" 的等价分隔符；解析后回格式化比对，
        // 连同全角数字、多余位数等格式变体一并拒绝
        return strictDayFormatter.string(from: date) == text
    }

    static func validate(_ response: GoalWorkshopResponseV1, for session: GoalWorkshopSessionV1) throws {
        // 会话匹配与新鲜度（迟到/重复丢弃）
        guard response.sessionID == session.id else {
            throw GoalWorkshopValidationError.sessionIDMismatch(expected: session.id, actual: response.sessionID)
        }
        guard response.revision == session.revision else {
            throw GoalWorkshopValidationError.staleResponse(
                sessionRevision: session.revision,
                responseRevision: response.revision
            )
        }
        guard !session.phase.isTerminal else {
            throw GoalWorkshopValidationError.phaseRejectsKind(session.phase, response.kind)
        }

        // 模型事实声明只允许 inference / unknown
        for fact in response.facts ?? [] {
            guard fact.provenance == .inference || fact.provenance == .unknown else {
                throw GoalWorkshopValidationError.forbiddenFactProvenance(fact.provenance)
            }
        }

        switch response.kind {
        case .question:
            try validateQuestion(response, session: session)
        case .options:
            try validateOptions(response, session: session)
        case .plan:
            try validatePlan(response, session: session)
        }
    }

    // MARK: - kind 各自的载荷与阶段规则

    private static func validateQuestion(_ response: GoalWorkshopResponseV1, session: GoalWorkshopSessionV1) throws {
        guard response.question != nil, response.options == nil, response.plan == nil else {
            throw GoalWorkshopValidationError.kindPayloadMismatch("question 载荷不匹配")
        }
        guard let question = response.question, !question.text.isEmpty, !question.whyItMatters.isEmpty else {
            throw GoalWorkshopValidationError.kindPayloadMismatch("question 缺 text/whyItMatters")
        }
        guard session.phase == .understanding || session.phase == .exploring else {
            throw GoalWorkshopValidationError.phaseRejectsKind(session.phase, .question)
        }
        guard session.questionsAsked < GoalWorkshopBudget.maxDecisionQuestions else {
            throw GoalWorkshopValidationError.questionBudgetExhausted
        }
    }

    private static func validateOptions(_ response: GoalWorkshopResponseV1, session: GoalWorkshopSessionV1) throws {
        guard response.options != nil, response.question == nil, response.plan == nil else {
            throw GoalWorkshopValidationError.kindPayloadMismatch("options 载荷不匹配")
        }
        guard session.phase == .understanding || session.phase == .exploring else {
            throw GoalWorkshopValidationError.phaseRejectsKind(session.phase, .options)
        }
        let options = response.options ?? []
        // 仅在确有实质分歧时 2–3 个；路径明显时允许单一推荐
        guard (1...3).contains(options.count) else {
            throw GoalWorkshopValidationError.optionsCountOutOfBounds(options.count)
        }
        try ensureUniqueIDs(options.map(\.id), duplicate: { .duplicateRouteIDs($0) })
        // recommendedOptionID 只能引用同一响应内实际存在的 ID
        if let recommended = response.recommendedOptionID {
            guard options.contains(where: { $0.id == recommended }) else {
                throw GoalWorkshopValidationError.danglingRecommendedOption(recommended)
            }
        }
    }

    private static func validatePlan(_ response: GoalWorkshopResponseV1, session: GoalWorkshopSessionV1) throws {
        guard response.plan != nil, response.question == nil, response.options == nil else {
            throw GoalWorkshopValidationError.kindPayloadMismatch("plan 载荷不匹配")
        }
        // understanding = 用户跳过追问直达带假设初稿；choosing = 选完路径的正常产草案
        guard session.phase == .understanding || session.phase == .choosing else {
            throw GoalWorkshopValidationError.phaseRejectsKind(session.phase, .plan)
        }
        let plan = response.plan!
        // 必填标题非空
        guard !plan.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalWorkshopValidationError.emptyTitle
        }
        // 成功证据必须可观察且非空
        guard !plan.successEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalWorkshopValidationError.emptySuccessEvidence
        }
        // 行动 ID 不重复（任务与习惯共用命名空间）
        try ensureUniqueIDs(plan.allActionIDs, duplicate: { .duplicateActionIDs($0) })
        // firstActionID 只能引用同一响应内的行动
        if let firstActionID = plan.firstActionID {
            guard plan.allActionIDs.contains(firstActionID) else {
                throw GoalWorkshopValidationError.danglingFirstAction(firstActionID)
            }
        }
        // 既有习惯引用只放行会话开始时授权的候选（§6.1 / R06）；未授权一律拒绝
        let candidates = session.candidates
        if let sourceHabitId = plan.draft.sourceHabitId, !candidates.habitIDs.contains(sourceHabitId) {
            throw GoalWorkshopValidationError.unauthorizedHabitReference
        }
        for habit in plan.draft.habits {
            if let ref = habit.reuseHabitRef {
                guard candidates.habit(ref: ref) != nil else {
                    throw GoalWorkshopValidationError.unauthorizedCandidateReference(ref)
                }
            }
            if let aggregation = habit.aggregation, !["sum", "latest"].contains(aggregation) {
                throw GoalWorkshopValidationError.unknownEnumValue(field: "habits.aggregation", value: aggregation)
            }
        }
        // 日期一律严格解析：deadline / 任务 dueDate / 里程碑 / 复盘日 / 资金期次
        var dateTexts: [String] = []
        if let deadline = plan.draft.deadlineText { dateTexts.append(deadline) }
        for task in plan.draft.tasks {
            if let due = task.dueDateText { dateTexts.append(due) }
        }
        for milestone in plan.milestones {
            if let date = milestone.dateText { dateTexts.append(date) }
        }
        if let reviewDate = plan.reviewDateText { dateTexts.append(reviewDate) }
        for installment in plan.fundSchedule ?? [] {
            dateTexts.append(installment.dueDateText)
            guard installment.amount > 0 else {
                throw GoalWorkshopValidationError.valueOutOfBounds(field: "fundSchedule.amount")
            }
        }
        for text in dateTexts where !isValidStrictDay(text) {
            throw GoalWorkshopValidationError.invalidDateText(text)
        }
        try validatePlanExtensions(plan, candidates: candidates)
    }

    // MARK: - 目标闭环 v2 扩展校验（角色与规则由代码校验，不接受模型任意 invent 的实体类型）

    private static func validatePlanExtensions(_ plan: GoalWorkshopPlan,
                                               candidates: GoalWorkshopAuthorizedCandidates) throws {
        let numericHabitDraftIDs = Set(plan.draft.habits.filter { $0.type == "numeric" }.map(\.id))
        let habitDraftIDs = Set(plan.draft.habits.map(\.id))

        if let source = plan.resultSource {
            guard let kind = GoalResultSourceKind(rawValue: source.sourceType) else {
                throw GoalWorkshopValidationError.unknownEnumValue(field: "resultSource.sourceType", value: source.sourceType)
            }
            if let scope = source.ledgerScope, GoalLedgerScopeKind(rawValue: scope) == nil {
                throw GoalWorkshopValidationError.unknownEnumValue(field: "resultSource.ledgerScope", value: scope)
            }
            if let aggregation = source.aggregation, GoalHabitAggregationKind(rawValue: aggregation) == nil {
                throw GoalWorkshopValidationError.unknownEnumValue(field: "resultSource.aggregation", value: aggregation)
            }
            if let comparison = source.comparison, GoalResultComparison(rawValue: comparison) == nil {
                throw GoalWorkshopValidationError.unknownEnumValue(field: "resultSource.comparison", value: comparison)
            }
            if let ref = source.candidateRef {
                switch kind {
                case .habit:
                    guard candidates.habit(ref: ref) != nil else {
                        throw GoalWorkshopValidationError.unauthorizedCandidateReference(ref)
                    }
                case .ledger:
                    guard candidates.account(ref: ref) != nil else {
                        throw GoalWorkshopValidationError.unauthorizedCandidateReference(ref)
                    }
                case .manual:
                    throw GoalWorkshopValidationError.unauthorizedCandidateReference(ref)
                }
            }
            if let draftID = source.habitDraftID {
                guard kind == .habit, numericHabitDraftIDs.contains(draftID) else {
                    throw GoalWorkshopValidationError.danglingHabitDraftReference(draftID)
                }
            }
            if let target = source.targetValue, !(target.isFinite && target >= 0) {
                throw GoalWorkshopValidationError.valueOutOfBounds(field: "resultSource.targetValue")
            }
        }

        if let cadence = plan.reviewCadenceDays, !(1...90).contains(cadence) {
            throw GoalWorkshopValidationError.valueOutOfBounds(field: "reviewCadenceDays")
        }

        if let budget = plan.budget {
            guard budget.amount > 0, budget.amount.isFinite else {
                throw GoalWorkshopValidationError.valueOutOfBounds(field: "budget.amount")
            }
            guard BudgetPeriod(rawValue: budget.period) != nil else {
                throw GoalWorkshopValidationError.unknownEnumValue(field: "budget.period", value: budget.period)
            }
            if let ref = budget.accountCandidateRef, candidates.account(ref: ref) == nil {
                throw GoalWorkshopValidationError.unauthorizedCandidateReference(ref)
            }
        }

        var constraintIDs: [String] = []
        for constraint in plan.constraints ?? [] {
            constraintIDs.append(constraint.id)
            guard (1...90).contains(constraint.windowDays) else {
                throw GoalWorkshopValidationError.valueOutOfBounds(field: "constraints.windowDays")
            }
            guard constraint.limitValue.isFinite, constraint.limitValue >= 0 else {
                throw GoalWorkshopValidationError.valueOutOfBounds(field: "constraints.limitValue")
            }
            switch (constraint.habitDraftID, constraint.habitCandidateRef) {
            case (let draftID?, nil):
                guard habitDraftIDs.contains(draftID) else {
                    throw GoalWorkshopValidationError.danglingHabitDraftReference(draftID)
                }
            case (nil, let ref?):
                guard candidates.habit(ref: ref) != nil else {
                    throw GoalWorkshopValidationError.unauthorizedCandidateReference(ref)
                }
            default:
                throw GoalWorkshopValidationError.kindPayloadMismatch("constraint \(constraint.id) 须二选一引用习惯草案或授权候选")
            }
        }
        try ensureUniqueIDs(constraintIDs, duplicate: { .duplicateActionIDs($0) })
    }

    private static func ensureUniqueIDs(_ ids: [String],
                                        duplicate: ([String]) -> GoalWorkshopValidationError) throws {
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        guard duplicates.isEmpty else {
            throw duplicate(duplicates)
        }
    }
}
