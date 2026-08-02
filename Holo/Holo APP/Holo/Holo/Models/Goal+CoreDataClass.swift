//
//  Goal+CoreDataClass.swift
//  Holo
//
//  目标实体类
//

import Foundation
import CoreData

@objc(Goal)
public class Goal: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Goal> {
        NSFetchRequest<Goal>(entityName: "Goal")
    }
}
