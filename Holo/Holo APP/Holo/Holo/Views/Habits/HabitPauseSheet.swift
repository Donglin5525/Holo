//
//  HabitPauseSheet.swift
//  Holo
//
//  暂停习惯弹层（Holo Plus 功能）
//  暂停期间：退出今日清单/看板/通知/小组件，连续进度冻结保留，恢复后接着算
//

import SwiftUI

struct HabitPauseSheet: View {
    let habit: Habit
    var onPaused: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    /// 是否设定自动恢复日；false = 无限期暂停，随时手动恢复
    @State private var hasEndDate = false
    @State private var endDate: Date = Calendar.current.date(
        byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date())
    ) ?? Date()

    /// 可选的最早恢复日（明天；今天暂停今天恢复没有意义）
    private var minEndDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            ?? Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        VStack(spacing: HoloSpacing.lg) {
            Capsule()
                .fill(Color.holoBorder)
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            VStack(spacing: HoloSpacing.xs) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(habit.habitColor)

                Text(String(localized: "暂停「\(habit.name)」"))
                    .font(.holoTitle3)
                    .foregroundColor(.holoTextPrimary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "暂停期间，它不会出现在今天清单、看板和提醒里。连续进度会原样保留，恢复后接着算。"))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, HoloSpacing.md)

            VStack(spacing: HoloSpacing.md) {
                Toggle(isOn: $hasEndDate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("到指定日期自动恢复")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("适合出差、旅行等有明确结束的场景")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .tint(habit.habitColor)

                if hasEndDate {
                    DatePicker(
                        String(localized: "恢复日期"),
                        selection: $endDate,
                        in: minEndDate...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .font(.holoBody)
                    .tint(habit.habitColor)

                    Text(String(localized: "当天打开 App 即自动回到今天清单；忘了打开也不算断"))
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(Color.holoCardBackground)
            )

            Button {
                pauseNow()
            } label: {
                Text(String(localized: "暂停"))
                    .font(.holoHeading)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        Capsule().fill(habit.habitColor)
                    )
            }

            Button {
                dismiss()
            } label: {
                Text(String(localized: "取消"))
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .holoSheetShell()
        .presentationDetents([.medium])
    }

    // MARK: - 动作

    private func pauseNow() {
        do {
            try HabitRepository.shared.pauseHabit(habit, until: hasEndDate ? endDate : nil)
            HoloToastCenter.shared.show(
                String(localized: "已暂停「\(habit.name)」，随时可恢复"),
                type: .success
            )
            onPaused?()
            dismiss()
        } catch {
            HoloToastCenter.shared.show(
                error.localizedDescription,
                type: .error
            )
        }
    }
}
