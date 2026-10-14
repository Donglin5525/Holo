import Foundation

/// 提醒保存失败只还原提醒字段；用户草稿和其他未保存编辑继续保留。
@MainActor
enum HabitReminderCommit {
    static func apply(_ habit: Habit, mode: HabitReminderMode, time: (hour: Int, minute: Int),
                      save: (Habit, HabitUpdates) throws -> Void) throws {
        let oldMode = habit.habitReminderMode
        let oldTime = habit.reminderTime
        let oldUpdatedAt = habit.updatedAt
        do {
            try save(habit, HabitUpdates(reminderMode: mode, reminderTime: time))
        } catch {
            habit.habitReminderMode = oldMode
            habit.reminderTime = oldTime
            habit.updatedAt = oldUpdatedAt
            throw error
        }
    }
}
