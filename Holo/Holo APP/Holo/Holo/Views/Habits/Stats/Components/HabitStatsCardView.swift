//
//  HabitStatsCardView.swift
//  Holo
//
//  习惯统计卡片组件
//  显示单个习惯的统计信息，可展开查看详情
//

import SwiftUI
import Charts

// MARK: - HabitStatsCardView

/// 习惯统计卡片视图
struct HabitStatsCardView: View {
    let item: HabitStatsItem
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 主卡片
            mainCard
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        onToggle()
                    }
                }

            // 展开详情
            if isExpanded {
                expandedContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 主卡片

    private var mainCard: some View {
        HStack(spacing: HoloSpacing.md) {
            // 图标
            iconView

            // 习惯信息
            habitInfo

            Spacer()

            // 统计数据
            statsSection

            // 展开箭头
            chevronIcon
        }
        .padding(HoloSpacing.md)
    }

    // MARK: - 图标

    private var iconView: some View {
        ZStack {
            Circle()
                .fill(item.habitColor.opacity(0.15))
                .frame(width: 44, height: 44)

            Image(systemName: item.icon)
                .font(.system(size: 20))
                .foregroundColor(item.habitColor)
        }
    }

    // MARK: - 习惯信息

    private var habitInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)

            HStack(spacing: 4) {
                // 类型标签
                typeTag

                // 连续天数
                if item.streak > 0 {
                    streakBadge
                }
            }
        }
    }

    // MARK: - 类型标签

    private var typeTag: some View {
        HStack(spacing: 2) {
            Image(systemName: item.isCheckInType ? "checkmark.circle" : "chart.line.uptrend.xyaxis")
                .font(.system(size: 10))

            Text(item.isCheckInType ? "打卡" : (item.isCountType ? "计数" : "测量"))
                .font(.holoLabel)
        }
        .foregroundColor(.holoTextSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.holoBackground)
        .clipShape(Capsule())
    }

    // MARK: - 连续天数徽章

    private var streakBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10))
                .foregroundColor(.holoPrimary)

            Text("\(item.streak)")
                .font(.holoLabel)
                .foregroundColor(.holoPrimary)
        }
    }

    // MARK: - 统计部分

    @ViewBuilder
    private var statsSection: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // 今日完成/进度
            if item.isCheckInType {
                // 打卡型
                Image(systemName: item.todayValue == 1 ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(item.todayValue == 1 ? .holoSuccess : .holoTextSecondary.opacity(0.5))
            } else {
                // 数值型
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.todayValue != nil ? String(format: "%.1f", item.todayValue!) : "--")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    if let target = item.todayTarget {
                        Text("/ \(String(format: "%.0f", target))")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            // 完成率
            Text(String(format: "%.0f%%", item.completionRate))
                .font(.holoLabel)
                .foregroundColor(item.completionRate >= 70 ? .holoSuccess : .holoTextSecondary)
        }
    }

    // MARK: - 展开箭头

    private var chevronIcon: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.holoTextSecondary)
            .rotationEffect(.degrees(isExpanded ? 0 : 0))
            .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: - 展开内容

    private var expandedContent: some View {
        VStack(spacing: HoloSpacing.md) {
            Divider()
                .padding(.horizontal, HoloSpacing.md)

            // 根据类型显示不同的图表
            if item.isCheckInType {
                // 打卡型 - 日历热力图
                HabitCalendarHeatmap(calendarData: item.calendarData)
            } else if item.isCountType {
                // 计数类 - 柱状图
                HabitBarChartView(data: item.dailyData, unit: item.unitText)
            } else {
                // 测量类 - 折线图
                HabitLineChartView(data: item.dailyData, unit: item.unitText)
            }
        }
        .padding(.bottom, HoloSpacing.md)
    }
}
