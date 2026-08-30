//
//  PlannedTimeRangeSheet.swift
//  Holo
//
//  任务计划时间段编辑弹窗（时间块）
//  与「截止日期」语义分离：这是打算做事的时段，不是死线
//

import SwiftUI

/// 计划时间段弹窗：日期 + 开始/结束时刻，约束在同一天内
struct PlannedTimeRangeSheet: View {
    @Environment(\.dismiss) var dismiss

    // MARK: - Bindings（直通详情页编辑态，与 TaskDatePickerSheet 同模式：关闭即生效，返回详情页才落库）

    @Binding var hasPlannedRange: Bool
    @Binding var plannedStart: Date
    @Binding var plannedEnd: Date

    /// 首次开启时落在哪一天（通常传截止日，无截止日则今天）
    var defaultDay: Date?

    private let calendar = Calendar.current

    /// 当天 23:59，结束时刻与自动修正的上界（保证不跨天）
    private var endOfDayBound: Date {
        calendar.startOfDay(for: plannedStart).addingTimeInterval(24 * 3600 - 60)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        rangeToggleSection

                        if hasPlannedRange {
                            rangeEditorSection
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.lg)
                }
            }
            .navigationTitle("计划时间段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        hasPlannedRange = initialHasRange
                        plannedStart = initialStart
                        plannedEnd = initialEnd
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        clampEndAfterStartChange()
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(360), .large])
        .presentationDragIndicator(.visible)
        .onAppear { applyDefaultsIfNeeded() }
    }

    // MARK: - Sections

    private var rangeToggleSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $hasPlannedRange) {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "clock")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("设置计划时间段")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("打算做这件事的时段，与截止日期互相独立")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(.holoPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var rangeEditorSection: some View {
        VStack(spacing: 0) {
            DatePicker(
                "日期",
                selection: dayBinding,
                displayedComponents: .date
            )
            .font(.holoBody)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 12)

            DatePicker(
                "开始",
                selection: $plannedStart,
                in: ...calendar.startOfDay(for: plannedStart).addingTimeInterval(24 * 3600 - 15 * 60),
                displayedComponents: .hourAndMinute
            )
            .font(.holoBody)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 12)

            DatePicker(
                "结束",
                selection: $plannedEnd,
                in: plannedStart...endOfDayBound,
                displayedComponents: .hourAndMinute
            )
            .font(.holoBody)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .onChange(of: plannedStart) { _, newStart in
            // 开始时刻越过结束时把结束推到开始后 15 分钟（上界 23:59，不跨天）
            if newStart >= plannedEnd {
                plannedEnd = min(newStart.addingTimeInterval(15 * 60), endOfDayBound)
            }
        }
    }

    /// 日期与时刻分离选择：改日期时把两个时刻原样搬到新的一天
    private var dayBinding: Binding<Date> {
        Binding(
            get: { plannedStart },
            set: { newDay in
                plannedStart = shiftToDay(plannedStart, day: newDay)
                plannedEnd = shiftToDay(plannedEnd, day: newDay)
            }
        )
    }

    // MARK: - Helpers

    /// 进弹窗快照：取消时还原（时间段的开关比截止日重，关错了不该静默生效）
    @State private var initialHasRange = false
    @State private var initialStart = Date()
    @State private var initialEnd = Date()

    private func applyDefaultsIfNeeded() {
        initialHasRange = hasPlannedRange
        initialStart = plannedStart
        initialEnd = plannedEnd

        guard !hasPlannedRange else { return }
        let day = defaultDay ?? Date()
        let dayStart = calendar.startOfDay(for: day)
        // 默认时刻：当前时间向上取整 15 分钟，结束 = 开始 + 1 小时
        var comps = calendar.dateComponents([.hour, .minute], from: Date())
        let remainder = comps.minute! % 15
        if remainder != 0 {
            comps.minute! += 15 - remainder
        }
        if let minute = comps.minute, minute >= 60, let hour = comps.hour {
            comps.minute = minute - 60
            comps.hour = hour + 1
        }
        var startComps = calendar.dateComponents([.year, .month, .day], from: dayStart)
        startComps.hour = min(comps.hour ?? 9, 22)
        startComps.minute = comps.minute ?? 0
        guard let start = calendar.date(from: startComps) else { return }
        plannedStart = start
        plannedEnd = min(start.addingTimeInterval(3600), endOfDayBound)
    }

    private func clampEndAfterStartChange() {
        if plannedEnd <= plannedStart {
            plannedEnd = min(plannedStart.addingTimeInterval(15 * 60), endOfDayBound)
        }
    }

    private func shiftToDay(_ date: Date, day: Date) -> Date {
        var dayComps = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute], from: date)
        dayComps.hour = time.hour
        dayComps.minute = time.minute
        return calendar.date(from: dayComps) ?? date
    }
}
