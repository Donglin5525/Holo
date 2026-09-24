//
//  TodayRoutineStrip.swift
//  Holo
//
//  保持状态：习惯+健康紧凑一行与展开（今日看板 Matter 化方案 §5.4/§9.1）
//
//  - 默认一行摘要（习惯完成、睡眠、步数），正常状态不抢主行动；
//  - 有未完成习惯时可展开快速打卡；
//  - 负向（减少型）习惯只报告发生与否，不以「打卡越多越好」形式渲染；
//  - Health 未授权显示紧凑「连接 Apple Health」。
//

import SwiftUI

struct TodayRoutineStrip: View {

    let routine: HoloTodayRoutineSummary
    var onCheckIn: ((HoloTodayHabitRow) -> Void)?
    var onConnectHealth: (() -> Void)?

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "保持状态"))

            summaryLine

            if expanded, !routine.habitRows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(routine.habitRows.enumerated()), id: \.element.id) { index, row in
                        habitRow(row)
                        if index < routine.habitRows.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
        }
    }

    /// 一行摘要：习惯 3/5 · 睡眠 6.4h · 步数 4,230。
    private var summaryLine: some View {
        Button {
            if !routine.habitRows.isEmpty {
                withAnimation(HoloAnimation.standard) { expanded.toggle() }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk.motion")
                    .font(.caption)
                    .foregroundStyle(Color.holoPrimary)
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                if !routine.habitRows.isEmpty {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(routine.habitRows.isEmpty
            ? Text("")
            : Text("展开未完成的习惯"))
    }

    private var summaryText: String {
        var parts: [String] = []
        if routine.habitTotal > 0 {
            parts.append(String(localized: "习惯 \(routine.habitCompleted)/\(routine.habitTotal)"))
        } else {
            parts.append(String(localized: "习惯暂无待办"))
        }
        if let sleep = routine.sleepHours {
            parts.append(String(localized: "睡眠 \(String(format: "%.1f", sleep))h"))
        }
        if let steps = routine.steps {
            parts.append(String(localized: "步数 \(steps)"))
        }
        if !routine.hasHealthData && !routine.healthAuthorized {
            parts.append(String(localized: "连接 Apple Health"))
        }
        return parts.joined(separator: "  ·  ")
    }

    /// 未完成习惯行：负向习惯只报告（不鼓励打卡按钮语义）。
    private func habitRow(_ row: HoloTodayHabitRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.isNegative ? "minus.circle" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(row.isNegative ? Color.orange : Color.holoPrimary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if row.isNegative {
                    Text(String(localized: "减少型 · 记录发生即可"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let progress = row.progressText {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !row.isNegative {
                Button {
                    onCheckIn?(row)
                } label: {
                    Text(String(localized: "打卡"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
                        .foregroundStyle(Color.holoPrimary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("完成 \(row.name)"))
            } else {
                Button {
                    onCheckIn?(row)
                } label: {
                    Text(String(localized: "记录"))
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("记录 \(row.name) 发生"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}