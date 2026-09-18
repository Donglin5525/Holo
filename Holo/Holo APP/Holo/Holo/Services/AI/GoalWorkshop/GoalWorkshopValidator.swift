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
        // 模型不得关联既有习惯/目标实体（P0 授权范围外）
        if plan.draft.sourceHabitId != nil {
            throw GoalWorkshopValidationError.unauthorizedHabitReference
        }
        // 日期一律严格解析：deadline / 任务 dueDate / 里程碑 / 复盘日
        var dateTexts: [String] = []
        if let deadline = plan.draft.deadlineText { dateTexts.append(deadline) }
        for task in plan.draft.tasks {
            if let due = task.dueDateText { dateTexts.append(due) }
        }
        for milestone in plan.milestones {
            if let date = milestone.dateText { dateTexts.append(date) }
        }
        if let reviewDate = plan.reviewDateText { dateTexts.append(reviewDate) }
        for text in dateTexts where !isValidStrictDay(text) {
            throw GoalWorkshopValidationError.invalidDateText(text)
        }
    }

    private static func ensureUniqueIDs(_ ids: [String],
                                        duplicate: ([String]) -> GoalWorkshopValidationError) throws {
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        guard duplicates.isEmpty else {
            throw duplicate(duplicates)
        }
    }
}
