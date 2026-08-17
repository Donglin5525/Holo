//
//  HabitRetroactiveSheet.swift
//  Holo
//
//  习惯补签（找回断签）弹层
//  两态：日期选择（最近 7 天，仅漏卡日可选）→ 确认卡（🔥 恢复预览 + 额度提示）
//  规则：Plus 无限补签；免费每自然月 3 次，用尽时走付费墙，购买成功后自动完成本次补签
//

import SwiftUI

// MARK: - 弹层上下文

/// 补签弹层入参
/// - preselectedDay 非 nil（磁贴点阵/记录行入口）：跳过日期选择，直接进确认卡
/// - preselectedDay 为 nil（详情页横幅/长按菜单入口）：先进日期选择
struct HabitRetroactiveSheetContext: Identifiable {
    let habit: Habit
    let preselectedDay: Date?

    var id: UUID { habit.id }
}

// MARK: - 补签弹层

struct HabitRetroactiveSheet: View {

    let context: HabitRetroactiveSheetContext
    /// 完成后的轻提示由弹层内统一发出（全局 Toast，不受层级影响）
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// 窗口内可补的日子（升序）
    @State private var eligibleDays: [Date] = []
    /// 当前选中的目标日（nil = 日期选择态）
    @State private var selectedDay: Date?
    /// 打卡型连续天数恢复预览
    @State private var streakPreview: (before: Int, after: Int) = (0, 0)
    /// 测量类补签值
    @State private var inputValue: String = ""
    @State private var isSubmitting: Bool = false
    @FocusState private var isValueInputFocused: Bool

    @ObservedObject private var entitlement = HoloEntitlementState.shared

    private var habit: Habit { context.habit }

    private var isPickerMode: Bool { selectedDay == nil }

    var body: some View {
        NavigationStack {
            Group {
                if isPickerMode {
                    pickerContent
                } else {
                    confirmContent
                }
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle("补签打卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !isPickerMode {
                        Button(confirmTitle) { performRetroactive() }
                            .font(.holoBody)
                            .foregroundColor(habit.habitColor)
                            .disabled(isSubmitting || !canSubmit)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            eligibleDays = HabitRepository.shared.retroactiveEligibleDays(for: habit)
            if let day = context.preselectedDay, eligibleDays.contains(Calendar.current.startOfDay(for: day)) {
                selectDay(day)
            }
        }
    }

    // MARK: - 日期选择态

    private var pickerContent: some View {
        VStack(spacing: HoloSpacing.lg) {
            habitHeader(subtitle: "选择要补的日期 · 仅最近 \(HabitRetroactivePolicy.lookbackDays) 天内")

            if eligibleDays.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 30))
                        .foregroundColor(.holoSuccess)
                    Text("最近 \(HabitRetroactivePolicy.lookbackDays) 天没有漏卡，无需补签")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    // 倒序展示：离今天越近越靠前
                    ForEach(Array(eligibleDays.reversed()), id: \.self) { day in
                        dayRow(day)
                    }
                }
            }

            Spacer(minLength: 0)

            Text("今天请直接打卡 · 超过 \(HabitRetroactivePolicy.lookbackDays) 天的日期无法补签")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func dayRow(_ day: Date) -> some View {
        let isSelected = selectedDay == day
        return Button {
            selectDay(day)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 15))
                    .foregroundColor(habit.habitColor)

                Text(dayDisplayText(day))
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text("漏卡")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoError)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.holoError.opacity(0.1))
                    .clipShape(Capsule())

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(isSelected ? habit.habitColor.opacity(0.1) : Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .stroke(isSelected ? habit.habitColor.opacity(0.5) : Color.holoBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 确认卡态

    private var confirmContent: some View {
        VStack(spacing: HoloSpacing.lg) {
            if let day = selectedDay {
                habitHeader(subtitle: "\(dayDisplayText(day, withYear: true)) · 补上后连续记录自动接回")

                if habit.isCheckInType {
                    streakEffectCard
                } else if habit.isCountType {
                    Text("将为该日补 1 次记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    retroactiveValueInput
                }

                quotaLine

                Spacer(minLength: 0)

                Text("补签记录会带「补」标记，与当日实时打卡如实区分 · 免费次数每月 1 日重置")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 主按钮（导航栏之外给一个大按钮，符合原型确认卡样式）
                Button {
                    performRetroactive()
                } label: {
                    Text(isSubmitting ? "补签中…" : confirmTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                                .fill(canSubmit ? habit.habitColor : habit.habitColor.opacity(0.35))
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || !canSubmit)
            }
        }
    }

    private func habitHeader(subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(habit.habitColor.opacity(0.12))
                    .frame(width: 46, height: 46)

                habit.iconImage(size: 22)
                    .foregroundColor(habit.habitColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(habit.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoCardBackground)
        )
    }

    /// 打卡型：🔥 当前 → 补签后
    private var streakEffectCard: some View {
        HStack(spacing: 0) {
            streakItem(value: streakPreview.before, label: "当前连续")
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, 18)
            streakItem(value: streakPreview.after, label: "补签后", highlight: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(habit.habitColor.opacity(0.08))
        )
    }

    private func streakItem(value: Int, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 16))
                .foregroundColor(highlight ? habit.habitColor : .holoTextSecondary)
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(highlight ? habit.habitColor : .holoTextPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 测量类：补签数值输入
    private var retroactiveValueInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入当日数值\(habit.unitText.isEmpty ? "" : "（单位：\(habit.unitText)）")")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)

            TextField("输入数值", text: $inputValue)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .keyboardType(.decimalPad)
                .focused($isValueInputFocused)
                .padding(12)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    /// 额度提示行：Plus 无限 / 免费剩余次数
    private var quotaLine: some View {
        HStack(spacing: 6) {
            if entitlement.isPlusActive {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.holoPrimary)
                Text("Holo Plus · 无限补签")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            } else {
                let remaining = HabitRetroactiveQuota.remaining()
                Text("本月免费补签")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                HStack(spacing: 4) {
                    ForEach(0..<HabitRetroactivePolicy.freeMonthlyQuota, id: \.self) { index in
                        Circle()
                            .fill(index < remaining ? Color.holoSuccess : Color.holoBorder)
                            .frame(width: 7, height: 7)
                    }
                }
                Text("剩余 \(remaining) 次")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(remaining > 0 ? .holoTextPrimary : .holoError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    private var confirmTitle: String {
        if let day = selectedDay {
            return "补签 \(shortDayText(day))"
        }
        return "确认补签"
    }

    /// 测量类必须输入有效数值；其他类型恒可提交
    private var canSubmit: Bool {
        if habit.isNumericType && !habit.isCountType {
            guard let value = Double(inputValue), value > 0 else { return false }
        }
        return true
    }

    private func selectDay(_ day: Date) {
        let dayStart = Calendar.current.startOfDay(for: day)
        selectedDay = dayStart
        if habit.isCheckInType {
            streakPreview = HabitRepository.shared.simulateStreakAfterRetroactiveCheckIn(for: habit, on: dayStart)
        }
    }

    private func performRetroactive() {
        guard let day = selectedDay, !isSubmitting else { return }
        isSubmitting = true

        let value = Double(inputValue)
        do {
            let result = try HabitRepository.shared.retroactiveCheckIn(
                for: habit,
                on: day,
                value: value,
                note: nil
            )
            switch result {
            case .success(let before, let after):
                let toast = habit.isCheckInType && after > before
                    ? "已补签 \(shortDayText(day)) · 连续恢复至 \(after) 天"
                    : "已补签 \(shortDayText(day))"
                HoloToastCenter.shared.show(toast, type: .success)
                onFinished?()
                dismiss()
            case .alreadyCompleted:
                HoloToastCenter.shared.show("该日已有打卡记录，无需补签", type: .info)
                onFinished?()
                dismiss()
            case .invalidDate:
                HoloToastCenter.shared.show("仅支持补最近 \(HabitRetroactivePolicy.lookbackDays) 天内的日期", type: .warning)
                onFinished?()
                dismiss()
            case .requiresPlus:
                isSubmitting = false
                // 走统一付费墙；购买成功后自动完成本次补签（resume 续接原操作）
                HoloPlusActionCoordinator.shared.requirePlus(context: .habitRetroactiveCheckIn) {
                    await MainActor.run {
                        self.performRetroactive()
                    }
                }
            }
        } catch {
            isSubmitting = false
            HoloToastCenter.shared.show("补签失败，请重试", type: .error)
        }
    }

    // MARK: - 日期格式化

    private func dayDisplayText(_ day: Date, withYear: Bool = false) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = withYear ? "yyyy年M月d日" : "M月d日"
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[calendar.component(.weekday, from: day) - 1]

        let today = calendar.startOfDay(for: Date())
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let agoText: String
        switch daysAgo {
        case 1: agoText = " · 昨天"
        case 2: agoText = " · 前天"
        case 3...: agoText = " · \(daysAgo) 天前"
        default: agoText = ""
        }
        return "\(formatter.string(from: day))（周\(weekday)）\(agoText)"
    }

    private func shortDayText(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: day)
    }
}
