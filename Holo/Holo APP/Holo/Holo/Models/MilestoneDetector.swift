// 长廊里程碑只读共享积累事件，不从今天的连续状态反推过去。
import Foundation
import CoreData

struct MilestoneDetector {
    static func detect(context: NSManagedObjectContext,
                       achievements: MemoryAchievementSnapshot? = nil) throws -> [(date: Date, data: MilestoneData)] {
        try HoloGrowthStore.events(context: context).compactMap { event in
            guard let date = event.achievedAt else { return nil }
            return (date, MilestoneData(title: event.title,
                description: "每一次小小的记录，都留下了痕迹。",
                icon: event.metric.icon, milestoneType: .growth, growthEvent: event))
        }
    }
}
