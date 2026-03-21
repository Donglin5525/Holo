//
//  TaskStatsView.swift
//  Holo
//
//  任务统计视图
//  适配 Tab 栏内布局
//

import SwiftUI

// MARK: - Stats Period

/// 统计周期
enum StatsPeriod: String, CaseIterable {
    case week = "本周"
    case month = "本月"
    case year = "本年"
    case all = "全部"
}

struct TaskStatsView: View {
    @ObservedObject var repository: TodoRepository
    let onBack: () -> Void

    @State private var selectedPeriod: StatsPeriod = .all

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            headerView

            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 周期选择器
                    periodPickerView

                    // 总览统计卡片
                    overviewCardView

                    // 按优先级统计卡片
                    priorityCardView

                    // 今日进度卡片
                    todayProgressCardView
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .background(Color.holoBackground)
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        HStack {
            // 返回按钮
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // 标题
            Text("统计")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 占位
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 周期选择器

    private var periodPickerView: some View {
        HStack(spacing: 8) {
            ForEach(StatsPeriod.allCases, id: \.self) { period in
                HoloFilterChip(
                    title: period.rawValue,
                    isSelected: selectedPeriod == period
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedPeriod = period
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - 总览统计卡片

    private var overviewCardView: some View {
        let stats = repository.getTaskStatistics()

        return VStack(spacing: HoloSpacing.md) {
            Text("总览")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: HoloSpacing.md) {
                StatItemView(
                    title: "总任务",
                    value: "\(stats.total)",
                    icon: "list.bullet",
                    color: .blue
                )

                StatItemView(
                    title: "已完成",
                    value: "\(stats.completed)",
                    icon: "checkmark.circle.fill",
                    color: .green
                )

                StatItemView(
                    title: "已过期",
                    value: "\(stats.overdue)",
                    icon: "exclamationmark.triangle.fill",
                    color: .red
                )
            }

            if stats.total > 0 {
                let completionRate = Double(stats.completed) / Double(stats.total) * 100
                HStack {
                    Text("完成率")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Text(String(format: "%.1f%%", completionRate))
                        .font(.holoBody.bold())
                        .foregroundColor(.holoPrimary)
                }
                .padding(.top, HoloSpacing.sm)

                ProgressView(value: completionRate, total: 100)
                    .progressViewStyle(.linear)
                    .tint(.holoPrimary)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - 按优先级统计卡片

    private var priorityCardView: some View {
        let priorityStats = repository.getTasksGroupedByPriority()

        return VStack(spacing: HoloSpacing.md) {
            Text("按优先级")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(TaskPriority.allCasesSorted, id: \.self) { priority in
                HStack {
                    Image(systemName: priority.iconName)
                        .foregroundColor(priority.color)
                        .frame(width: 24)

                    Text(priority.displayTitle)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text("\(priorityStats[priority] ?? 0)")
                        .font(.holoBody.bold())
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - 今日进度卡片

    private var todayProgressCardView: some View {
        let progress = repository.getTodayTaskProgress()

        return VStack(spacing: HoloSpacing.md) {
            Text("今日进度")
                .font(.holoBody.bold())
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .tint(.holoPrimary)

                HStack {
                    Text("已完成 \(progress.completed) / 共 \(progress.total)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Text(String(format: "%.0f%%", Double(progress.completed) / Double(progress.total) * 100))
                        .font(.holoBody.bold())
                        .foregroundColor(.holoPrimary)
                }
            } else {
                HStack {
                    Image(systemName: "sun.max.fill")
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                        .frame(width: 24)

                    Text("今日暂无任务")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }
}

// MARK: - Stat Item View

/// 统计项组件
private struct StatItemView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(color)

            Text(value)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Text(title)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.sm)
    }
}

// MARK: - Preview

#Preview {
    TaskStatsView(repository: TodoRepository.shared, onBack: {})
}
