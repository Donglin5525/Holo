//
//  ChatTaskEditSheets.swift
//  Holo
//
//  待确认任务卡的编辑弹层（2026-09-23 从 ChatView 拆出，随栈溢出三修）
//
//  驱动 ChatView 的 .sheet(item:)：按消息 ID + itemID 定位待确认项，
//  kind 决定渲染哪个编辑弹层。初始值与写回都按 ID 重读最新状态。
//

import SwiftUI

/// 编辑会话：按消息 ID + itemID 定位待确认项，
/// kind 决定渲染哪个编辑弹层。初始值与写回都按 ID 重读最新状态。
struct PendingTaskEdit: Identifiable {
    enum Kind {
        case dueDate
        case reminders
        case list
        case content
    }

    let id = UUID()
    let messageID: UUID
    let itemID: String?
    var kind: Kind
}

/// 编辑弹层路由：弹层初始值/写回都基于重读的最新消息（编辑期间卡片可能已被更新）。
struct ChatTaskEditSheet: View {
    let viewModel: ChatViewModel
    let edit: PendingTaskEdit

    var body: some View {
        let rd = renderData(edit)
        let effective = TaskPendingDefaults.effectiveDueDate(data: rd, originalInput: rd["originalInput"])

        switch edit.kind {
        case .dueDate:
            TaskDueDateTimeSheet(
                initialDate: effective.dueDate ?? Date().addingTimeInterval(3600),
                initialAllDay: !effective.hasTime
            ) { date, allDay in
                applyPatch(edit, [
                    TaskPendingDefaults.userDueDateKey:
                        TaskPendingDefaults.formatUserDueDate(date, hasTime: !allDay)
                ])
            }

        case .reminders:
            let initial = TaskPendingDefaults.effectiveReminders(
                data: rd, dueDate: effective.dueDate, hasTime: effective.hasTime
            ) ?? []
            TaskReminderPickerSheet(
                mode: effective.hasTime ? .relative : .absolute,
                initialReminders: initial
            ) { reminders in
                applyPatch(edit, [
                    TaskPendingDefaults.userRemindersKey:
                        TaskPendingDefaults.encodeReminders(Array(reminders)) ?? "[]"
                ])
            }

        case .list:
            let initialName = TaskPendingDefaults.effectiveListName(data: rd)
            TaskListPickerSheet(
                repository: TodoRepository.shared,
                initialListId: initialName.flatMap { TodoRepository.shared.matchList(named: $0)?.id }
            ) { _, listName in
                // listName 为 nil = 收件箱（空串哨兵，同时让 AI 的 listName 失效）
                applyPatch(edit, [
                    TaskPendingDefaults.userListNameKey: listName ?? ""
                ])
            }

        case .content:
            TaskContentEditSheet(prefill: contentPrefill(from: rd)) { patch in
                applyPatch(edit, patch)
            }
        }
    }

    private func renderData(_ edit: PendingTaskEdit) -> [String: String] {
        guard let msg = viewModel.messages.first(where: { $0.id == edit.messageID }),
              let item = viewModel.pendingTaskItem(in: msg, itemID: edit.itemID) else { return [:] }
        return item.renderData ?? [:]
    }

    private func applyPatch(_ edit: PendingTaskEdit, _ patch: [String: String]) {
        guard let msg = viewModel.messages.first(where: { $0.id == edit.messageID }) else { return }
        viewModel.updatePendingTaskRenderData(from: msg, itemID: edit.itemID, patch: patch)
    }

    private func contentPrefill(from rd: [String: String]) -> TaskContentEditSheet.Prefill {
        let weekdays = Set((rd["repeatWeekdays"] ?? "")
            .split(separator: ",")
            .compactMap { Weekday(rawValue: Int($0) ?? 0) })
        return TaskContentEditSheet.Prefill(
            title: rd["title"] ?? "",
            description: rd["description"] ?? "",
            subtasks: TaskPendingDefaults.effectiveSubtasks(data: rd),
            priorityRaw: rd["priority"] ?? "1",
            repeatEnabled: rd["repeatEnabled"] == "true",
            repeatType: rd["repeatType"].flatMap { RepeatType(rawValue: $0) } ?? .daily,
            repeatInterval: rd["repeatInterval"].flatMap { Int($0) } ?? 1,
            repeatWeekdays: weekdays,
            repeatMonthDay: rd["repeatMonthDay"].flatMap { Int($0) } ?? 1
        )
    }
}
