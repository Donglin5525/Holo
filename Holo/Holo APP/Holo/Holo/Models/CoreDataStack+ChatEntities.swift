//
//  CoreDataStack+ChatEntities.swift
//  Holo
//
//  AI 对话相关 Core Data 实体定义
//

import CoreData

extension CoreDataStack {

    // MARK: - Chat Entities

    /// 创建 AI 对话相关实体（ChatMessage）
    nonisolated func createChatEntities() -> [NSEntityDescription] {
        let chatMessageEntity = NSEntityDescription()
        chatMessageEntity.name = "ChatMessage"
        chatMessageEntity.managedObjectClassName = "ChatMessage"

        var chatAttributes: [NSAttributeDescription] = []

        let chatId = NSAttributeDescription()
        chatId.name = "id"
        chatId.attributeType = .UUIDAttributeType
        chatId.isOptional = false
        chatId.isIndexed = true
        chatAttributes.append(chatId)

        let chatRole = NSAttributeDescription()
        chatRole.name = "role"
        chatRole.attributeType = .stringAttributeType
        chatRole.isOptional = false
        chatAttributes.append(chatRole)

        let chatContent = NSAttributeDescription()
        chatContent.name = "content"
        chatContent.attributeType = .stringAttributeType
        chatContent.isOptional = false
        chatAttributes.append(chatContent)

        let chatTimestamp = NSAttributeDescription()
        chatTimestamp.name = "timestamp"
        chatTimestamp.attributeType = .dateAttributeType
        chatTimestamp.isOptional = false
        chatTimestamp.isIndexed = true
        chatAttributes.append(chatTimestamp)

        let chatIntent = NSAttributeDescription()
        chatIntent.name = "intent"
        chatIntent.attributeType = .stringAttributeType
        chatIntent.isOptional = true
        chatAttributes.append(chatIntent)

        let chatExtractedData = NSAttributeDescription()
        chatExtractedData.name = "extractedDataJSON"
        chatExtractedData.attributeType = .stringAttributeType
        chatExtractedData.isOptional = true
        chatAttributes.append(chatExtractedData)

        let chatIsStreaming = NSAttributeDescription()
        chatIsStreaming.name = "isStreaming"
        chatIsStreaming.attributeType = .booleanAttributeType
        chatIsStreaming.isOptional = false
        chatIsStreaming.defaultValue = false
        chatAttributes.append(chatIsStreaming)

        let chatParentMessageId = NSAttributeDescription()
        chatParentMessageId.name = "parentMessageId"
        chatParentMessageId.attributeType = .UUIDAttributeType
        chatParentMessageId.isOptional = true
        chatAttributes.append(chatParentMessageId)

        let chatParsedBatch = NSAttributeDescription()
        chatParsedBatch.name = "parsedBatchJSON"
        chatParsedBatch.attributeType = .stringAttributeType
        chatParsedBatch.isOptional = true
        chatAttributes.append(chatParsedBatch)

        let chatExecutionBatch = NSAttributeDescription()
        chatExecutionBatch.name = "executionBatchJSON"
        chatExecutionBatch.attributeType = .stringAttributeType
        chatExecutionBatch.isOptional = true
        chatAttributes.append(chatExecutionBatch)

        let chatAnalysisContext = NSAttributeDescription()
        chatAnalysisContext.name = "analysisContextJSON"
        chatAnalysisContext.attributeType = .stringAttributeType
        chatAnalysisContext.isOptional = true
        chatAttributes.append(chatAnalysisContext)

        chatMessageEntity.properties = chatAttributes

        return [chatMessageEntity]
    }

}
