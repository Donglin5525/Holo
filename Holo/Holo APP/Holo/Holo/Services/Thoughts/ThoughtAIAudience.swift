//
//  ThoughtAIAudience.swift
//  Holo
//
//  想法「AI 可见性」统一判定（2026-10-21 标签级 AI 排除方案）
//

import Foundation
import CoreData

/// 想法的 AI 受众判定：哪些想法允许进入 AI 通道（归类/洞察/报告/聊天背景/agent 数据集）。
///
/// 排除只认「用户关联」的标签（manual / inline / confirmedAI）——AI 自动打的标签不触发排除，
/// 否则 AI 给一条想法打上排除标签会反过来把它踢出 AI，再被清理撤掉标签，陷入自缠绕。
/// `thought.tags` 是编辑保存时并集回写的镜像、会混入 AI 标签，不能作为判定源；事实源是 tagAssignments。
///
/// 用法边界：**用户界面查询一律不过滤**（列表/搜索/筛选/日历/周观察/小组件照常），
/// 只有把想法内容或条数交给 AI 的调用方才套这层判定。
nonisolated enum ThoughtAIAudience {

    /// 视为用户意图的标签关联来源
    static let userAssociationSources: [String] = [
        ThoughtTagAssignment.Source.manual.rawValue,
        ThoughtTagAssignment.Source.inline.rawValue,
        ThoughtTagAssignment.Source.confirmedAI.rawValue,
    ]

    /// 「AI 可见」谓词：AND 进任意 Thought fetch 即排除命中排除标签的想法。
    static func aiVisiblePredicate() -> NSPredicate {
        NSPredicate(
            format: "SUBQUERY(tagAssignments, $a, $a.rejectedAt == nil AND $a.source IN %@ AND $a.tag.excludeFromAI == YES).@count == 0",
            userAssociationSources as CVarArg
        )
    }

    /// 既有谓词叠加 AI 可见约束。
    static func aiVisible(_ base: NSPredicate?) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [base, aiVisiblePredicate()].compactMap { $0 })
    }

    /// 管线执行器按 id 取单条想法时的谓词：未删未归档 + AI 可见 + 非排除态。
    /// 同时认 organizedStatus：多设备下 CloudKit 字段分批到达，先到的任一信号即生效。
    static func processablePredicate(thoughtID: UUID) -> NSPredicate {
        aiVisible(NSPredicate(
            format: "id == %@ AND deletedAt == nil AND isArchived == NO AND organizedStatus != %@",
            thoughtID as CVarArg, ThoughtAIClassificationPolicy.excludedStatus))
    }

    /// 内存判定，与谓词同口径；取数后过滤与单条守卫共用。
    static func isExcluded(_ thought: Thought) -> Bool {
        guard let assignments = thought.tagAssignments as? Set<ThoughtTagAssignment> else { return false }
        return assignments.contains { assignment in
            assignment.rejectedAt == nil
                && userAssociationSources.contains(assignment.source)
                && assignment.tag?.excludeFromAI == true
        }
    }

    /// 混用方法（fetchAll / search 等同时服务 UI 与 AI）的 AI 调用方取数后过滤。
    static func aiVisibleOnly(_ thoughts: [Thought]) -> [Thought] {
        thoughts.filter { !isExcluded($0) }
    }
}
