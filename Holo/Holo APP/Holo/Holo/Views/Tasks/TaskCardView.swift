//
//  TaskCardView.swift
//  Holo
//
//  任务卡片 —— 清单色条身份 + 时间语义胶囊 + 子任务迷你进度
//  卡片解剖（原型 §04）：色条=谁的事 / 右上胶囊=什么时候 / 勾选圈=做没做 / 小胶囊=多急
//

import SwiftUI
import os

struct TaskCardView: View {
    let task: TodoTask
    @ObservedObject var repository: TodoRepository
    var onNavigate: (() -> Void)?
    var isCompleting: Bool = false
    var onToggleCompletion: (() -> Void)?
    /// 点击纪念日来源徽章时跳转
    var onNavigateToAnniversary: ((UUID) -> Void)?
    /// 点击时间胶囊弹出延期面板（nil = 胶囊不可点，如重复任务/未安排任务）
    var onPostpone: (() -> Void)?

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

    /// 显示的子任务（最多5项，展开后显示全部）
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

    /// 清单色（左侧色条身份；无清单不显示）
    private var listStripeColor: Color? {
        guard let list = task.list else { return nil }
        return Color(hex: list.color ?? "#007AFF")
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskCardView")

    /// 显示完成态（task 已完成 或 正在完成中）
    private var showsCompleted: Bool {
        task.completed || isCompleting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主内容行
            HStack(alignment: .top, spacing: 11) {
                // 完成状态切换按钮（撤回窗口内再点一下 = 撤回，误触后不用去找底部按钮）
                Button(action: toggleCompletion) {
                    Image(systemName: showsCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(showsCompleted ? .holoPrimary : .holoTextSecondary)
                }
                .buttonStyle(.plain)

                // 任务内容
                VStack(alignment: .leading, spacing: 4) {
                    // 标题 + 右上时间胶囊
                    HStack(alignment: .top, spacing: 8) {
                        Text(task.title)
                            .font(.system(size: 15, weight: .semibold))
                            .strikethrough(showsCompleted)
                            .foregroundColor(showsCompleted ? .holoTextSecondary : .holoTextPrimary)
                            .lineLimit(2)

                        Spacer(minLength: 6)

                        duePill
                            .onTapGesture {
                                // 子视图手势优先于整卡 onTap；胶囊=什么时候，点它=改什么时候
                                onPostpone?()
                            }
                    }

                    // 描述（截断展示，默认 1 行）
                    if let desc = task.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }

                    // 任务元信息（远期日期 / 优先级 / 重复 / 清单 / 纪念日来源 / 目标）
                    HStack(spacing: 8) {
                        // 截止日期：仅远期任务在 meta 行显示（今天/明天/过期已由右上胶囊承载）
                        if !showsCompleted, let dueDate = task.dueDate,
                           !task.isOverdue, !task.isDueToday, !task.isDueTomorrow {
                            Label(
                                formatDueDate(dueDate),
                                systemImage: "clock"
                            )
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                        }

                        // 优先级（仅紧急/高，小色胶囊）
                        if task.taskPriority == .urgent {
                            priorityTag(text: "紧急", color: .holoError)
                        } else if task.taskPriority == .high {
                            priorityTag(text: "高", color: Color(red: 0.96, green: 0.62, blue: 0.05))
                        }

                        // 延期痕迹：允许拖延，但让拖延可见（延期 ≥1 次才出现）
                        if !showsCompleted, task.postponedCount > 0 {
                            Label("已延期 \(task.postponedCount) 次", systemImage: "clock.arrow.circlepath")
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.holoBorder.opacity(0.6)))
                        }

                        // 重复任务标识
                        if task.repeatRule != nil {
                            Image(systemName: "repeat")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.holoPrimary)
                        }

                        // 纪念日来源徽章
                        if let anniversaryId = task.sourceAnniversaryId {
                            anniversarySourceBadge(anniversaryId)
                        }

                        // 清单名称
                        if let list = task.list {
                            Text(list.name)
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(1)
                        }

                        // 目标归属
                        if let goal = task.goal {
                            GoalBadge(goal: goal)
                        }
                    }
                }
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
                                    .foregroundColor(item.isChecked ? .holoPrimary : .holoTextSecondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)

                            Text(item.title)
                                .font(.holoCaption)
                                .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                                .strikethrough(item.isChecked, color: .holoTextSecondary)

                            Spacer()
                        }
                    }

                    // 子任务进度：n/m + 迷你进度条（与习惯磁贴计数类同款语言）
                    let completedCount = checkItems.filter(\.isChecked).count
                    HStack(spacing: 8) {
                        Text("\(completedCount)/\(checkItems.count)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.holoPrimary)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.holoDivider)

                                Capsule()
                                    .fill(Color.holoPrimary)
                                    .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(checkItems.count))
                            }
                        }
                        .frame(height: 3)

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
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.top, HoloSpacing.xs)
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        // 左侧清单色条：一眼区分归属（无清单任务无色条）
        .overlay(alignment: .leading) {
            if let stripe = listStripeColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(stripe)
                    .frame(width: 3.5)
                    .padding(.vertical, 12)
            }
        }
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
        // 整卡热区：留白、元信息、子任务平铺区点按均可进入任务页；
        // 完成圈 / 子任务勾选 / 纪念日徽章等子视图交互优先消费，不触发跳转
        .contentShape(Rectangle())
        .onTapGesture {
            onNavigate?()
        }
    }

    // MARK: - 时间语义胶囊

    /// 右上角时间胶囊：已完成绿 / 过期红 / 今天橙 / 明天蓝；远期任务不戴胶囊（降噪音，meta 行给日期）
    @ViewBuilder
    private var duePill: some View {
        if showsCompleted {
            pill(text: completedText, bg: Color.holoSuccess.opacity(0.10), fg: .holoSuccess)
        } else if task.isOverdue {
            pill(text: overdueText, bg: Color.holoError.opacity(0.09), fg: .holoError)
        } else if task.isDueToday {
            pill(text: nearText(prefix: "今天"), bg: Color.holoPrimary.opacity(0.10), fg: .holoPrimaryDark)
        } else if task.isDueTomorrow {
            pill(text: nearText(prefix: "明天"),
                 bg: Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.09),
                 fg: Color(red: 0.23, green: 0.37, blue: 0.84))
        }
    }

    private func pill(text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(bg))
            .fixedSize()
    }

    /// 完成/进行完成中：绿胶囊（有完成时刻则带上）
    private var completedText: String {
        guard !isCompleting, let completedAt = task.completedAt else { return "已完成" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "已完成 \(formatter.string(from: completedAt))"
    }

    /// 过期文案：过期 N 天（当天内过期只写「过期」）
    private var overdueText: String {
        guard let due = task.dueDate else { return "过期" }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: due),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        return days > 0 ? "过期 \(days) 天" : "过期"
    }

    /// 今天/明天胶囊文案（全天任务不带时刻）
    private func nearText(prefix: String) -> String {
        guard let due = task.dueDate, !task.isAllDay else { return prefix }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "\(prefix) \(formatter.string(from: due))"
    }

    // MARK: - 优先级小胶囊

    private func priorityTag(text: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "flag.fill")
                .font(.system(size: 7.5, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.10)))
        .fixedSize()
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

    // MARK: - 纪念日来源徽章

    /// 纪念日自动生成的任务，在元信息行显示来源徽章。
    /// 点击直达纪念日详情，形成串联闭环。
    @ViewBuilder
    private func anniversarySourceBadge(_ anniversaryId: UUID) -> some View {
        if let anniversary = AnniversaryRepository.shared.anniversary(by: anniversaryId) {
            HStack(spacing: 3) {
                Image(systemName: anniversary.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(anniversary.title)
                    .lineLimit(1)
            }
            .font(.holoTinyLabel)
            .foregroundColor(Color(hex: anniversary.color))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: anniversary.color).opacity(0.12))
            .clipShape(Capsule())
            .onTapGesture {
                HapticManager.selection()
                onNavigateToAnniversary?(anniversaryId)
            }
        } else {
            Label("纪念日", systemImage: "heart.text.square")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func toggleCompletion() {
        // 优先使用回调（TaskListView 会在回调中区分完成/取消完成/撤回）
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

            // 所有子项完成 → 通过 onToggleCompletion 走撤回流程自动完成父任务
            // 有子项未完成且父任务已完成/完成中 → 同样走回调取消或撤回
            let items = checkItems
            guard !items.isEmpty else { return }

            let allChecked = items.allSatisfy(\.isChecked)
            if allChecked && !task.completed && !isCompleting {
                onToggleCompletion?()
            } else if !allChecked && (task.completed || isCompleting) {
                onToggleCompletion?()
            }
        } catch {
            Self.logger.error("切换子任务状态失败: \(error.localizedDescription)")
        }
    }
}
