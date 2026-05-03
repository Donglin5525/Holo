//
//  TaskCardView.swift
//  Holo
//
//  任务卡片视图
//

import SwiftUI
import os

struct TaskCardView: View {
    let task: TodoTask
    @ObservedObject var repository: TodoRepository
    var onNavigate: (() -> Void)?
    var isCompleting: Bool = false
    var onToggleCompletion: (() -> Void)?

    /// 是否展开检查清单
    @State private var isChecklistExpanded = false

    /// 检查清单项（排序后）
    private var checkItems: [CheckItem] {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        return items.sorted { $0.order < $1.order }
    }

    /// 是否有检查清单
    private var hasChecklist: Bool {
        !checkItems.isEmpty
    }

    /// 显示的检查项（最多5项，展开后显示全部）
    private var displayedCheckItems: [CheckItem] {
        if isChecklistExpanded {
            return checkItems
        } else {
            return Array(checkItems.prefix(5))
        }
    }

    /// 是否需要显示"更多"指示
    private var shouldShowMoreIndicator: Bool {
        checkItems.count > 5 && !isChecklistExpanded
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskCardView")

    /// 显示完成态（task 已完成 或 正在完成中）
    private var showsCompleted: Bool {
        task.completed || isCompleting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主内容行
            HStack(spacing: 12) {
                // 完成状态切换按钮
                Button(action: toggleCompletion) {
                    Image(systemName: showsCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(showsCompleted ? .holoPrimary : .holoTextSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isCompleting)

                // 任务内容（点击导航到详情页）
                Button(action: { onNavigate?() }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.holoBody)
                            .strikethrough(showsCompleted)
                            .foregroundColor(showsCompleted ? .holoTextSecondary : .holoTextPrimary)
                            .lineLimit(2)

                        // 描述（截断展示）
                        if let desc = task.desc, !desc.isEmpty {
                            Text(desc)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }

                        // 任务元信息
                        HStack(spacing: 8) {
                            // 截止日期
                            if let dueDate = task.dueDate {
                                Label(
                                    formatDueDate(dueDate),
                                    systemImage: "clock"
                                )
                                .font(.holoTinyLabel)
                                .foregroundColor(dateColor)
                            }

                            // 优先级
                            if task.taskPriority == .urgent || task.taskPriority == .high {
                                Label(
                                    task.taskPriority.displayTitle,
                                    systemImage: task.taskPriority.iconName
                                )
                                .font(.holoTinyLabel)
                                .foregroundColor(task.taskPriority.color)
                            }

                            // 重复任务标识
                            if task.repeatRule != nil {
                                Image(systemName: "repeat")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.holoPrimary)
                            }

                            // 清单名称
                            if let list = task.list {
                                Label(
                                    list.name,
                                    systemImage: "folder"
                                )
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                            }

                            // 检查清单进度
                            if hasChecklist {
                                Label(
                                    task.checkItemProgress,
                                    systemImage: "checklist"
                                )
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                            }

                            // 附件指示器
                            if let count = task.attachments?.count, count > 0 {
                                Label(
                                    "\(count)",
                                    systemImage: "paperclip"
                                )
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // 优先级指示点
                Circle()
                    .fill(task.taskPriority.color)
                    .frame(width: 6, height: 6)
            }
            .padding(HoloSpacing.md)

            // 检查清单平铺展示
            if hasChecklist {
                Divider()
                    .padding(.horizontal, HoloSpacing.md)

                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    ForEach(displayedCheckItems, id: \.id) { item in
                        HStack(spacing: 8) {
                            Button {
                                toggleCheckItem(item)
                            } label: {
                                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)

                            Text(item.title)
                                .font(.holoCaption)
                                .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                                .strikethrough(item.isChecked, color: .holoTextSecondary)

                            Spacer()
                        }
                    }

                    // 更多项指示 / 展开按钮
                    if checkItems.count > 5 {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isChecklistExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isChecklistExpanded ? "chevron.up" : "ellipsis")
                                    .font(.system(size: 12, weight: .medium))
                                Text(isChecklistExpanded ? "收起" : "还有 \(checkItems.count - 5) 项")
                                    .font(.holoTinyLabel)
                            }
                            .foregroundColor(.holoPrimary)
                            .padding(.top, HoloSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func formatDueDate(_ date: Date) -> String {
        if task.isDueToday {
            return "今天"
        } else if task.isDueTomorrow {
            return "明天"
        } else if task.isOverdue {
            return "已过期"
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日"
            return f.string(from: date)
        }
    }

    private var dateColor: Color {
        if task.isOverdue {
            return .red
        } else if task.isDueToday {
            return .orange
        } else if task.isDueTomorrow {
            return .yellow
        }
        return .holoTextSecondary
    }

    private func toggleCompletion() {
        guard !isCompleting else { return }

        // 优先使用回调（TaskListView 会在回调中区分完成/取消完成）
        if let onToggleCompletion = onToggleCompletion {
            onToggleCompletion()
            return
        }

        // 兼容搜索页等不使用撤回的场景
        let wasCompleted = task.completed
        do {
            if task.repeatRule != nil && !task.completed {
                _ = try repository.completeRepeatingTask(task)
            } else {
                try repository.toggleTaskCompletion(task)
            }
            if wasCompleted {
                HapticManager.medium()
            } else {
                HapticManager.taskCompletion()
            }
        } catch {
            Self.logger.error("切换任务状态失败: \(error.localizedDescription)")
        }
    }

    private func toggleCheckItem(_ item: CheckItem) {
        do {
            try repository.toggleCheckItem(item)
        } catch {
            Self.logger.error("切换检查项状态失败: \(error.localizedDescription)")
        }
    }
}
