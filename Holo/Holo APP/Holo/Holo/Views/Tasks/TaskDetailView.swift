//
//  TaskDetailView.swift
//  Holo
//
//  任务只读详情页 — 查看任务信息，需要修改时点「编辑」进入编辑页
//

import SwiftUI
import CoreData
import os.log

struct TaskDetailView: View {

    @ObservedObject var task: TodoTask
    let repository: TodoRepository
    var onBack: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var selectedAttachmentIndex: Int? = nil

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: HoloSpacing.md) {
                    titleSection
                    if let desc = task.desc, !desc.isEmpty {
                        descriptionSection(desc)
                    }
                    timeInfoSection
                    attributesSection
                    if task.sourceThought != nil {
                        sourceThoughtSection
                    }
                    if !checkItems.isEmpty {
                        checklistSection
                    }
                    if !sortedAttachments.isEmpty {
                        attachmentSection
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 120)
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $showEditSheet, onDismiss: {
            // 编辑后无需额外刷新，@ObservedObject task 会自动反映变化
        }) {
            AddTaskSheet(repository: repository, task: task)
        }
        .alert("删除任务", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteTask()
            }
        } message: {
            Text("确定要删除「\(task.title)」吗？删除后可在归档管理中恢复。")
        }
        .sheet(item: Binding(
            get: { selectedAttachmentIndex.map { IndexWrapper(index: $0) } },
            set: { selectedAttachmentIndex = $0?.index }
        )) { wrapper in
            AttachmentGalleryView(
                attachments: sortedAttachments,
                startIndex: wrapper.index,
                taskId: task.id
            )
        }
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        HStack {
            Button {
                if let onBack = onBack {
                    onBack()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Text("任务详情")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Button {
                showEditSheet = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 标题区（含完成圆圈）

    private var titleSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                toggleCompletion()
            } label: {
                ZStack {
                    Circle()
                        .fill(task.completed ? Color.holoPrimary : Color.clear)
                        .frame(width: 24, height: 24)

                    Circle()
                        .stroke(task.completed ? Color.holoPrimary : Color.holoDivider, lineWidth: 2)
                        .frame(width: 24, height: 24)

                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(task.completed ? 1 : 0)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: task.completed)
            }
            .buttonStyle(.plain)

            Text(task.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(task.completed ? .holoTextSecondary : .holoTextPrimary)
                .strikethrough(task.completed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - 描述

    private func descriptionSection(_ desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 16))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 24)

            Text(desc)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - 时间信息

    @ViewBuilder
    private var timeInfoSection: some View {
        let hasTimeInfo = task.dueDate != nil || task.hasReminders || task.repeatRule != nil
        if hasTimeInfo {
            VStack(spacing: 0) {
                if let dueDate = task.dueDate {
                    infoRow(icon: "calendar", label: "截止时间", value: formatDueDate(dueDate), valueColor: dateColor)
                    Divider().background(Color.holoDivider).padding(.horizontal, 12)
                }
                if task.hasReminders {
                    let reminderText = task.remindersArray.map { $0.displayTitle }.joined(separator: "、")
                    infoRow(icon: "bell", label: "提醒", value: reminderText, valueColor: .holoTextPrimary)
                    Divider().background(Color.holoDivider).padding(.horizontal, 12)
                }
                if task.repeatRule != nil {
                    infoRow(icon: "arrow.clockwise", label: "重复", value: repeatRuleText, valueColor: .holoTextPrimary)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
        }
    }

    // MARK: - 属性（清单 / 优先级 / 状态）

    private var attributesSection: some View {
        VStack(spacing: 0) {
            if let list = task.list {
                infoRow(icon: "folder", label: "清单", value: list.name, valueColor: .holoTextPrimary)
                Divider().background(Color.holoDivider).padding(.horizontal, 12)
            }
            infoRow(
                icon: task.taskPriority.iconName,
                label: "优先级",
                value: task.taskPriority.displayTitle,
                valueColor: task.taskPriority.color
            )
            Divider().background(Color.holoDivider).padding(.horizontal, 12)
            infoRow(
                icon: task.taskStatus.iconName,
                label: "状态",
                value: task.taskStatus.displayTitle,
                valueColor: task.taskStatus.color
            )
            if let goal = task.goal {
                Divider().background(Color.holoDivider).padding(.horizontal, 12)
                infoRow(
                    icon: goal.goalDomain.icon,
                    label: "目标",
                    value: goal.title,
                    valueColor: goal.goalDomain.badgeColor
                )
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - 子任务

    // MARK: - 来源想法

    @ViewBuilder
    private var sourceThoughtSection: some View {
        if let thought = task.sourceThought {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("来自想法")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                        Text(thought.firstLine ?? String(thought.content.prefix(30)))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }

                // 选中文字转任务时保留的原文选区（任务标题后来改过时仍可追溯来源句）
                if let snippet = task.sourceTextSnippet, !snippet.isEmpty {
                    Text("原文：\(snippet)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.holoBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
        }
    }

    private var checkItems: [CheckItem] {
        (task.checkItems?.allObjects as? [CheckItem] ?? [])
            .sorted { $0.order < $1.order }
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("子任务")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                let completed = checkItems.filter { $0.isChecked }.count
                Text("\(completed)/\(checkItems.count)")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(checkItems, id: \.id) { item in
                Button {
                    toggleCheckItem(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(item.isChecked ? .holoPrimary : .holoTextSecondary)

                        Text(item.title)
                            .font(.holoBody)
                            .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                            .strikethrough(item.isChecked)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    // MARK: - 附件

    private var sortedAttachments: [TaskAttachment] {
        task.sortedAttachments
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("附件（\(sortedAttachments.count)）")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, 4)

            // 缩略图网格
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(sortedAttachments.enumerated()), id: \.element.id) { index, attachment in
                    AttachmentThumbnailView(
                        fileName: attachment.fileName,
                        taskId: task.id,
                        thumbnailData: attachment.thumbnailData
                    )
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                    .onTapGesture {
                        selectedAttachmentIndex = index
                    }
                }
            }
        }
    }

    // MARK: - 通用信息行

    private func infoRow(icon: String, label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 24)

            Text(label)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            Text(value)
                .font(.holoBody)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    // MARK: - 操作

    private func toggleCompletion() {
        do {
            if task.repeatRule != nil && !task.completed {
                _ = try repository.completeRepeatingTask(task)
            } else {
                try repository.toggleTaskCompletion(task)
            }
            if task.completed {
                HapticManager.medium()
            } else {
                HapticManager.taskCompletion()
            }
        } catch {
            Self.logger.error("切换完成状态失败: \(error.localizedDescription)")
        }
    }

    private func toggleCheckItem(_ item: CheckItem) {
        do {
            try repository.toggleCheckItem(item)
            HapticManager.light()
        } catch {
            Self.logger.error("切换子任务失败: \(error.localizedDescription)")
        }
    }

    private func deleteTask() {
        do {
            try repository.deleteTask(task)
            HapticManager.medium()
            if let onBack = onBack {
                onBack()
            } else {
                dismiss()
            }
        } catch {
            Self.logger.error("删除任务失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 格式化

    private func formatDueDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if task.isAllDay {
            f.dateFormat = "M月d日 EEE"
            return f.string(from: date)
        }
        f.dateFormat = "M月d日 EEE HH:mm"
        return f.string(from: date)
    }

    private var dateColor: Color {
        if task.isOverdue { return .holoError }
        if task.isDueToday { return .holoPrimary }
        return .holoTextPrimary
    }

    private var repeatRuleText: String {
        guard let rule = task.repeatRule else { return "不重复" }
        return rule.repeatType.displayTitle
    }
}

// MARK: - Index Wrapper（用于 sheet(item:) 绑定整数索引）

private struct IndexWrapper: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Preview

#Preview {
    TaskDetailView(task: TodoTask(context: CoreDataStack.shared.viewContext), repository: TodoRepository.shared)
}
