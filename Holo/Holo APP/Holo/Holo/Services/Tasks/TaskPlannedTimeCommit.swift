import Foundation

/// 时间块拖动只提交计划时间。失败还原本次修改的字段，不回滚共享上下文中的其他编辑。
@MainActor
enum TaskPlannedTimeCommit {
    static func apply(_ task: TodoTask, start: Date, end: Date,
                      save: (TodoTask, TodoRepository.TaskPlannedTimeUpdate) throws -> Void) throws {
        let oldStart = task.plannedStart
        let oldEnd = task.plannedEnd
        let oldUpdatedAt = task.updatedAt
        do {
            try save(task, .set(start: start, end: end))
        } catch {
            task.plannedStart = oldStart
            task.plannedEnd = oldEnd
            task.updatedAt = oldUpdatedAt
            throw error
        }
    }
}
