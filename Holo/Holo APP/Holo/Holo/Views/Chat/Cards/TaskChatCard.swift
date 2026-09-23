//
//  TaskChatCard.swift
//  Holo
//
//  任务卡片视图
//

import SwiftUI

struct TaskChatCard: View {

    let data: TaskCardData
    var isDeleted: Bool = false
    var onTap: (() -> Void)?
    var onConfirm: (() -> Void)?
    /// 取消（待确认/删除确认场景）：与确认按钮成对，避免「只能确认不能反悔」
    var onCancel: (() -> Void)?
    /// 「补充条目」：锚定该任务进入追加对话（仅已确认且持有 taskId 的卡片显示）
    var onFollowUp: (() -> Void)?
    /// 待确认卡的设置行编辑入口（确认前就地改日期/提醒/清单/内容，不必进详情页）
    var onEditDueDate: (() -> Void)?
    var onEditReminders: (() -> Void)?
    var onEditList: (() -> Void)?
    var onEditContent: (() -> Void)?

    var body: some View {
        ChatCardView(isDeleted: isDeleted, onTap: data.requiresConfirmation ? nil : onTap) {
            CardHeaderView(
                icon: headerIcon,
                title: headerTitle,
                badge: headerBadge,
                // 待确认态用标题当副标题（头部标题是「任务待确认」）；
                // 其余态不再重复——底部 footer 已有日期/提醒摘要
                subtitle: data.requiresConfirmation ? data.title : nil,
                isDeleted: isDeleted
            )

            if let description = data.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(3)
                    .strikethrough(isDeleted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isModifyMode && (!data.addItems.isEmpty || !data.removeItems.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(data.addItems.prefix(6).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.holoSuccess)
                                .padding(.top, 3)
                            Text(item)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(2)
                        }
                    }
                    ForEach(Array(data.removeItems.prefix(6).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.holoError)
                                .padding(.top, 3)
                            Text(item)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                                .strikethrough()
                                .lineLimit(2)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoTextSecondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if !data.subtasks.isEmpty {
                subtasksBlock
            }

            if showsSettingsSection {
                settingsSection
            }

            if data.requiresConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    if data.isFailed, let error = data.confirmationError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.holoError)
                    }

                    HStack(spacing: 10) {
                        if data.isRecurring && !data.isFailed, let summary = data.repeatSummary {
                            HStack(spacing: 4) {
                                Image(systemName: "repeat")
                                    .font(.system(size: 10))
                                Text(summary)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.holoPrimary)
                        }

                        Spacer()

                        if !data.isFailed {
                            Button {
                                onCancel?()
                            } label: {
                                Text("取消")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.holoTextSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.holoTextSecondary.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(data.isConfirming)
                        }

                        Button {
                            onConfirm?()
                        } label: {
                            Text(confirmButtonText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(confirmButtonColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(data.isConfirming)
                    }
                }
            } else {
                HStack {
                    CardFooterView(timeText: footerText, isDeleted: isDeleted)
                    Spacer()
                    if canFollowUp {
                        Button {
                            onFollowUp?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.bubble")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("补充条目")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityLabel(String(localized: "任务卡片：\(data.title)"))
    }

    // MARK: - 子条目区块

    private var subtasksBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(data.subtasks.prefix(4).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .stroke(Color.holoTextSecondary.opacity(0.5), lineWidth: 1.3)
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                    Text(item)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(2)
                        .strikethrough(isDeleted)
                }
            }
            if data.subtasks.count > 4 {
                Text("还有 \(data.subtasks.count - 4) 项")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoTextSecondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 设置区（待确认创建卡专属）

    /// 确认前可就地调整；确认执行中冻结（弹层值会落后于路由输入）
    private var showsSettingsSection: Bool {
        data.requiresConfirmation
            && cardModeIsCreate
            && !data.isConfirming
            && !data.isCancelled
    }

    private var cardModeIsCreate: Bool { data.cardMode == .create }

    private var settingsSection: some View {
        VStack(spacing: 0) {
            settingRow(
                icon: "calendar",
                label: String(localized: "日期"),
                value: dueDateValueText,
                action: { onEditDueDate?() }
            )
            settingsDivider
            settingRow(
                icon: "bell",
                label: String(localized: "提醒"),
                value: reminderValueText,
                valueTint: reminderValueIsEmpty ? .holoTextSecondary.opacity(0.7) : .holoTextPrimary,
                action: { onEditReminders?() }
            )
            settingsDivider
            settingRow(
                icon: "tray.full",
                label: String(localized: "清单"),
                value: listValueText,
                valueTint: listWillCreate ? .holoPrimary : .holoTextPrimary,
                action: { onEditList?() }
            )
            settingsDivider
            settingRow(
                icon: "square.and.pencil",
                label: String(localized: "调整内容"),
                value: String(localized: "标题、条目、优先级"),
                action: { onEditContent?() }
            )
        }
        .padding(.vertical, 4)
        .background(Color.holoTextSecondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 44)
            .opacity(0.6)
    }

    private func settingRow(
        icon: String,
        label: String,
        value: String,
        valueTint: Color = .holoTextPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 20)

                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: HoloSpacing.md)

                Text(value)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(valueTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // contentShape 必须在 label 内：挂在外层会让整行点击识别失效（真机实锤坑）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 设置行取值

    private var dueDateValueText: String {
        TaskPendingDefaults.displayDueDate(data.dueDate) ?? String(localized: "未设置")
    }

    private var reminderValueText: String {
        if data.reminderDates.isEmpty {
            return String(localized: "未设置")
        }
        if data.reminderDates.count > 2 {
            return data.reminderDates.prefix(2).joined(separator: "、") + String(localized: " 等\(data.reminderDates.count)个")
        }
        return data.reminderDates.joined(separator: "、")
    }

    private var reminderValueIsEmpty: Bool {
        data.reminderDates.isEmpty
    }

    /// 清单显示：命中已有清单显示名字；AI 给了名但未命中显示「新建 X」；未指定显示真实落点「收件箱」
    private var listValueText: String {
        guard let name = data.listName else {
            return String(localized: "收件箱")
        }
        if listWillCreate {
            return String(localized: "新建「\(name)」")
        }
        return name
    }

    private var listWillCreate: Bool {
        guard let name = data.listName else { return false }
        return TodoRepository.shared.matchList(named: name) == nil
    }

    // MARK: - Formatting

    private var footerText: String {
        // 已确认态的摘要行：日期与提醒都要可见（确认后核对落库结果）
        var parts: [String] = []
        if let dueDate = data.dueDate, !dueDate.isEmpty {
            if let display = TaskPendingDefaults.displayDueDate(dueDate) {
                parts.append(String(localized: "日期：\(display)"))
            }
        }
        if !data.reminderDates.isEmpty {
            parts.append(String(localized: "提醒：\(data.reminderDates.joined(separator: "、"))"))
        }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return data.requiresConfirmation ? String(localized: "待确认") : String(localized: "今天")
    }

    // MARK: - Modify Mode Helpers

    private var isModifyMode: Bool { data.cardMode == .modify }
    private var isDeleteMode: Bool { data.cardMode == .delete }

    /// 已确认（非待确认态）、有真实任务 ID、未删除的卡片才能锚定补充
    private var canFollowUp: Bool {
        !data.requiresConfirmation && data.taskId != nil && !isDeleted
    }

    private var headerIcon: String {
        if data.requiresConfirmation {
            if isDeleteMode { return "trash.circle" }
            return isModifyMode ? "square.and.pencil" : "checklist.unchecked"
        }
        return "checkmark.circle"
    }

    private var headerTitle: String {
        if data.requiresConfirmation {
            if isDeleteMode { return String(localized: "删除任务待确认") }
            if data.isFailed { return String(localized: "处理失败") }
            return isModifyMode ? String(localized: "修改待办") : String(localized: "任务待确认")
        }
        if data.isCancelled { return String(localized: "已取消") }
        return data.title
    }

    private var headerBadge: CardBadge? {
        if data.isCancelled {
            return CardBadge(text: String(localized: "已取消"), color: .holoTextSecondary)
        }
        if data.isConfirming {
            return CardBadge(text: String(localized: "处理中"), color: .holoTextSecondary)
        }
        if data.requiresConfirmation {
            if isDeleteMode { return CardBadge(text: String(localized: "待删除"), color: .holoError) }
            return CardBadge(text: isModifyMode ? String(localized: "待修改") : String(localized: "待确认"), color: .holoPrimary)
        }
        return nil
    }

    private var confirmButtonText: String {
        if data.isConfirming { return String(localized: "正在处理…") }
        if isDeleteMode { return String(localized: "确认删除") }
        if data.isFailed { return String(localized: "重试") }
        return isModifyMode ? String(localized: "确认修改") : String(localized: "确认创建")
    }

    private var confirmButtonColor: Color {
        if isDeleteMode { return .holoError }
        return .holoPrimary
    }
}
