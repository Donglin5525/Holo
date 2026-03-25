//
//  RepeatPicker.swift
//  Holo
//
//  重复规则选择器
//  支持每天、每周、每月、每年、自定义重复
//

import SwiftUI
import Foundation

/// 重复规则选择器
struct RepeatPicker: View {

    // MARK: - Properties

    /// 是否启用重复
    @Binding var hasRepeat: Bool

    /// 重复类型
    @Binding var repeatType: RepeatType

    /// 自定义：选中的星期
    @Binding var selectedWeekdays: Set<Weekday>

    /// 每月：固定日期（1-31）
    @Binding var monthDay: Int

    /// 每月：第几个（1-5）
    @Binding var monthWeekOrdinal: Int

    /// 每月：哪个星期
    @Binding var monthWeekday: Weekday?

    /// 每月重复模式
    @Binding var monthlyRepeatMode: MonthlyRepeatMode

    /// 结束条件类型
    @Binding var endConditionType: EndConditionType

    /// 结束日期（仅当 endConditionType == .onDate 时使用）
    @Binding var endDate: Date?

    /// 结束次数（仅当 endConditionType == .afterCount 时使用）
    @Binding var endCount: Int

    /// 是否启用（例如需要先设置截止日期）
    var isEnabled: Bool = true

    /// 是否显示结束日期选择器
    @State private var showEndDatePicker = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题行
            headerRow

            if isEnabled && hasRepeat {
                // 重复类型选择
                repeatTypeSelector
                    .padding(.top, HoloSpacing.xs)

                // 自定义选项（仅当选择 custom 时显示）
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
        .background(isEnabled ? Color.holoCardBackground : Color.holoCardBackground.opacity(0.5))
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "repeat")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isEnabled ? .holoTextSecondary : .holoTextSecondary.opacity(0.5))

            Text("重复")
                .font(.holoBody)
                .foregroundColor(isEnabled ? .holoTextPrimary : .holoTextPlaceholder)

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

            if isEnabled {
                Toggle("", isOn: $hasRepeat)
                    .labelsHidden()
                    .tint(.holoPrimary)
            } else {
                Text("需设置截止时间")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            }
        }
    }

    // MARK: - Repeat Type Selector

    private var repeatTypeSelector: some View {
        FlowLayout(spacing: HoloSpacing.xs) {
            ForEach([RepeatType.daily, .weekly, .monthly, .yearly, .custom], id: \.self) { type in
                RepeatTypeChip(
                    type: type,
                    isSelected: repeatType == type,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            repeatType = type
                            // 切换到自定义时，默认选择工作日
                            if type == .custom && selectedWeekdays.isEmpty {
                                selectedWeekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: - Custom Options

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

    /// 周几的显示顺序（周一到周日）
    private var weekdayOrder: [Weekday] {
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    }

    /// 是否选中了工作日
    private var isWorkdaysSelected: Bool {
        let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        return selectedWeekdays == workdays
    }

    // MARK: - Monthly Options

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

            // 第N个周X选择
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

    /// 第N个的文字描述
    private func ordinalText(_ ordinal: Int) -> String {
        let names = ["", "一", "二", "三", "四", "五"]
        return ordinal < names.count ? names[ordinal] : "\(ordinal)"
    }

    // MARK: - End Condition

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
                            if type == .onDate && endDate == nil {
                                endDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
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

            // 指定日期 - 使用紧凑的行内显示
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
        }
    }

    /// 格式化的结束日期显示
    private var formattedEndDate: String {
        guard let date = endDate else {
            return "未选择"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 结束日期选择器 Sheet
    private var endDatePickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: HoloSpacing.lg) {
                    HStack {
                        Text("选择结束日期")
                            .font(.holoHeading)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Button("取消") {
                            showEndDatePicker = false
                        }
                        .foregroundColor(.holoTextSecondary)
                    }

                    DatePicker(
                        "",
                        selection: Binding(
                            get: { endDate ?? Date() },
                            set: { endDate = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .padding()

                }
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
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        RepeatPicker(
            hasRepeat: .constant(true),
            repeatType: .constant(.custom),
            selectedWeekdays: .constant([.monday, .wednesday, .friday]),
            monthDay: .constant(15),
            monthWeekOrdinal: .constant(2),
            monthWeekday: .constant(.thursday),
            monthlyRepeatMode: .constant(.dayOfMonth),
            endConditionType: .constant(.never),
            endDate: .constant(nil),
            endCount: .constant(10),
            isEnabled: true
        )

        RepeatPicker(
            hasRepeat: .constant(false),
            repeatType: .constant(.daily),
            selectedWeekdays: .constant([]),
            monthDay: .constant(1),
            monthWeekOrdinal: .constant(1),
            monthWeekday: .constant(nil),
            monthlyRepeatMode: .constant(.dayOfMonth),
            endConditionType: .constant(.never),
            endDate: .constant(nil),
            endCount: .constant(10),
            isEnabled: false
        )
    }
    .padding()
    .background(Color.holoBackground)
}
