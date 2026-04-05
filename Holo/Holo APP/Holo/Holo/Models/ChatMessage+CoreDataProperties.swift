//
//  ChatMessage+CoreDataProperties.swift
//  Holo
//
//  ChatMessage Core Data 属性定义
//

import Foundation
import CoreData

extension ChatMessage {

    @nonobjc class func fetchRequest() -> NSFetchRequest<ChatMessage> {
        return NSFetchRequest<ChatMessage>(entityName: "ChatMessage")
    }

    // MARK: - Attributes

    @NSManaged var id: UUID
    @NSManaged var role: String        // "user" | "assistant" | "system"
    @NSManaged var content: String
    @NSManaged var timestamp: Date
    @NSManaged var intent: String?     // AI 识别的意图
    @NSManaged var extractedDataJSON: String?  // 提取的结构化数据 JSON
    @NSManaged var isStreaming: Bool
    @NSManaged var parentMessageId: UUID?  // 关联的用户消息 ID

    // MARK: - Computed Properties

    /// 从 extractedDataJSON 中解析关联的交易 ID
    var linkedTransactionId: UUID? {
        guard let json = extractedDataJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let idStr = dict["transactionId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }
}
