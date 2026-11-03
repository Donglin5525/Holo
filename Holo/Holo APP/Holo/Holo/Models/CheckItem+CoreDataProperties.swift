//
//  CheckItem+CoreDataProperties.swift
//  Holo
//
//  子任务实体属性扩展
//

import Foundation
import CoreData

extension CheckItem: Identifiable {}

extension CheckItem {

    // MARK: - 创建方法

    @nonobjc public class func create(
        in context: NSManagedObjectContext,
        title: String,
        task: TodoTask,
        order: Int16 = 0,
        isWaiting: Bool = false,
        waitNote: String? = nil,
        waitHints: [String] = []
    ) -> CheckItem {
        let item = CheckItem(context: context)
        item.id = UUID()
        item.title = title
        item.task = task
        item.order = order
        item.isChecked = false
        item.isWaiting = isWaiting
        item.waitNote = waitNote
        item.waitHints = waitHints
        item.createdAt = Date()
        return item
    }

    // MARK: - 等待候选词（JSON 数组字符串的编解码存取）

    var waitHints: [String] {
        get {
            guard let json = waitHintsJSON,
                  let data = json.data(using: .utf8),
                  let hints = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return hints
        }
        set {
            guard !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                waitHintsJSON = nil
                return
            }
            waitHintsJSON = json
        }
    }
}
