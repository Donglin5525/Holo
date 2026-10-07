//
//  TaskCreationDraft.swift
//  Holo
//
//  轻量新增的草稿（2026-10-06 任务重构方案 §5）：承载全部字段一次保存，
//  不提前落库；预填上下文不算用户编辑；同一草稿重试中本地操作 UUID 不变。
//

import Foundation
import Combine

/// 新增入口上下文（方案 §5.2 各入口预填表）
struct TaskCreationContext: Equatable {
    /// 重要性预填（象限新增时非 unknown）
    var importance: TaskImportance = .unknown
    /// 紧急方式预填（象限新增为手动；普通新增 auto）
    var urgencyMode: TaskUrgencyMode = .auto
    /// 截止预填（今天到期范围新增 = 今天全天）
    var dueDate: Date? = nil
    var dueIsAllDay: Bool = true
    /// 清单预填（指定清单新增 = 当前清单；否则收件箱 nil）
    var listID: UUID? = nil
    /// 来源提示（象限新增显示「来自『…』，已预填分类，可调整」）
    var sourceQuadrant: TaskQuadrant? = nil
}

/// 新增草稿：标题 + 两轴 + 截止 + 清单 + 描述；一次保存建任务。
/// userEdited 只在用户真正改动后置位（预填不算），驱动取消时的未保存确认。
@MainActor
final class TaskCreationDraft: ObservableObject {

    @Published var title: String = ""
    @Published var importance: TaskImportance
    @Published var urgencyMode: TaskUrgencyMode
    @Published var hasDueDate: Bool
    @Published var dueDate: Date
    @Published var dueIsAllDay: Bool
    @Published var listID: UUID?
    @Published var note: String = ""

    /// 预填上下文（取消判定时排除的部分）
    let context: TaskCreationContext

    /// 用户是否真正编辑过（预填不算，方案 §5.4）
    @Published private(set) var userEdited: Bool = false

    /// 同一草稿重试中保持不变的本地操作 UUID（视图提交层防重，方案 §5.4）
    let localOperationID: UUID = UUID()

    init(context: TaskCreationContext = TaskCreationContext(), now: Date = Date()) {
        self.context = context
        self.importance = context.importance
        self.urgencyMode = context.urgencyMode
        self.hasDueDate = context.dueDate != nil
        self.dueDate = context.dueDate ?? now
        self.dueIsAllDay = context.dueIsAllDay
        self.listID = context.listID
    }

    // MARK: - 用户编辑标记

    func markEdited() {
        userEdited = true
    }

    /// 空白草稿：标题空白且用户没有编辑过任何字段（预填上下文不算编辑）
    var isBlank: Bool {
        !userEdited && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 提交标题：去首尾空白与换行后非空才可保存（方案 §5.1）
    var submitTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var canSave: Bool { submitTitle != nil }

    // MARK: - 实时归属预览（与首页同一解析器，方案 §5.3；紧急分 2026-10-07）

    nonisolated private var previewCalendar: Calendar {
        TaskAnalyticsPeriod.makeCalendar()
    }

    var effectiveDueForPreview: Date? {
        hasDueDate
            ? TodoTaskDatePolicy.effectiveDueDate(dueDate: dueDate, isAllDay: dueIsAllDay, calendar: previewCalendar)
            : nil
    }

    var previewQuadrant: TaskQuadrant {
        TaskQuadrantResolver.quadrant(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDueForPreview,
            now: Date(),
            calendar: previewCalendar
        )
    }

    /// 紧急分（重要性未判断 → nil）
    var urgencyScore: Int? {
        TaskQuadrantResolver.urgencyScore(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDueForPreview,
            now: Date(),
            calendar: previewCalendar
        )
    }

    /// 预览一行解释
    var previewExplanation: String {
        TaskQuadrantResolver.urgencyExplanation(
            mode: urgencyMode,
            effectiveDue: effectiveDueForPreview,
            now: Date(),
            calendar: previewCalendar
        )
    }
}
