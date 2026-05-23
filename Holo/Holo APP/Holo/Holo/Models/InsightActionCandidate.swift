//
//  InsightActionCandidate.swift
//  Holo
//
//  洞察行动候选模型
//  规则生成，用户确认后执行
//

import Foundation

/// 行动候选
struct InsightActionCandidate: Codable, Equatable, Identifiable {
    let id: String
    let cardId: String
    let type: InsightActionType
    let title: String
    let payload: InsightActionPayload
    let confidence: Double
}

/// 行动 Payload（手写 Codable，带标签关联值）
enum InsightActionPayload: Equatable {
    case taskDraft(title: String, dueDate: Date?, priority: Int16?)
    case habitAdjustmentDraft(habitId: UUID, targetValue: Double?)
    case budgetReminderDraft(categoryId: UUID?, amount: Decimal?)
    case reflectionQuestion(String)
    case checkInReminder(Date)
    case noAction
}

// MARK: - 手写 Codable

extension InsightActionPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case dueDate
        case priority
        case habitId
        case targetValue
        case categoryId
        case amount
        case question
        case date
    }

    private enum Kind: String, Codable {
        case taskDraft
        case habitAdjustmentDraft
        case budgetReminderDraft
        case reflectionQuestion
        case checkInReminder
        case noAction
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .taskDraft(let title, let dueDate, let priority):
            try container.encode(Kind.taskDraft, forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(dueDate, forKey: .dueDate)
            try container.encodeIfPresent(priority, forKey: .priority)
        case .habitAdjustmentDraft(let habitId, let targetValue):
            try container.encode(Kind.habitAdjustmentDraft, forKey: .kind)
            try container.encode(habitId, forKey: .habitId)
            try container.encodeIfPresent(targetValue, forKey: .targetValue)
        case .budgetReminderDraft(let categoryId, let amount):
            try container.encode(Kind.budgetReminderDraft, forKey: .kind)
            try container.encodeIfPresent(categoryId, forKey: .categoryId)
            try container.encodeIfPresent(amount?.codableValue, forKey: .amount)
        case .reflectionQuestion(let question):
            try container.encode(Kind.reflectionQuestion, forKey: .kind)
            try container.encode(question, forKey: .question)
        case .checkInReminder(let date):
            try container.encode(Kind.checkInReminder, forKey: .kind)
            try container.encode(date, forKey: .date)
        case .noAction:
            try container.encode(Kind.noAction, forKey: .kind)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .taskDraft:
            let title = try container.decode(String.self, forKey: .title)
            let dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
            let priority = try container.decodeIfPresent(Int16.self, forKey: .priority)
            self = .taskDraft(title: title, dueDate: dueDate, priority: priority)
        case .habitAdjustmentDraft:
            let habitId = try container.decode(UUID.self, forKey: .habitId)
            let targetValue = try container.decodeIfPresent(Double.self, forKey: .targetValue)
            self = .habitAdjustmentDraft(habitId: habitId, targetValue: targetValue)
        case .budgetReminderDraft:
            let categoryId = try container.decodeIfPresent(UUID.self, forKey: .categoryId)
            let amountValue = try container.decodeIfPresent(Double.self, forKey: .amount)
            let amount = amountValue.map { Decimal(codableValue: $0) }
            self = .budgetReminderDraft(categoryId: categoryId, amount: amount)
        case .reflectionQuestion:
            let question = try container.decode(String.self, forKey: .question)
            self = .reflectionQuestion(question)
        case .checkInReminder:
            let date = try container.decode(Date.self, forKey: .date)
            self = .checkInReminder(date)
        case .noAction:
            self = .noAction
        }
    }
}
