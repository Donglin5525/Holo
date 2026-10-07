//
//  HabitRowView.swift
//  Holo
//
//  今天页连续习惯行（2026-10 重构，V2 调整职责）：
//  左侧名字/图标/摘要 =「今天的记录」入口；右侧动作按钮独立命中。
//  三十天缝线只读（积累摘要，不承担导航，V2 §5.1）。
//

import SwiftUI

extension HabitRowSnapshot: HabitIconRenderable {}

struct HabitRowView: View {

    let snapshot: HabitRowSnapshot
    /// 该行正在保存（按钮禁用，防重复提交的可见态）
    let isSaving: Bool
    /// 行内错误消息（覆盖副标题位置短暂显示）
    let inlineErrorMessage: String?
    var onOpenTodayRecords: () -> Void
    var onToggleCheckIn: () -> Void
    var onIncrement: () -> Void
    var onDecrement: () -> Void
    var onMeasureRecord: () -> Void

    // MARK: 文案

    /// 坏习惯今日超上限（数值型才有；行内红化的统一开关）
    private var isOverLimit: Bool {
        snapshot.isBadHabit && snapshot.today.isOverLimit
    }

    private var statusText: String {
        if let inlineErrorMessage { return inlineErrorMessage }
        if isOverLimit {
            return String(localized: "已超当日限额")
        }
        if snapshot.isBadHabit {
            if snapshot.today.isRecorded {
                return String(localized: "已记录发生")
            }
            return String(localized: "未记录")
        }
        if snapshot.today.isTargetMet {
            return String(localized: "已达标")
        }
        if snapshot.today.isRecorded {
            return String(localized: "已记录")
        }
        return String(localized: "未记录")
    }

    /// 副标题（方案 §4.3）：打卡行=连续+状态；数值行=今日/周期进展+状态
    private var subtitleText: String {
        var parts: [String] = []
        switch snapshot.kind {
        case .checkIn:
            if let streak = snapshot.streak, streak.value > 0 {
                parts.append(streak.displayText)
            }
        case .count, .measure:
            if let period = snapshot.today.periodValueText {
                parts.append(period)
            }
        }
        // 数值行的进展文本已表达「今天有记录」，重复念状态只会挤占一行（验收反馈 3）
        let redundant = snapshot.kind != .checkIn && snapshot.today.isRecorded && !snapshot.today.isTargetMet
        if !redundant {
            parts.append(statusText)
        }
        return parts.joined(separator: " · ")
    }

    /// 副行颜色：行内错误与超限共用红（旧磁贴版超限红字语义）
    private var subtitleColor: Color {
        if inlineErrorMessage != nil || isOverLimit {
            return .holoError
        }
        return .holoToolTextSecondary
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                // 今日记录入口：图标 + 名字 + 摘要（命中区域独立，不与动作重叠）
                Button {
                    onOpenTodayRecords()
                } label: {
                    HStack(alignment: .center, spacing: HoloSpacing.md) {
                        habitIcon
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.name)
                                .font(.holoBody.weight(.medium))
                                .foregroundColor(.holoToolText)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                            Text(subtitleText)
                                .font(.system(size: 12))
                                .foregroundColor(subtitleColor)
                                .lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "查看\(snapshot.name)今天的记录")))
                .accessibilityIdentifier("habit.rowbody.\(snapshot.id)")

                Spacer(minLength: HoloSpacing.sm)

                actionArea
            }
            .padding(.vertical, 10)

            // 三十天缝线：只读积累摘要（不承担导航，V2 §5.1）
            trailStitches
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .padding(.bottom, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(trailAccessibilityText))
        }
        .padding(.horizontal, HoloSpacing.sm)
        .frame(minHeight: 72)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.6))
                .frame(height: 0.5)
        }
    }

    /// VoiceOver 摘要：只报告积累事实，不宣称可点日（V2 §5.1）
    private var trailAccessibilityText: String {
        let recorded = snapshot.trail.filter { $0.isRecorded }.count
        return String(localized: "最近30天有\(recorded)天记录，痕迹仅作摘要")
    }

    // MARK: 图标

    private var habitIcon: some View {
        Group {
            if snapshot.isCustomIcon {
                snapshot.iconImage(size: 18)
                    .foregroundColor(Color(hex: snapshot.colorHex))
            } else {
                snapshot.iconImage(size: 17)
                    .foregroundColor(Color(hex: snapshot.colorHex))
            }
        }
        .frame(width: 34, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: snapshot.colorHex).opacity(0.12))
        )
    }

    // MARK: 动作区（右侧独立命中）

    @ViewBuilder
    private var actionArea: some View {
        switch snapshot.kind {
        case .checkIn:
            checkInButton
        case .count:
            countControls
        case .measure:
            measureButton
        }
    }

    private var checkInButton: some View {
        Button {
            onToggleCheckIn()
        } label: {
            Group {
                if snapshot.today.isRecorded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(hex: snapshot.colorHex)))
                } else {
                    Text(snapshot.isBadHabit ? String(localized: "记录发生") : String(localized: "打卡"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: snapshot.colorHex))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(
                            Capsule().fill(Color(hex: snapshot.colorHex).opacity(0.12))
                        )
                }
            }
        }
        .buttonStyle(HoloPressStyle())
        .disabled(isSaving)
        .accessibilityIdentifier("habit.row.\(snapshot.id).record")
        .accessibilityLabel(Text(snapshot.today.isRecorded
            ? String(localized: snapshot.isBadHabit ? "取消发生记录" : "取消打卡")
            : String(localized: snapshot.isBadHabit ? "记录发生" : "打卡")))
    }

    private var countControls: some View {
        HStack(spacing: 10) {
            if snapshot.today.isRecorded {
                // −：撤销最近一条今日记录（有记录才出现，避免「− - +」三个横线并排）
                Button {
                    onDecrement()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoToolText)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoloPressStyle())
                .disabled(isSaving)
                .accessibilityIdentifier("habit.row.\(snapshot.id).decrement")
                .accessibilityLabel(Text(String(localized: "撤销最近一次记录")))

                Text(todayValueText)
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundColor(isOverLimit ? Color.holoError : .holoToolText)
                    .frame(minWidth: 26)
                    .accessibilityLabel(Text(todayAccessibilityText))
            }

            // ＋：固定新增 1（方案 §8.2/§11.4）；无记录时它是行内唯一动作
            Button {
                onIncrement()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 44)
                    .background(Circle().fill(isOverLimit ? Color.holoError : Color(hex: snapshot.colorHex)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .disabled(isSaving)
            .accessibilityIdentifier("habit.row.\(snapshot.id).increment")
            .accessibilityLabel(Text(String(localized: "增加一次")))
        }
    }

    private var measureButton: some View {
        Button {
            onMeasureRecord()
        } label: {
            Group {
                if snapshot.today.isRecorded {
                    VStack(spacing: 1) {
                        Text(todayValueText)
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            .foregroundColor(isOverLimit ? Color.holoError : .holoToolText)
                        Text(String(localized: "再记录"))
                            .font(.system(size: 11))
                            .foregroundColor(isOverLimit ? Color.holoError : Color(hex: snapshot.colorHex))
                    }
                    .frame(minWidth: 56, minHeight: 44)
                } else {
                    Text(String(localized: "记录"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isOverLimit ? Color.holoError : Color(hex: snapshot.colorHex))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Capsule().fill(
                            isOverLimit
                                ? Color.holoError.opacity(0.12)
                                : Color(hex: snapshot.colorHex).opacity(0.12)
                        ))
                }
            }
        }
        .buttonStyle(HoloPressStyle())
        .disabled(isSaving)
        .accessibilityIdentifier("habit.row.\(snapshot.id).record")
        .accessibilityLabel(Text(snapshot.today.isRecorded
            ? String(localized: "再记录一次")
            : String(localized: "记录数值")))
    }

    // MARK: 数值文本

    private var unitText: String { snapshot.target?.unit ?? "" }

    private var todayValueText: String {
        guard let value = snapshot.today.todayValue else { return "-" }
        return HabitPresentationProjector.formatValue(value)
    }

    private var todayAccessibilityText: String {
        if snapshot.kind == .count {
            return String(localized: "今天 \(todayValueText) \(unitText)，增加一次或撤销最近一次")
        }
        return String(localized: "今天 \(todayValueText) \(unitText)")
    }

    // MARK: 三十天缝线（B 方案「缝线日课」，2026-10-07 东林定稿）

    /// 实针=已记录 ｜ 空心针=补录 ｜ 针眼=漏做 ｜ 细搭线=暂停日（不算断）｜ 空圈=今天指针；
    /// 创建前空位不渲染（那时还没有这个习惯，不是漏做）。
    private var trailStitches: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.trail) { day in
                stitch(for: day)
                    .frame(maxWidth: .infinity)
            }
        }
        // 打卡缝一针 / 撤销拆针：痕迹值变化时对状态切换播过渡
        .animation(HoloAnimation.snappy, value: snapshot.trail)
    }

    @ViewBuilder
    private func stitch(for day: HabitTrailDay) -> some View {
        let color = Color(hex: snapshot.colorHex)
        ZStack {
            if day.isBeforeCreation {
                // 创建前：空位，不渲染
            } else if day.isRecorded {
                if day.isRetroactive {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(color.opacity(0.9), lineWidth: 1.2)
                        .frame(width: 7, height: 4)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Capsule()
                        .fill(color.opacity(0.9))
                        .frame(width: 6, height: 3)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            } else if day.isPaused {
                Capsule()
                    .fill(Color.holoToolBorder.opacity(0.8))
                    .frame(width: 6, height: 1)
            } else {
                Circle()
                    .fill(Color.holoToolBorder.opacity(0.7))
                    .frame(width: 2.5, height: 2.5)
            }

            // 今天空圈：位置指针，独立于四态，恒显
            if day.isToday {
                Circle()
                    .strokeBorder(color.opacity(0.65), lineWidth: 1)
                    .frame(width: 4, height: 4)
                    .offset(y: -7)
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}
