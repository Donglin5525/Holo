//
//  TaskDatePickerSheet.swift
//  Holo
//
//  任务「日期与时间」弹窗（任务详情与新建任务共用）
//  2026-10-14 重设计（契约见 task-datetime-redesign-prototype.html，东林拍板 1:1 落实）：
//  - 草稿确认制：打开弹窗拷一份草稿，一切改动先落草稿；「确定」整体写回，
//    「取消」/下滑关闭整体丢弃——取消是真回滚，不再是只关窗。
//  - 紧凑滚轮日历替代 320pt 大月历：全天 = 单列日期；关「全天」= 日期+时+分三列，
//    同一张卡不换区；关全天的瞬间把 00:00 垫成「下一个整 15 分钟」（跨午夜落 23:59）。
//  - 提醒区交互（行级确认制 / 按时刻去重）由 TaskReminderEditor 承担，绑草稿。
//  - 重复区保持原有交互，同样绑草稿。
//

import SwiftUI

/// 任务日期选择弹窗
struct TaskDatePickerSheet: View {
    @Environment(\.dismiss) var dismiss

    // MARK: - Bindings（只在「确定」时写回；init 时拷入草稿）

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

    // MARK: - 草稿 State（弹窗内的一切改动只落这里）

    @State private var draftDueDate: Date
    @State private var draftIsAllDay: Bool
    @State private var draftHasDueDate: Bool
    @State private var draftReminders: Set<TaskReminder>
    @State private var draftHasRepeat: Bool
    @State private var draftRepeatType: RepeatType
    @State private var draftSelectedWeekdays: Set<Weekday>
    @State private var draftMonthDay: Int
    @State private var draftMonthWeekOrdinal: Int
    @State private var draftMonthWeekday: Weekday?
    @State private var draftMonthlyRepeatMode: MonthlyRepeatMode
    @State private var draftEndConditionType: EndConditionType
    @State private var draftRepeatEndDate: Date?
    @State private var draftRepeatEndCount: Int

    @State private var showEndDatePicker = false

    init(
        dueDate: Binding<Date>,
        isAllDay: Binding<Bool>,
        hasDueDate: Binding<Bool>,
        selectedReminders: Binding<Set<TaskReminder>>,
        hasRepeat: Binding<Bool>,
        repeatType: Binding<RepeatType>,
        selectedWeekdays: Binding<Set<Weekday>>,
        monthDay: Binding<Int>,
        monthWeekOrdinal: Binding<Int>,
        monthWeekday: Binding<Weekday?>,
        monthlyRepeatMode: Binding<MonthlyRepeatMode>,
        endConditionType: Binding<EndConditionType>,
        repeatEndDate: Binding<Date?>,
        repeatEndCount: Binding<Int>
    ) {
        self._dueDate = dueDate
        self._isAllDay = isAllDay
        self._hasDueDate = hasDueDate
        self._selectedReminders = selectedReminders
        self._hasRepeat = hasRepeat
        self._repeatType = repeatType
        self._selectedWeekdays = selectedWeekdays
        self._monthDay = monthDay
        self._monthWeekOrdinal = monthWeekOrdinal
        self._monthWeekday = monthWeekday
        self._monthlyRepeatMode = monthlyRepeatMode
        self._endConditionType = endConditionType
        self._repeatEndDate = repeatEndDate
        self._repeatEndCount = repeatEndCount

        self._draftDueDate = State(initialValue: dueDate.wrappedValue)
        self._draftIsAllDay = State(initialValue: isAllDay.wrappedValue)
        self._draftHasDueDate = State(initialValue: hasDueDate.wrappedValue)
        self._draftReminders = State(initialValue: selectedReminders.wrappedValue)
        self._draftHasRepeat = State(initialValue: hasRepeat.wrappedValue)
        self._draftRepeatType = State(initialValue: repeatType.wrappedValue)
        self._draftSelectedWeekdays = State(initialValue: selectedWeekdays.wrappedValue)
        self._draftMonthDay = State(initialValue: monthDay.wrappedValue)
        self._draftMonthWeekOrdinal = State(initialValue: monthWeekOrdinal.wrappedValue)
        self._draftMonthWeekday = State(initialValue: monthWeekday.wrappedValue)
        self._draftMonthlyRepeatMode = State(initialValue: monthlyRepeatMode.wrappedValue)
        self._draftEndConditionType = State(initialValue: endConditionType.wrappedValue)
        self._draftRepeatEndDate = State(initialValue: repeatEndDate.wrappedValue)
        self._draftRepeatEndCount = State(initialValue: repeatEndCount.wrappedValue)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        dateSection

                        if draftHasDueDate {
                            allDaySection
                        }

                        // 提醒：有截止日时用相对预设，无截止日时选绝对提醒时刻
                        reminderSection

                        // 重复：需要截止日
                        if draftHasDueDate {
                            repeatSection
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
                        commitAndDismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(720), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: draftHasDueDate) { _, isOn in
            // 关闭截止日时，清理无效的相对提醒（只保留绝对提醒）
            if !isOn {
                draftReminders = draftReminders.filter { $0.isAbsolute }
                draftHasRepeat = false
            }
        }
        .onChange(of: draftIsAllDay) { _, allDay in
            // 关「全天」的瞬间垫时刻：00:00 已是过去时，任务会立即显示「已过期」。
            // 非 00:00 的时刻说明用户或流程已显式选过时间，保持不动。
            if !allDay, draftDueDate == Calendar.current.startOfDay(for: draftDueDate) {
                draftDueDate = TaskDetailTimeDefault.timedDate(from: draftDueDate)
            }
        }
    }

    /// 「确定」：草稿一次性写回宿主（「取消」/下滑关闭不经过这里 = 零影响）
    private func commitAndDismiss() {
        dueDate = draftDueDate
        isAllDay = draftIsAllDay
        hasDueDate = draftHasDueDate
        selectedReminders = draftReminders
        hasRepeat = draftHasRepeat
        repeatType = draftRepeatType
        selectedWeekdays = draftSelectedWeekdays
        monthDay = draftMonthDay
        monthWeekOrdinal = draftMonthWeekOrdinal
        monthWeekday = draftMonthWeekday
        monthlyRepeatMode = draftMonthlyRepeatMode
        endConditionType = draftEndConditionType
        repeatEndDate = draftRepeatEndDate
        repeatEndCount = draftRepeatEndCount
        dismiss()
    }

    // MARK: - 日期卡（截止开关 + 快速选择 + 紧凑滚轮日历）

    private var dateSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 22)

                Text("日期")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Toggle("", isOn: $draftHasDueDate)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }
            .frame(minHeight: 44)

            if draftHasDueDate {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoloSpacing.sm) {
                        quickDateButton(title: String(localized: "今天"), daysFromToday: 0)
                        quickDateButton(title: String(localized: "明天"), daysFromToday: 1)
                        quickDateButton(title: String(localized: "本周末"), targetDate: upcomingWeekendDate)
                        quickDateButton(title: String(localized: "下周"), daysFromToday: 7)
                    }
                }

                // 紧凑滚轮日历：全天 = 单列日期；关「全天」= 日期+时+分三列，同一张卡
                DatePicker(
                    "",
                    selection: $draftDueDate,
                    displayedComponents: draftIsAllDay ? .date : [.date, .hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - 全天卡

    private var allDaySection: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 22)

            Text("全天")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Toggle("", isOn: $draftIsAllDay)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - 提醒卡

    /// 提醒区：共用 TaskReminderEditor（行级确认制 + 按时刻去重），绑草稿。
    /// 带时刻 → 相对预设 chips；全天 → 锚定任务日的绝对档位（当天 09:00 等，与确认卡一致）；
    /// 无截止日 → 绝对时刻自由添加。全天任务不给「提前15分钟」chips——全天没有截止时刻，
    /// 「提前15分钟」等于提醒在 00:00 前几分钟，语义不成立。
    private var reminderSection: some View {
        TaskReminderEditor(
            mode: (draftHasDueDate && !draftIsAllDay) ? .relative : .absolute,
            anchorDate: (draftHasDueDate && draftIsAllDay) ? draftDueDate : nil,
            reminders: $draftReminders
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - 重复卡（内部交互保持原样，绑草稿）

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

                if draftHasRepeat {
                    Text(draftRepeatType.displayTitle)
                        .font(.holoCaption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }

                Spacer()

                Toggle("", isOn: $draftHasRepeat)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }

            if draftHasRepeat {
                // 重复类型选择
                repeatTypeSelector
                    .padding(.top, HoloSpacing.xs)

                // 自定义选项
                if draftRepeatType == .custom {
                    customOptionsView
                        .padding(.top, HoloSpacing.sm)
                }

                // 每月选项
                if draftRepeatType == .monthly {
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
                    isSelected: draftRepeatType == type,
                    onTap: {
                        withAnimation(HoloAnimation.quick) {
                            draftRepeatType = type
                            if type == .custom && draftSelectedWeekdays.isEmpty {
                                draftSelectedWeekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
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
                withAnimation(HoloAnimation.quick) {
                    let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
                    if draftSelectedWeekdays == workdays {
                        draftSelectedWeekdays = []
                    } else {
                        draftSelectedWeekdays = workdays
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
                        isSelected: draftSelectedWeekdays.contains(weekday),
                        onTap: {
                            withAnimation(HoloAnimation.quick) {
                                if draftSelectedWeekdays.contains(weekday) {
                                    draftSelectedWeekdays.remove(weekday)
                                } else {
                                    draftSelectedWeekdays.insert(weekday)
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
        return draftSelectedWeekdays == workdays
    }

    private var monthlyOptionsView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 模式选择
            HStack(spacing: HoloSpacing.sm) {
                ForEach([MonthlyRepeatMode.dayOfMonth, .nthWeekday], id: \.self) { mode in
                    Button {
                        withAnimation(HoloAnimation.quick) {
                            draftMonthlyRepeatMode = mode
                            if mode == .nthWeekday && draftMonthWeekday == nil {
                                draftMonthWeekday = .thursday
                            }
                        }
                    } label: {
                        Text(mode.displayTitle)
                            .font(.holoCaption)
                            .foregroundColor(draftMonthlyRepeatMode == mode ? .white : .holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(draftMonthlyRepeatMode == mode ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 固定日期选择
            if draftMonthlyRepeatMode == .dayOfMonth {
                HStack(spacing: HoloSpacing.xs) {
                    Text("每月")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Picker("", selection: $draftMonthDay) {
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
            if draftMonthlyRepeatMode == .nthWeekday {
                HStack(spacing: HoloSpacing.xs) {
                    Text("每月第")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Picker("", selection: $draftMonthWeekOrdinal) {
                        ForEach(1...5, id: \.self) { ordinal in
                            Text(ordinalText(ordinal)).tag(ordinal)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.holoPrimary)

                    Picker("", selection: $draftMonthWeekday) {
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
        let names = ["", String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五")]
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
                        withAnimation(HoloAnimation.quick) {
                            draftEndConditionType = type
                            if type == .onDate && draftRepeatEndDate == nil {
                                draftRepeatEndDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
                            }
                        }
                    } label: {
                        Text(type.displayTitle)
                            .font(.holoCaption)
                            .foregroundColor(draftEndConditionType == type ? .white : .holoTextPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(draftEndConditionType == type ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 指定日期
            if draftEndConditionType == .onDate {
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
            if draftEndConditionType == .afterCount {
                HStack {
                    Text("重复")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Picker("", selection: $draftRepeatEndCount) {
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

    // MARK: - 快速日期与结束日期

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
                .foregroundColor(isSameDay(draftDueDate, targetDate) ? .white : .holoPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSameDay(draftDueDate, targetDate) ? Color.holoPrimary : Color.holoPrimary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }

    private func selectDatePreservingTime(_ date: Date) {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: draftDueDate)
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: date)
        targetComponents.hour = timeComponents.hour
        targetComponents.minute = timeComponents.minute
        targetComponents.second = timeComponents.second
        draftDueDate = calendar.date(from: targetComponents) ?? date
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

    private var formattedEndDate: String {
        guard let date = draftRepeatEndDate else {
            return String(localized: "未选择")
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    private var endDatePickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                DatePicker(
                    "",
                    selection: Binding(
                        get: { draftRepeatEndDate ?? Date() },
                        set: { draftRepeatEndDate = $0 }
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

// MARK: - 关「全天」时的默认时刻规则（新建与详情共用，随弹窗走）

/// 新建任务默认落「当天 00:00（全天）」；用户关掉全天的瞬间，00:00 已是过去时，
/// 任务会立即显示「已过期」。这里把整点日期值垫成有意义的时刻：
/// 当前时钟向上取整到下一个 15 分钟；若已越过午夜则落回当天 23:59。
/// 非 00:00 的时刻说明用户或流程已显式选过时间，保持不动。
enum TaskDetailTimeDefault {
    static func timedDate(
        from allDayDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        guard allDayDate == calendar.startOfDay(for: allDayDate) else { return allDayDate }

        var minute = calendar.component(.minute, from: now)
        var hour = calendar.component(.hour, from: now)
        let remainder = minute % 15
        if remainder == 0 && calendar.component(.second, from: now) == 0 {
            // 恰好整 15 分钟倍数：直接用当前时刻
        } else {
            minute += 15 - remainder
            if minute >= 60 {
                minute -= 60
                hour += 1
            }
        }
        if hour >= 24 {
            hour = 23
            minute = 59
        }

        var components = calendar.dateComponents([.year, .month, .day], from: allDayDate)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? allDayDate
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
