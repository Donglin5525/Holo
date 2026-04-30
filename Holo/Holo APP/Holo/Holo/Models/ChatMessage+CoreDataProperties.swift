//
//  ChatMessage+CoreDataProperties.swift
//  Holo
//
//  ChatMessage Core Data 属性定义
//

import Foundation
import CoreData
import ObjectiveC
import os.log

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
    @NSManaged var parsedBatchJSON: String?     // 批量解析结果
    @NSManaged var executionBatchJSON: String?  // 批量执行结果

    // MARK: - Computed Properties

    /// 从 extractedDataJSON 中解析关联的交易 ID
    var linkedTransactionId: UUID? {
        guard let idStr = extractedDataDictionary?["transactionId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }

    /// 从 extractedDataJSON 中解析关联的任务 ID
    var linkedTaskId: UUID? {
        guard let idStr = extractedDataDictionary?["taskId"] else {
            return nil
        }
        return UUID(uuidString: idStr)
    }


    /// extractedDataDictionary 缓存的 associated object key
    private static var extractedDataDictKey: UInt8 = 0
    private static var parsedBatchKey: UInt8 = 0
    private static var executionBatchKey: UInt8 = 0

    /// 解析 extractedDataJSON 为字典（带缓存，避免 body 重算时反复解析 JSON）
    var extractedDataDictionary: [String: String]? {
        // 命中缓存：NSNull 表示 nil 结果，字典表示实际数据
        if let cached = objc_getAssociatedObject(self, &Self.extractedDataDictKey) {
            return cached is NSNull ? nil : (cached as? [String: String])
        }

        // 首次解析
        let result: [String: String]?
        if let json = extractedDataJSON, let data = json.data(using: .utf8) {
            do {
                result = try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                Logger(subsystem: "com.holo.app", category: "ChatMessage")
                    .error("解析 extractedDataJSON 失败：\(error.localizedDescription)")
                result = nil
            }
        } else {
            result = nil
        }

        // 缓存：用 NSNull 作为 nil 的哨兵值
        objc_setAssociatedObject(
            self, &Self.extractedDataDictKey,
            result ?? NSNull(),
            .OBJC_ASSOCIATION_RETAIN
        )
        return result
    }

    /// 解析 parsedBatchJSON（带缓存）
    var parsedBatch: AIParseBatch? {
        if let cached = objc_getAssociatedObject(self, &Self.parsedBatchKey) {
            return cached is NSNull ? nil : (cached as? AIParseBatch)
        }

        let result: AIParseBatch?
        if let json = parsedBatchJSON, let data = json.data(using: .utf8) {
            do {
                result = try JSONDecoder().decode(AIParseBatch.self, from: data)
            } catch {
                Logger(subsystem: "com.holo.app", category: "ChatMessage")
                    .error("解析 parsedBatchJSON 失败：\(error.localizedDescription)")
                result = nil
            }
        } else {
            result = nil
        }

        objc_setAssociatedObject(self, &Self.parsedBatchKey, result ?? NSNull(), .OBJC_ASSOCIATION_RETAIN)
        return result
    }

    /// 解析 executionBatchJSON（带缓存）
    var executionBatch: AIExecutionBatch? {
        if let cached = objc_getAssociatedObject(self, &Self.executionBatchKey) {
            return cached is NSNull ? nil : (cached as? AIExecutionBatch)
        }

        let result: AIExecutionBatch?
        if let json = executionBatchJSON, let data = json.data(using: .utf8) {
            do {
                result = try JSONDecoder().decode(AIExecutionBatch.self, from: data)
            } catch {
                Logger(subsystem: "com.holo.app", category: "ChatMessage")
                    .error("解析 executionBatchJSON 失败：\(error.localizedDescription)")
                result = nil
            }
        } else {
            result = nil
        }

        objc_setAssociatedObject(self, &Self.executionBatchKey, result ?? NSNull(), .OBJC_ASSOCIATION_RETAIN)
        return result
    }
}
