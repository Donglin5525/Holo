import Foundation

/// 计划时段提交只写 planned 字段。失败还原本次修改的字段（含清空路径），
/// 不回滚共享上下文中的其他编辑。
@MainActor
enum TaskPlannedTimeCommit {
    static func apply(
        _ task: TodoTask,
        update: TodoRepository.TaskPlannedTimeUpdate,
        save: (TodoTask, TodoRepository.TaskPlannedTimeUpdate) throws -> Void
    ) throws {
        let oldStart = task.plannedStart
        let oldEnd = task.plannedEnd
        let oldUpdatedAt = task.updatedAt
        do {
            try save(task, update)
        } catch {
            task.plannedStart = oldStart
            task.plannedEnd = oldEnd
            task.updatedAt = oldUpdatedAt
            throw error
        }
    }

    /// 旧签名兼容：设值路径
    static func apply(_ task: TodoTask, start: Date, end: Date,
                      save: (TodoTask, TodoRepository.TaskPlannedTimeUpdate) throws -> Void) throws {
        try apply(task, update: .set(start: start, end: end), save: save)
    }
}
