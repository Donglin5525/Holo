#if DEBUG && targetEnvironment(simulator)
import CoreData
import Foundation

/// 仅在模拟器截图模式显式开启的主题徽章门禁夹具，不进入真机或日用数据。
@MainActor
enum HoloThoughtTopicBadgeGateSeeder {
    static func seed(in context: NSManagedObjectContext, now: Date) throws {
        let names = [
            ["Holo 产品开发与运营", "工作计划"],
            ["持续记录产品开发过程与用户反馈", "长期职业选择与工作生活节奏"],
            [String(repeating: "超长主题名称", count: 12), "工作计划"]
        ]
        for index in 0..<12 {
            let id = UUID(uuidString: String(format: "BAD6E100-0000-0000-0000-%012d", index))!
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard try context.count(for: request) == 0 else { continue }
            let thought = Thought(context: context)
            thought.id = id
            thought.content = "主题徽章回归样本 \(index)：反复上下滚动后，名称与顺序应保持一致，卡片不超出页面。"
            thought.createdAt = now.addingTimeInterval(Double(-index * 60))
            thought.updatedAt = thought.createdAt
            thought.organizedStatus = "organized"
            for (position, name) in names[index % names.count].enumerated().reversed() {
                let topic = Topic(context: context)
                topic.id = UUID(uuidString: String(format: "BAD6E100-0000-0000-0001-%012d", index * 2 + position))!
                // 每个样本独立命名，避免同名主题合并改变这组排版夹具。
                topic.title = name + "·回归\(index)"
                topic.titleSource = "user"
                topic.statusEnum = .active
                topic.createdAt = now.addingTimeInterval(Double(position))
                topic.updatedAt = topic.createdAt
                topic.addThoughts(thought)
                ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: topic)
            }
        }
        try context.save()
    }
}
#endif
