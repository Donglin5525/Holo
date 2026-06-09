//
//  ThoughtTagAssignment+CoreDataClass.swift
//  Holo
//
//  想法标签分配中间实体
//  记录标签来源（手动/正文/确认AI/AI/拒绝AI）、置信度、拒绝时间
//

import Foundation
import CoreData

@objc(ThoughtTagAssignment)
class ThoughtTagAssignment: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtTagAssignment> {
        NSFetchRequest<ThoughtTagAssignment>(entityName: "ThoughtTagAssignment")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var source: String
    @NSManaged var confidence: Double
    @NSManaged var assignedAt: Date
    @NSManaged var rejectedAt: Date?

    // MARK: - Relationships

    @NSManaged var thought: Thought?
    @NSManaged var tag: ThoughtTag?
}

// MARK: - Core Data Generated Accessors

extension ThoughtTagAssignment {
}

// MARK: - Source 枚举

extension ThoughtTagAssignment {

    /// 标签来源类型
    enum Source: String, CaseIterable {
        case manual       // 用户手动添加
        case inline       // 正文内 #标签 自动提取
        case confirmedAI  // 用户保留/确认过的 AI 标签
        case ai           // AI 自动生成
        case rejectedAI   // 用户删除过的 AI 标签

        /// 是否为高优先级来源（手动/正文）
        var isHighPriority: Bool {
            switch self {
            case .manual, .inline: return true
            case .confirmedAI, .ai, .rejectedAI: return false
            }
        }

        /// 是否应展示给用户
        var isVisible: Bool {
            self != .rejectedAI
        }
    }

    /// 便捷访问 source 枚举
    var sourceEnum: Source {
        get { Source(rawValue: source) ?? .ai }
        set { source = newValue.rawValue }
    }
}
