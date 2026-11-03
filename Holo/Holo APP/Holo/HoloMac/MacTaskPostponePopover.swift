//
//  MacTaskPostponePopover.swift
//  HoloMac
//
//  延期选项 popover + 移动到清单 popover。
//  选项生成走 TaskPostponePolicy（iOS 三入口共用的唯一规则源，
//  永不出现选项不一致）；落库走 TodoRepository.postpone，快照供撤回。
//

import SwiftUI

// MARK: - 延期 popover

struct MacTaskPostponePopover: View {

    let task: TodoTask
    /// 延期完成回执：toast 文案 + 撤回动作
    let onPostponed: (String, @escaping () -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    private let repository = TodoRepository.shared

    private var options: [TaskPostponeOption] {
        guard let due = task.dueDate else { return [] }
        return TaskPostponePolicy.options(
            dueDate: due,
            isAllDay: task.isAllDay,
            isOverdue: task.isOverdue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "延期到"))
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(options.filter { !$0.isCustom }) { option in
                Button {
                    postpone(to: option)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 13, weight: option.isPrimary ? .semibold : .regular))
                                .foregroundColor(option.isPrimary ? Color.holoPrimaryDark : Color.holoToolText)
                            Text(option.subLabel)
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                        }
                        Spacer()
                        if option.isPrimary {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundColor(Color.holoPrimary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 4)

            // 自定义日期（DatePicker 内嵌）
            HStack(spacing: 8) {
                Text(String(localized: "选日期"))
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolText)
                DatePicker(
                    "",
                    selection: Binding(
                        get: { task.dueDate ?? Date() },
                        set: { newDate in
                            postponeCustom(to: newDate)
                        }),
                    displayedComponents: task.isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 240)
    }

    private func postpone(to option: TaskPostponeOption) {
        guard let target = option.targetDate else { return }
        applyPostpone(targetDate: target, isAllDay: option.isAllDay)
    }

    private func postponeCustom(to date: Date) {
        applyPostpone(targetDate: date, isAllDay: task.isAllDay)
    }

    private func applyPostpone(targetDate: Date, isAllDay: Bool) {
        // 落库失败不再弹「已延期」成功回执（2026-10-31 审计 M5）：
        // 保留 popover 让用户重试，撤回闭包也不携带无效快照。
        let snapshot: TaskPostponeSnapshot
        do {
            snapshot = try repository.postpone(task: task, toDate: targetDate, isAllDay: isAllDay)
        } catch {
            onPostponed(String(localized: "延期失败，请重试")) {}
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        var message = String(localized: "已延期到 ") + formatter.string(from: targetDate)
        if !isAllDay {
            let time = DateFormatter()
            time.locale = Locale(identifier: "zh_CN")
            time.dateFormat = " HH:mm"
            message += time.string(from: targetDate)
        }
        dismiss()
        onPostponed(message) { [weak repository] in
            repository?.restorePostponed([snapshot])
            repository?.notifyDataChange()
        }
    }
}

// MARK: - 移动到清单 popover

struct MacTaskMoveToListPopover: View {

    let task: TodoTask

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repository = TodoRepository.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "移动到"))
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            Button {
                try? repository.updateTask(task, list: .clear)
                repository.notifyDataChange()
                dismiss()
            } label: {
                Label(String(localized: "收件箱"), systemImage: "tray")
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(repository.allActiveLists(), id: \.id) { list in
                Button {
                    try? repository.updateTask(task, list: .set(list))
                    repository.notifyDataChange()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: list.color ?? "#007AFF"))
                            .frame(width: 8, height: 8)
                        Text(list.name ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(.holoToolText)
                        Spacer()
                        if task.list?.id == list.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11))
                                .foregroundColor(Color.holoPrimary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)
        }
        .frame(minWidth: 220)
    }
}
