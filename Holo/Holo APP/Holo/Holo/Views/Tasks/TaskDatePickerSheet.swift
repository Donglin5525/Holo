//
//  TaskDatePickerSheet.swift
//  Holo
//
//  任务日期选择弹窗
//  整合日期选择、全天/定时切换、提醒设置、重复设置
//

import SwiftUI

/// 任务日期选择弹窗
struct TaskDatePickerSheet: View {
    @Environment(\.dismiss) var dismiss

    // MARK: - Bindings

    @Binding var dueDate: Date
    @Binding var isAllDay: Bool
    @Binding var hasDueDate: Bool

    @Binding var selectedReminders: Set<TaskReminder>
    @Binding var hasRepeat: Bool
    @Binding var repeatType: RepeatType
    @Binding var selectedWeekdays: Set<Weekday>
    @Binding var monthDay: Int
    @Binding var monthWeekOrdinal: Int
    @Binding var monthWeekday: Weekday?
    @Binding var monthlyRepeatMode: MonthlyRepeatMode
    @Binding var endConditionType: EndConditionType
    @Binding var repeatEndDate: Date?
    @Binding var repeatEndCount: Int

    // MARK: - Local State

    @State private var showEndDatePicker = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        dueDateToggleSection

                        if hasDueDate {
                            quickDateSection
                            compactDateSection
                            timeSection
                        }
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

    // MARK: - Compact Date-Time Sections

    private var dueDateToggleSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("截止日期")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(hasDueDate ? formattedDueDateSummary : "未设置")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Toggle("", isOn: $hasDueDate)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private var quickDateSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("快速选择")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    quickDateButton(title: "今天", daysFromToday: 0)
                    quickDateButton(title: "明天", daysFromToday: 1)
                    quickDateButton(title: "本周末", targetDate: upcomingWeekendDate)
                    quickDateButton(title: "下周", daysFromToday: 7)
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
                selection: $dueDate,
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

                    DatePicker("", selection: $dueDate, displayedComponents: .hourAndMinute)
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
                .foregroundColor(isSameDay(dueDate, targetDate) ? .white : .holoPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSameDay(dueDate, targetDate) ? Color.holoPrimary : Color.holoPrimary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }

    private func selectDatePreservingTime(_ date: Date) {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: dueDate)
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: date)
        targetComponents.hour = timeComponents.hour
        targetComponents.minute = timeComponents.minute
        targetComponents.second = timeComponents.second
        dueDate = calendar.date(from: targetComponents) ?? date
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

    private var formattedDueDateSummary: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = isAllDay ? "M月d日 EEE" : "M月d日 EEE HH:mm"
        return formatter.string(from: dueDate)
    }

    // MARK: - Date Picker Section

    private var datePickerSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("选择日期")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }

            DatePicker(
                "",
                selection: $dueDate,
                displayedComponents: isAllDay ? .date : [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(minHeight: 320)
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - All Day Toggle Section

    private var allDayToggleSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            Text("时间类型")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAllDay = true
                    }
                } label: {
                    Text("全天")
                        .font(.holoCaption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isAllDay ? Color.holoPrimary : Color.clear)
                        .foregroundColor(isAllDay ? .white : .holoTextSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAllDay = false
                    }
                } label: {
                    Text("定时")
                        .font(.holoCaption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(!isAllDay ? Color.holoPrimary : Color.clear)
                        .foregroundColor(!isAllDay ? .white : .holoTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .fixedSize()
            .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - Reminder Section

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("提醒")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                if !selectedReminders.isEmpty {
                    Text("\(selectedReminders.count)")
                        .font(.holoCaption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }

                Spacer()
            }

            // 预设选项
            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(TaskReminder.presetOptions, id: \.offsetMinutes) { reminder in
                    ReminderChip(
                        reminder: reminder,
                        isSelected: selectedReminders.contains(reminder),
                        onTap: {
                            toggleReminder(reminder)
                        }
                    )
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private func toggleReminder(_ reminder: TaskReminder) {
        if selectedReminders.contains(reminder) {
            selectedReminders.remove(reminder)
        } else {
            selectedReminders.insert(reminder)
        }
    }

    // MARK: - Repeat Section

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题行
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "repeat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("重复")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                if hasRepeat {
                    Text(repeatType.displayTitle)
                        .font(.holoCaption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }

                Spacer()

                Toggle("", isOn: $hasRepeat)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }

            if hasRepeat {
                // 重复类型选择
                repeatTypeSelector
                    .padding(.top, HoloSpacing.xs)

                // 自定义选项
                if repeatType == .custom {
                    customOptionsView
                        .padding(.top, HoloSpacing.sm)
                }

                // 每月选项
                if repeatType == .monthly {
                    monthlyOptionsView
                        .padding(.top, HoloSpacing.sm)
                }

                // 结束条件
                endConditionView
                    .padding(.top, HoloSpacing.sm)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private var repeatTypeSelector: some View {
        FlowLayout(spacing: HoloSpacing.xs) {
            ForEach([RepeatType.daily, .weekly, .monthly, .yearly, .custom], id: \.self) { type in
                RepeatTypeChip(
                    type: type,
                    isSelected: repeatType == type,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            repeatType = type
                            if type == .custom && selectedWeekdays.isEmpty {
                                selectedWeekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
                            }
                        }
                    }
                )
            }
        }
    }

    private var customOptionsView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 工作日快捷按钮
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
                    if selectedWeekdays == workdays {
                        selectedWeekdays = []
                    } else {
                        selectedWeekdays = workdays
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isWorkdaysSelected ? "checkmark" : "briefcase")
                        .font(.system(size: 12, weight: .medium))
                    Text("工作日")
                        .font(.holoCaption)
                }
                .foregroundColor(isWorkdaysSelected ? .white : .holoPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isWorkdaysSelected ? Color.holoPrimary : Color.holoPrimary.opacity(0.15))
                )
            }
            .buttonStyle(.plain)

            // 周选择器
            HStack(spacing: HoloSpacing.xs) {
                ForEach(weekdayOrder, id: \.self) { weekday in
                    WeekdayChip(
                        weekday: weekday,
                        isSelected: selectedWeekdays.contains(weekday),
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if selectedWeekdays.contains(weekday) {
                                    selectedWeekdays.remove(weekday)
                                } else {
                                    selectedWeekdays.insert(weekday)
                                }
                            }
                        }
                    )
                }
            }
        }
    }

    private var weekdayOrder: [Weekday] {
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    }

    private var isWorkdaysSelected: Bool {
        let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        return selectedWeekdays == workdays
    }

    private var monthlyOptionsView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 模式选择
            HStack(spacing: HoloSpacing.sm) {
                ForEach([MonthlyRepeatMode.dayOfMonth, .nthWeekday], id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            monthlyRepeatMode = mode
                            if mode == .nthWeekday && monthWeekday == nil {
                                monthWeekday = .thursday
                            }
                        }
                    } label: {
                        Text(mode.displayTitle)
                            .font(.holoCaption)
                            .foregroundColor(monthlyRepeatMode == mode ? .white : .holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(monthlyRepeatMode == mode ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 固定日期选择
            if monthlyRepeatMode == .dayOfMonth {
                HStack(spacing: HoloSpacing.xs) {
                    Text("每月")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Picker("", selection: $monthDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.holoPrimary)

                    Text("日")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            // 第 N 个周 X 选择
            if monthlyRepeatMode == .nthWeekday {
                HStack(spacing: HoloSpacing.xs) {
                    Text("每月第")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Picker("", selection: $monthWeekOrdinal) {
                        ForEach(1...5, id: \.self) { ordinal in
                            Text(ordinalText(ordinal)).tag(ordinal)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.holoPrimary)

                    Picker("", selection: $monthWeekday) {
                        ForEach(weekdayOrder, id: \.self) { weekday in
                            Text(weekday.displayTitle).tag(weekday as Weekday?)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.holoPrimary)
                }
            }
        }
    }

    private func ordinalText(_ ordinal: Int) -> String {
        let names = ["", "一", "二", "三", "四", "五"]
        return ordinal < names.count ? names[ordinal] : "\(ordinal)"
    }

    private var endConditionView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("结束条件")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                ForEach([EndConditionType.never, .onDate, .afterCount], id: \.self) { type in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            endConditionType = type
                            if type == .onDate && repeatEndDate == nil {
                                repeatEndDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
                            }
                        }
                    } label: {
                        Text(type.displayTitle)
                            .font(.holoCaption)
                            .foregroundColor(endConditionType == type ? .white : .holoTextPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(endConditionType == type ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 指定日期
            if endConditionType == .onDate {
                HStack {
                    Text(formattedEndDate)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Button {
                        showEndDatePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 12, weight: .medium))
                            Text("选择")
                                .font(.holoCaption)
                        }
                        .foregroundColor(.holoPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .sheet(isPresented: $showEndDatePicker) {
                    endDatePickerSheet
                }
            }

            // 重复次数
            if endConditionType == .afterCount {
                HStack {
                    Text("重复")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Picker("", selection: $repeatEndCount) {
                        ForEach(1...100, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.holoPrimary)

                    Text("次后结束")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
    }

    private var formattedEndDate: String {
        guard let date = repeatEndDate else {
            return "未选择"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }

    private var endDatePickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                DatePicker(
                    "",
                    selection: Binding(
                        get: { repeatEndDate ?? Date() },
                        set: { repeatEndDate = $0 }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding()
            }
            .navigationTitle("选择结束日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showEndDatePicker = false
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        showEndDatePicker = false
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Preview

#Preview {
    TaskDatePickerSheet(
        dueDate: .constant(Date()),
        isAllDay: .constant(true),
        hasDueDate: .constant(true),
        selectedReminders: .constant([TaskReminder(offsetMinutes: 15)]),
        hasRepeat: .constant(false),
        repeatType: .constant(.daily),
        selectedWeekdays: .constant([]),
        monthDay: .constant(1),
        monthWeekOrdinal: .constant(1),
        monthWeekday: .constant(nil),
        monthlyRepeatMode: .constant(.dayOfMonth),
        endConditionType: .constant(.never),
        repeatEndDate: .constant(nil),
        repeatEndCount: .constant(10)
    )
}
