//
//  HoloMemoryClarificationModels.swift
//  Holo
//
//  按需澄清模型（低确认成本方案 §8.4/§10.2/§11.4）。
//
//  - 澄清卡只呈现「当前结果依赖的最小未知量」，不审核记忆全文；
//  - logicalQuestionKey 由主体/关系/范围/缺失变量规范化签名生成，不用显示文案；
//  - 提问历史仅 metadata（key/时间/次数/证据修订），不含记忆正文；
//  - 问题文案优先复用萃取时形成的 openQuestions / 规划 unknowns，本地模板兜底，
//    不在聊天关键路径新增串行模型调用（§11.4）。
//

import Foundation

/// 澄清问题卡：呈现给当前流程（计划 unknowns / 聊天澄清通道）。
nonisolated struct HoloMemoryClarificationQuestion: Equatable, Sendable {
    var recordID: String
    var logicalQuestionKey: String
    /// 展示文案（本地模板/openQuestions，非模型实时生成）。
    var questionText: String
    var missingVariable: String
    var impactSummary: String
    var options: [HoloMemoryClarificationOption]
    /// 提问时的记录版本与证据修订（回答写回与实质变化解锁的基准）。
    var recordVersionAtPrompt: String
    var evidenceRevisionAtPrompt: String
}

/// 选项：语义答案 + 适用范围（§8.5：默认最窄范围，明确长期表达才 durable）。
nonisolated struct HoloMemoryClarificationOption: Equatable, Sendable {
    var title: String
    /// 写回用的规范化答案（追加为用户声明证据）。
    var semanticAnswer: String
    /// 用户是否明确表达了长期/重复规则。
    var expressesDurableRule: Bool
    var isDismissal: Bool

    init(
        title: String,
        semanticAnswer: String,
        expressesDurableRule: Bool = false,
        isDismissal: Bool = false
    ) {
        self.title = title
        self.semanticAnswer = semanticAnswer
        self.expressesDurableRule = expressesDurableRule
        self.isDismissal = isDismissal
    }
}

/// 用户对澄清卡的回答。
nonisolated enum HoloMemoryClarificationAnswer: Equatable, Sendable {
    /// 选择了具体选项（下标对应 question.options）。
    case answered(optionIndex: Int)
    /// 「暂时不确定」/关闭/跳过 → 冷却 30 天（实质新证据可提前解锁）。
    case dismissed
    /// 「不要使用这条信息」→ suppression + 语义墓碑，不得重生。
    case doNotUse
}

/// 单个问题的提问状态（仅 metadata）。
nonisolated struct HoloMemoryClarificationQuestionState: Codable, Equatable, Sendable {
    var lastPromptedAt: Date
    var promptCount: Int
    var cooldownUntil: Date?
    /// 提问时的证据修订；变化达到实质门槛才解除冷却。
    var evidenceRevisionAtLastPrompt: String?

    init(
        lastPromptedAt: Date,
        promptCount: Int = 1,
        cooldownUntil: Date? = nil,
        evidenceRevisionAtLastPrompt: String? = nil
    ) {
        self.lastPromptedAt = lastPromptedAt
        self.promptCount = promptCount
        self.cooldownUntil = cooldownUntil
        self.evidenceRevisionAtLastPrompt = evidenceRevisionAtLastPrompt
    }
}

/// 提问历史：同题冷却账本 + 滚动窗口全局预算账本（仅 metadata，UserDefaults 持久）。
nonisolated struct HoloMemoryClarificationPromptHistory: Codable, Equatable, Sendable {
    var perQuestion: [String: HoloMemoryClarificationQuestionState]
    /// 滚动窗口内的全局提问时间（普通入口共享预算；用户主动核对不受限）。
    var recentPromptDates: [Date]

    static let empty = HoloMemoryClarificationPromptHistory(
        perQuestion: [:],
        recentPromptDates: []
    )
}
