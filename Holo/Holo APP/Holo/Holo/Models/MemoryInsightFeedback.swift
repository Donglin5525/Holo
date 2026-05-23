//
//  MemoryInsightFeedback.swift
//  Holo
//
//  洞察反馈 Core Data 实体
//  用户对洞察卡片的准确性/价值感反馈，UUID 弱关联 MemoryInsight
//

import Foundation
import CoreData

/// 洞察反馈实体
@objc(MemoryInsightFeedback)
public class MemoryInsightFeedback: NSManagedObject {

    @NSManaged public var id: UUID
    @NSManaged public var insightId: UUID
    @NSManaged public var cardId: String?
    @NSManaged public var accuracyRating: String?
    @NSManaged public var valueRating: String?
    @NSManaged public var reasonType: String?
    @NSManaged public var module: String?
    @NSManaged public var patternType: String?
    @NSManaged public var userCorrection: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var consumedAt: Date?
}

extension MemoryInsightFeedback: @unchecked Sendable {}
