//
//  TaskDueDateTimeSheet.swift
//  Holo
//
//  AI 建任务确认卡的截止时间弹层：快捷日期 + 图形日历 + 全天开关 + 具体时间。
//  比任务详情的 TaskDatePickerSheet 轻（提醒与重复有各自的专属入口）。
//

import SwiftUI

struct TaskDueDateTimeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var isAllDay: Bool

    /// 完成回调：(截止时间, 是否全天)
    let onDone: (Date, Bool) -> Void

    init(initialDate: Date, initialAllDay: Bool, onDone: @escaping (Date, Bool) -> Void) {
        self._date = State(initialValue: initialDate)
        self._isAllDay = State(initialValue: initialAllDay)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        quickDateSection
                        compactDateSection
                        timeSection
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.lg)
                }
            }
            .navigationTitle("日期与时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onDone(date, isAllDay)
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var quickDateSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("快速选择")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    quickDateButton(title: String(localized: "今天"), daysFromToday: 0)
                    quickDateButton(title: String(localized: "明天"), daysFromToday: 1)
                    quickDateButton(title: String(localized: "本周末"), targetDate: upcomingWeekendDate)
                    quickDateButton(title: String(localized: "下周"), daysFromToday: 7)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private var compactDateSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 22)

                Text("选择日期")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()
            }

            DatePicker(
                "",
                selection: $date,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .labelsHidden()
            .frame(minHeight: 320)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private var timeSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 22)

                Text("全天")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Toggle("", isOn: $isAllDay)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }
            .frame(minHeight: 44)

            if !isAllDay {
                Divider()
                    .padding(.vertical, HoloSpacing.xs)

                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "timer")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 22)

                    Text("具体时间")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .labelsHidden()
                        .tint(.holoPrimary)
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - Helpers

    private func quickDateButton(title: String, daysFromToday: Int) -> some View {
        let targetDate = Calendar.current.date(byAdding: .day, value: daysFromToday, to: Date()) ?? Date()
        return quickDateButton(title: title, targetDate: targetDate)
    }

    private func quickDateButton(title: String, targetDate: Date) -> some View {
        Button {
            selectDatePreservingTime(targetDate)
        } label: {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(isSameDay(date, targetDate) ? .white : .holoPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSameDay(date, targetDate) ? Color.holoPrimary : Color.holoPrimary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }

    private func selectDatePreservingTime(_ date: Date) {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: self.date)
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: date)
        targetComponents.hour = timeComponents.hour
        targetComponents.minute = timeComponents.minute
        targetComponents.second = timeComponents.second
        self.date = calendar.date(from: targetComponents) ?? date
    }

    private func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    private var upcomingWeekendDate: Date {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilSaturday = (7 - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysUntilSaturday, to: today) ?? today
    }
}
