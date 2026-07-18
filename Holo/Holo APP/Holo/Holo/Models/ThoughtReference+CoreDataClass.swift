//
//  ThoughtReference+CoreDataClass.swift
//  Holo
//
//  观点模块 - 引用关系实体类
//

import Foundation
import CoreData

@objc(ThoughtReference)
class ThoughtReference: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtReference> {
        NSFetchRequest<ThoughtReference>(entityName: "ThoughtReference")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var createdAt: Date
    @NSManaged var displayText: String?           // 插入时目标首行快照（@ 后显示文字）
    @NSManaged var snapshot: String?              // 插入时目标正文摘要快照（目标删除后展示）

    // MARK: - Relationships

    @NSManaged var sourceThought: Thought?
    @NSManaged var targetThought: Thought?
}
