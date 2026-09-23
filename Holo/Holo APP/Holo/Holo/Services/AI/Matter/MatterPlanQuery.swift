//
//  MatterPlanQuery.swift
//  Holo
//
//  Matter V2 计划只读查询（2026-09-21 方案 §5.6 下一步确定性规则）。
//
//  单一事实口径：计划列表与下一步一律按 todoTask link 的 planOrder 排序，
//  不依赖 fetch 顺序、创建时间或标题匹配。卡片回执恢复与详情页共用。
//

import Foundation

/// 计划只读查询（MainActor：与 HoloMatterRepository 同隔离域；页面打开不请求网络或 LLM）。
@MainActor enum MatterPlanQuery {

    struct PlanTask: Identifiable, Equatable {
        let id: UUID
        let title: String
        let completed: Bool
        let planOrder: Int16
    }

    /// Matter 的计划任务（role=action 的 todoTask links 解析，按 planOrder 升序）。
    /// 已删除/已归档任务排除；已完成任务保留在计划内（展示 ✓ 与进度用）。
    /// 按 task id 去重：重复 link（历史数据/多轮修复残留）不得让 ForEach 出现重复 id
    /// （重复 id 会引发点一行多行联动的渲染错乱），planOrder 取最小值。
    static func planTasks(matterID: UUID, repository: HoloMatterRepository) -> [PlanTask] {
        let links = repository.links(matterID: matterID, linkedOnly: true)
            .filter { $0.entityType == .todoTask && $0.role == .action }
        var byID: [UUID: PlanTask] = [:]
        for link in links {
            guard let taskID = UUID(uuidString: link.entityID) else { continue }
            guard let task = repository.todoTask(id: taskID),
                  task.deletedAt == nil, !task.archived else { continue }
            let candidate = PlanTask(
                id: task.id,
                title: task.title,
                completed: task.completed,
                planOrder: link.planOrder
            )
            if let existing = byID[task.id] {
                if candidate.planOrder < existing.planOrder {
                    byID[task.id] = candidate
                }
            } else {
                byID[task.id] = candidate
            }
        }
        return byID.values.sorted { $0.planOrder < $1.planOrder }
    }

    /// 下一步 = planOrder 最小的未完成任务；无候选返回 nil（waiting / readyToComplete 由调用方判）。
    static func nextActionTask(matterID: UUID, repository: HoloMatterRepository) -> PlanTask? {
        planTasks(matterID: matterID, repository: repository)
            .first { !$0.completed }
    }

    /// 冷启动回执恢复（UseCase S4）：从 origin link 重建已启动态，不依赖临时 @State。
    /// matterTitle 供孤儿回执卡展示（云异步方案 JSON 未落时 draft 不可用的兜底）。
    static func restoreLaunchSummary(
        contextPlanMessageID: UUID,
        repository: HoloMatterRepository
    ) -> (matterID: UUID, matterTitle: String, stepCount: Int, nextAction: PlanTask?)? {
        guard let matter = repository.findMatterActivated(from: contextPlanMessageID) else {
            return nil
        }
        let tasks = planTasks(matterID: matter.id, repository: repository)
        return (matter.id, matter.title, tasks.count, tasks.first { !$0.completed })
    }
}
