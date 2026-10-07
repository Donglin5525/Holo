//
//  TodayReliefUITestSeeder.swift
//  Holo
//
//  「今天减负」UITest 数据播种（2026-10-03 实施方案 §15.1 贯穿真实旅程）
//  仅 DEBUG + UITEST_SEED_TODAY_RELIEF 启动参数生效：幂等创建 4 个根任务
//  （报名今晚 21:00 / 机票 10-10 全天 / 资料+照片无截止），标题稳定供 UI 断言。
//

#if DEBUG
import Foundation
import CoreData

@MainActor
enum TodayReliefUITestSeeder {

    static let enrollmentTitle = "UITEST-提交活动报名"
    static let flightTitle = "UITEST-预订旅行机票"
    static let materialsTitle = "UITEST-整理签证资料"
    static let photosTitle = "UITEST-冲洗旅行照片"

    @discardableResult
    static func seedIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_TODAY_RELIEF") else { return false }
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "title BEGINSWITH %@ AND deletedAt == nil", "UITEST-")
        let existing = (try? context.fetch(request)) ?? []
        guard existing.isEmpty else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let tonight = calendar.date(bySettingHour: max(calendar.component(.hour, from: now) + 1, 21), minute: 0, second: 0, of: now) ?? now
        let inAWeek = calendar.date(byAdding: .day, value: 7, to: now) ?? now

        _ = TodoTask.create(in: context, title: enrollmentTitle, dueDate: tonight)
        _ = TodoTask.create(in: context, title: flightTitle, dueDate: calendar.startOfDay(for: inAWeek), isAllDay: true)
        _ = TodoTask.create(in: context, title: materialsTitle)
        _ = TodoTask.create(in: context, title: photosTitle)
        try? context.save()
        return true
    }
}
#endif
