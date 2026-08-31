//
//  CategoryLearningEntities.swift
//  Holo
//
//  分类学习同步实体类
//  随 CloudKit 私有库同步；卸载重装后随 iCloud 恢复。
//

import Foundation
import CoreData

/// 精确学习映射（candidate → 用户确认分类）
@objc(CategoryMappingRecordEntity)
public class CategoryMappingRecordEntity: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CategoryMappingRecordEntity> {
        return NSFetchRequest<CategoryMappingRecordEntity>(entityName: "CategoryMappingRecordEntity")
    }

    @NSManaged public var mappingKey: String
    @NSManaged public var transactionType: String
    @NSManaged public var primaryCategory: String
    @NSManaged public var candidate: String
    @NSManaged public var targetPrimary: String
    @NSManaged public var targetSub: String
    @NSManaged public var updatedAt: Date
}

/// LLM 归纳规则（模式匹配 → 分类）
@objc(CategoryInductionRuleEntity)
public class CategoryInductionRuleEntity: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CategoryInductionRuleEntity> {
        return NSFetchRequest<CategoryInductionRuleEntity>(entityName: "CategoryInductionRuleEntity")
    }

    @NSManaged public var ruleKey: String
    @NSManaged public var pattern: String
    @NSManaged public var matchType: String
    @NSManaged public var transactionType: String
    @NSManaged public var targetPrimary: String
    @NSManaged public var targetSub: String
    @NSManaged public var sampleCount: Int64
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
}
