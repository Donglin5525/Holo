//
//  HabitRowView.swift
//  Holo
//
//  今天页连续习惯行（2026-10 重构，V2 调整职责）：
//  左侧名字/图标/摘要 =「今天的记录」入口；右侧动作按钮独立命中。
//  当月缝线只读（积累摘要，不承担导航，V2 §5.1；10-07 定稿月初累加视角）。
//

import SwiftUI

extension HabitRowSnapshot: HabitIconRenderable {}

struct HabitRowView: View {

    let snapshot: HabitRowSnapshot
    /// 该行正在保存（按钮禁用，防重复提交的可见态）
    let isSaving: Bool
    /// 行内错误消息（覆盖副标题位置短暂显示）
    let inlineErrorMessage: String?
    /// 今天页导演分发的灯点亮令牌（当天首次完成才有；nil = 静止）
    var ignitionToken: UUID? = nil
    var onOpenTodayRecords: () -> Void
    var onToggleCheckIn: () -> Void
    var onIncrement: () -> Void
    var onDecrement: () -> Void
    var onMeasureRecord: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HoloMotionRollout.completionKey) private var completionMotionEnabled = true

    /// 灯动效是否允许（完成动效开关 + 系统减弱动态效果）
    private var lampMotionAllowed: Bool {
        completionMotionEnabled && !reduceMotion
    }

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
        if let inlineErrorMessage { return inlineErrorMessage }
        if snapshot.folderID != nil, snapshot.kind == .checkIn,
           snapshot.frequency != .daily, let period = snapshot.today.periodValueText {
            return period
        }
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

    /// 副标题视图：打卡行连续值有效时带橙色火焰前缀（旧磁贴连续徽章的激励记号，V1 重构时丢失，2026-10-07 东林要求加回）
    @ViewBuilder
    private var subtitleView: some View {
        if showsStreakFlame {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .accessibilityHidden(true)
                Text(subtitleText)
            }
        } else {
            Text(subtitleText)
        }
    }

    /// 火焰显示条件：打卡行 + 连续值>0 + 无行内错误（错误态副标题整体被错误文案替换）
    private var showsStreakFlame: Bool {
        guard case .checkIn = snapshot.kind,
              inlineErrorMessage == nil,
              snapshot.folderID == nil || snapshot.frequency == .daily,
              let streak = snapshot.streak else { return false }
        return streak.value > 0
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
                            subtitleView
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

            if let description = snapshot.habitDescription {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 34 + HoloSpacing.md)
                    .padding(.top, -4)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }

            // 当月缝线：只读积累摘要（不承担导航，V2 §5.1）
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
        return String(localized: "本月有\(recorded)天记录，痕迹仅作摘要")
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
            if snapshot.prefersQuantityInput {
                HStack(spacing: 10) {
                    if snapshot.today.isRecorded { decrementButton }
                    measureButton
                }
            } else {
                countControls
            }
        case .measure:
            measureButton
        }
    }

    /// 打卡按钮：好习惯已记录 = 习惯灯（审美七项 P1「A 点亮」），
    /// 坏习惯保持实心圆 + 对勾（不点灯、不飞、不进「今日的灯」）
    private var checkInButton: some View {
        Button {
            onToggleCheckIn()
        } label: {
            Group {
                if snapshot.isBadHabit {
                    badHabitCheckInContent
                } else {
                    goodHabitCheckInContent
                }
            }
        }
        .buttonStyle(HoloPressStyle())
        .disabled(isSaving)
        // 光点起飞起点 = 按钮中心（habitToday 坐标系）
        .habitLampOrigin(id: snapshot.id)
        .accessibilityIdentifier("habit.row.\(snapshot.id).record")
        .accessibilityLabel(Text(snapshot.today.isRecorded
            ? String(localized: snapshot.isBadHabit ? "取消发生记录" : "取消打卡")
            : String(localized: snapshot.isBadHabit ? "记录发生" : "打卡")))
    }

    /// 坏习惯「记录发生」：样式维持现状（无过渡动画）
    private var badHabitCheckInContent: some View {
        Group {
            if snapshot.today.isRecorded {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(hex: snapshot.colorHex)))
            } else {
                Text(String(localized: "记录发生"))
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

    /// 好习惯「打卡」：未记录 = 习惯色浅底胶囊；已记录 = 灯。
    /// 亮灯 / 熄灯按 reducedFade 0.25s 淡变；首次点亮动画由灯自己播
    private var goodHabitCheckInContent: some View {
        Group {
            if snapshot.today.isRecorded {
                HabitLampView(
                    color: Color(hex: snapshot.colorHex),
                    ignitionToken: ignitionToken,
                    allowsMotion: lampMotionAllowed
                )
                .frame(width: 44, height: 44)
                .transition(.opacity)
            } else {
                checkInCapsule
                    .transition(.opacity)
            }
        }
        .animation(HoloAnimation.reducedFade, value: snapshot.today.isRecorded)
    }

    private var checkInCapsule: some View {
        Text(String(localized: "打卡"))
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Color(hex: snapshot.colorHex))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                Capsule().fill(Color(hex: snapshot.colorHex).opacity(0.12))
            )
    }

    private var countControls: some View {
        HStack(spacing: 10) {
            if snapshot.today.isRecorded {
                decrementButton

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
            // 数值行光点从主操作按钮（＋）起飞
            .habitLampOrigin(id: snapshot.id)
            .accessibilityIdentifier("habit.row.\(snapshot.id).increment")
            .accessibilityLabel(Text(String(localized: "增加一次")))
        }
    }

    /// 有记录才显示减号，共用原有计数行的点击区域和图标。
    private var decrementButton: some View {
        Button(action: onDecrement) {
            Image(systemName: "minus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoToolText)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .disabled(isSaving)
        .accessibilityIdentifier("habit.row.\(snapshot.id).decrement")
        .accessibilityLabel(Text(snapshot.prefersQuantityInput
            ? String(localized: "撤销上一笔")
            : String(localized: "撤销最近一次记录")))
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
                    Text(snapshot.kind == .count ? String(localized: "记数量") : String(localized: "记录"))
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
        // 测量/计数（quantity 输入态）行光点从「记录」按钮起飞
        .habitLampOrigin(id: snapshot.id)
        .accessibilityIdentifier("habit.row.\(snapshot.id).record")
        .accessibilityLabel(Text(snapshot.today.isRecorded
            ? String(localized: "再记录一次")
            : snapshot.kind == .count ? String(localized: "记数量") : String(localized: "记录数值")))
        .accessibilityValue(Text(snapshot.today.isRecorded ? "\(todayValueText) \(unitText)" : ""))
    }

    // MARK: 数值文本

    private var unitText: String { snapshot.unit }

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

    // MARK: 当月缝线（月初累加视角，2026-10-07 东林定稿）

    /// 实针=已记录 ｜ 空心针=补录 ｜ 针眼=漏做 ｜ 细搭线=暂停日（不算断）｜ 淡点=还没到的日子 ｜
    /// 空圈=今天游标（位置即日期，不另标数字）；创建前=最淡的小点占位（那时还没有这个习惯，
    /// 不是漏做——但完全不画会让月中新建的习惯整条痕迹缺一截，像没显示全，2026-11-17 东林实报）。
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
                // 创建前：最淡占位点（弱于未来日），保住整月痕迹的连续感
                Circle()
                    .fill(Color.holoToolTextSecondary.opacity(0.25))
                    .frame(width: 2, height: 2)
            } else if day.isFuture {
                // 还没走到的日子：小点弱于漏做针眼。用 ToolTextSecondary 而非 ToolBorder——
                // 后者浅色是 0.91 暖灰，米色底上不可见（11-05 挑刺专项F 浅色补弱）
                Circle()
                    .fill(Color.holoToolTextSecondary.opacity(0.35))
                    .frame(width: 2, height: 2)
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
                    .fill(Color.holoToolTextSecondary.opacity(0.8))
                    .frame(width: 6, height: 1)
            } else {
                Circle()
                    .fill(Color.holoToolTextSecondary.opacity(0.75))
                    .frame(width: 2.5, height: 2.5)
            }

            // 今天游标：空圈位置指针，独立于五态，恒显
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
