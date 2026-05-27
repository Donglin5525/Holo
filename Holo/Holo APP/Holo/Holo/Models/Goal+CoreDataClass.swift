//
//  Goal+CoreDataClass.swift
//  Holo
//
//  目标实体类
//

import Foundation
import CoreData

@objc(Goal)
public class Goal: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Goal> {
        NSFetchRequest<Goal>(entityName: "Goal")
    }
}
