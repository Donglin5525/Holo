//
//  HabitReviewView.swift
//  Holo
//
//  回顾页（2026-10 重构，方案 §5）：先回答「最近留下了哪些记录」，
//  再看单习惯积累。七天总览 → 习惯选择/月份切换 → 单习惯月历 → 趋势/摘要
//  → 月度概览入口（旧统计页承载全部原有统计能力）。
//

import SwiftUI

struct HabitReviewView: View {

    @ObservedObject var model: HabitModuleViewModel
    let onOpenMonthlyOverview: () -> Void
    let onOpenDetail: (UUID) -> Void

    // MARK: 状态

    /// 回顾范围：进行中 + 可选包含已暂停（查看历史不要求恢复或付费，方案 §5.2）
    @State private var includePaused = false
    @State private var selectedHabitId: UUID?
    @State private var selectedMonth: Date = Date()
    @State private var monthCells: [HabitStatsDayCell] = []
    @State private var monthDailyData: [DailyHabitData] = []
    @State private var monthStreak: HabitStreak = .zero()
    @State private var monthRecordedDays = 0
    /// 点选的日历格（日记录弹层）
    @State private var selectedDay: Date?
    @State private var retroContext: HabitRetroactiveSheetContext?

    private var reviewHabits: [HabitRowSnapshot] {
        includePaused ? model.todayRows + model.pausedRows : model.todayRows
    }

    private var selectedRow: HabitRowSnapshot? {
        reviewHabits.first { $0.id == selectedHabitId }
            ?? reviewHabits.first
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.md) {
                sevenDayOverview
                habitPicker
                monthSwitcher
                monthCalendar
                if let row = selectedRow {
                    if row.kind == .checkIn {
                        checkInSummary(row)
                    } else {
                        HabitLineChartView(data: monthDailyData, unit: row.target?.unit ?? "")
                    }
                }
                overviewEntry
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 40)
        }
        .onAppear {
            if selectedHabitId == nil {
                selectedHabitId = selectedRow?.id
            }
            reloadMonth()
        }
        .onChange(of: selectedHabitId) { _, _ in reloadMonth() }
        .onChange(of: selectedMonth) { _, _ in reloadMonth() }
        .onChange(of: includePaused) { _, _ in
            if selectedHabitId != nil, !reviewHabits.contains(where: { $0.id == selectedHabitId }) {
                selectedHabitId = reviewHabits.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            reloadMonth()
        }
        .sheet(item: dayBinding) { item in
            HabitDayRecordsSheet(
                habitRow: selectedRow,
                day: item.date,
                model: model
            ) { day, mode in
                guard let row = selectedRow,
                      let habit = HabitRepository.shared.findHabit(by: row.id) else { return }
                retroContext = HabitRetroactiveSheetContext(
                    habit: habit, preselectedDay: day,
                    mode: mode == .sign ? .sign : .backfill
                )
            }
        }
        .sheet(item: $retroContext) { context in
            HabitRetroactiveSheet(context: context)
        }
    }

    private var dayBinding: Binding<DayItem?> {
        Binding(
            get: { selectedDay.map(DayItem.init) },
            set: { selectedDay = $0?.date }
        )
    }

    private struct DayItem: Identifiable {
        let date: Date
        var id: Date { date }
    }

    // MARK: 七天总览

    private var sevenDayOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "最近七天"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)

            let days = sortedRollingDays
            let maxCount = max(days.map { model.rollingSevenDayCounts[$0] ?? 0 }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days, id: \.self) { day in
                    let count = model.rollingSevenDayCounts[day] ?? 0
                    let isToday = Calendar.current.isDateInToday(day)
                    VStack(spacing: 5) {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(count > 0 ? .holoToolText : .holoToolTextSecondary.opacity(0.6))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(count > 0 ? Color.holoPrimary.opacity(isToday ? 1 : 0.55) : Color.holoToolInset)
                            .frame(height: CGFloat(8 + CGFloat(count) / CGFloat(maxCount) * 46))
                        Text(weekdayLabel(day))
                            .font(.system(size: 10))
                            .foregroundColor(isToday ? .holoPrimary : .holoToolTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)

            Text(weekSummaryText)
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.lg)
        .accessibilityElement(children: .combine)
    }

    private var sortedRollingDays: [Date] {
        model.rollingSevenDayCounts.keys.sorted()
    }

    private func weekdayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("E")
        return formatter.string(from: day)
    }

    /// 「本周记录了 X 项」= 本自然周有有效记录的不同习惯数（方案 §5.2 口径）
    private var weekSummaryText: String {
        let calendar = Calendar.current
        guard let week = calendar.dateInterval(of: .weekOfYear, for: model.projectionNow) else { return "" }
        let distinctHabits = Set(
            model.todayRows.filter { row in
                row.trail.contains { trail in
                    week.contains(trail.day) && trail.isRecorded
                }
            }.map(\.id)
        )
        return String(localized: "本周记录了 \(distinctHabits.count) 项 · 每天记录了几项见上图")
    }

    // MARK: 习惯选择

    private var habitPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(reviewHabits) { row in
                        let isSelected = row.id == selectedRow?.id
                        Button {
                            withAnimation(HoloAnimation.quick) { selectedHabitId = row.id }
                        } label: {
                            HStack(spacing: 5) {
                                row.iconImage(size: 11)
                                Text(row.name)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            }
                            .foregroundColor(isSelected ? .white : .holoToolText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(
                                Capsule().fill(isSelected ? Color(hex: row.colorHex) : Color.holoToolInset)
                            )
                        }
                        .buttonStyle(HoloPressStyle())
                    }
                }
                .padding(.vertical, 2)
            }

            if !model.pausedRows.isEmpty {
                Toggle(isOn: $includePaused) {
                    Text(String(localized: "包含已暂停"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .tint(.holoPrimary)
                .frame(maxWidth: 180)
            }
        }
    }

    // MARK: 月份切换

    private var canGoNextMonth: Bool {
        let calendar = Calendar.current
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: model.projectionNow))!
        let selected = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth))!
        return selected < current
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
        return formatter.string(from: selectedMonth)
    }

    private var monthSwitcher: some View {
        HStack {
            Button {
                moveMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
            Text(monthTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)
            Spacer()

            Button {
                moveMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(canGoNextMonth ? .holoToolText : .holoToolTextSecondary.opacity(0.35))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNextMonth)
        }
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.md)
    }

    private func moveMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: selectedMonth) else { return }
        let calendar = Calendar.current
        let currentStart = calendar.date(from: calendar.dateComponents([.year, .month], from: model.projectionNow))!
        let nextStart = calendar.date(from: calendar.dateComponents([.year, .month], from: next))!
        guard nextStart <= currentStart else { return }
        withAnimation(HoloAnimation.quick) { selectedMonth = next }
    }

    // MARK: 月历

    private var monthCalendar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = selectedRow,
               let habit = HabitRepository.shared.findHabit(by: row.id),
               let section = monthSection(for: habit) {
                Text(String(localized: "\(row.name)的月历"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                HabitMonthGridView(month: section, accentColor: Color(hex: row.colorHex))
                legend
            } else {
                Text(String(localized: "选择一个习惯查看月历"))
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.lg)
    }

    /// 月历点格：点任何一天查看当日记录（未来/创建前给明确说明，不给无响应按钮）
    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(Color.holoPrimary, text: String(localized: "有记录"))
            legendDot(Color.holoToolBorder.opacity(0.5), text: String(localized: "无记录"))
            legendDot(Color.holoToolTextSecondary.opacity(0.4), text: String(localized: "休"))
        }
        .font(.system(size: 11))
        .foregroundColor(.holoToolTextSecondary)
    }

    private func legendDot(_ color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    private func monthSection(for habit: Habit) -> HabitStatsMonthSection? {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth))!
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return nil }
        let cells = HabitRepository.shared.makeMonthCells(for: habit, monthStart: monthStart, monthEnd: monthEnd)
        guard !cells.isEmpty else { return nil }
        let allSymbols = calendar.shortWeekdaySymbols
        let weekdaySymbols = Array(allSymbols[1...]) + [allSymbols[0]]
        let rows = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
        return HabitStatsMonthSection(monthStart: monthStart, weekdaySymbols: weekdaySymbols, rows: rows)
    }

    // MARK: 打卡型摘要 / 数值趋势

    private func checkInSummary(_ row: HabitRowSnapshot) -> some View {
        HStack(spacing: 0) {
            summaryCell(value: "\(monthRecordedDays)",
                        label: String(localized: "本月记录天数"))
            divider
            summaryCell(value: monthStreak.displayText,
                        label: String(localized: "连续积累"))
            divider
            summaryCell(value: row.target?.count.map { "\($0) 次/\(row.frequency == .weekly ? String(localized: "周") : String(localized: "月"))" }
                        ?? row.frequency.displayName,
                        label: String(localized: "目标周期"))
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.lg)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(width: 0.5, height: 32)
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundColor(.holoToolText)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 月度概览入口

    private var overviewEntry: some View {
        Button {
            onOpenMonthlyOverview()
        } label: {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 14))
                    .foregroundColor(.holoToolTextSecondary)
                Text(String(localized: "月度概览与详细统计"))
                    .font(.holoBody)
                    .foregroundColor(.holoToolText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            }
            .padding(.horizontal, HoloSpacing.md)
            .frame(minHeight: 50)
            .background(Color.holoToolSurface)
            .cornerRadius(HoloRadius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 数据

    private func reloadMonth() {
        guard let row = selectedRow,
              let habit = HabitRepository.shared.findHabit(by: row.id) else {
            monthCells = []
            monthDailyData = []
            return
        }
        let repository = HabitRepository.shared
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth))!
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return }

        monthCells = repository.makeMonthCells(for: habit, monthStart: monthStart, monthEnd: monthEnd)
        monthRecordedDays = monthCells.filter { $0.hasRecord }.count
        monthStreak = repository.calculateStreakInfo(for: habit)
        if habit.isNumericType {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: monthEnd) ?? monthEnd
            monthDailyData = repository.getDailyAggregatedData(for: habit, dateRange: monthStart...nextDay)
        } else {
            monthDailyData = []
        }
    }
}

// MARK: - 单日记录弹层（方案 §5.4）

/// 顶部习惯+日期；中部当日状态；下部每条记录（值/时间/备注/补录标识）；
/// 今日走正常操作，过去日按补签/补记政策判定，不绕开额度。
struct HabitDayRecordsSheet: View {

    let habitRow: HabitRowSnapshot?
    let day: Date
    @ObservedObject var model: HabitModuleViewModel
    /// 请求补录（day, mode）
    var onRequestRetroactive: (Date, HabitRetroactiveMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dayRecords: [HabitRecord] = []

    var body: some View {
        NavigationStack {
            List {
                if let row = habitRow {
                    Section {
                        statusHeader(row)
                    }
                    Section(String(localized: "记录明细")) {
                        if dayRecords.isEmpty {
                            Text(emptyText(row))
                                .foregroundColor(.holoToolTextSecondary)
                        } else {
                            ForEach(dayRecords) { record in
                                recordRow(record, row: row)
                            }
                        }
                    }
                    if let action = retroactiveAction(row) {
                        Section {
                            Button {
                                dismiss()
                                onRequestRetroactive(day, action.mode)
                            } label: {
                                Label(action.title, systemImage: "clock.arrow.circlepath")
                                    .foregroundColor(.holoPrimary)
                            }
                        }
                    }
                } else {
                    Text(String(localized: "选择一个习惯查看当日记录"))
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { loadRecords() }
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        return formatter.string(from: day)
    }

    private func loadRecords() {
        guard let row = habitRow,
              let habit = HabitRepository.shared.findHabit(by: row.id) else { return }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        dayRecords = HabitRepository.shared.getRecords(from: dayStart, to: dayEnd)
            .filter { $0.habitId == row.id }
    }

    private func statusHeader(_ row: HabitRowSnapshot) -> some View {
        HStack(spacing: HoloSpacing.md) {
            row.iconImage(size: 16)
                .foregroundColor(Color(hex: row.colorHex))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.holoBody.weight(.medium))
                    .foregroundColor(.holoToolText)
                Text(dayStatusLine(row))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer()
            dayValueLabel(row)
        }
        .padding(.vertical, 4)
    }

    /// 当日数值（异步无关：直接按记录窗口算）
    private func dayValueLabel(_ row: HabitRowSnapshot) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayFacts = HabitRepository.shared.getRecords(from: dayStart, to: dayEnd)
            .filter { $0.habitId == row.id }
            .map { HabitRecordFact(id: $0.id, habitId: $0.habitId, date: $0.date,
                                   isCompleted: $0.isCompleted, value: $0.valueDouble,
                                   isRetroactive: $0.isRetroactive) }
        let value: Double?
        if row.kind != .checkIn, !dayFacts.isEmpty {
            value = HabitRepository.shared.findHabit(by: row.id).map { habit in
                HabitPresentationProjector.dailyAggregate(
                    habit: habit, facts: dayFacts,
                    data: HabitProjectionData(recordsByHabit: [:], completedDaysByHabit: [:],
                                              dailyNumericByHabit: [:], pauseWindowsByHabit: [:],
                                              now: Date(), calendar: calendar)
                )
            } ?? nil
        } else {
            value = nil
        }
        return Group {
            if let value {
                Text("\(HabitPresentationProjector.formatValue(value)) \(row.target?.unit ?? "")")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(.holoToolText)
            }
        }
    }

    /// 简版状态行（弹层头部）：记录状态 + 暂停/补录标记
    private func dayStatusLine(_ row: HabitRowSnapshot) -> String {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let todayStart = calendar.startOfDay(for: Date())
        var parts: [String] = []
        if dayStart > todayStart {
            parts.append(String(localized: "未来日期"))
        } else if let habit = HabitRepository.shared.findHabit(by: row.id),
                  dayStart < calendar.startOfDay(for: habit.createdAt) {
            parts.append(String(localized: "习惯创建前"))
        }
        let trail = row.trail.first { calendar.startOfDay(for: $0.day) == dayStart }
        if let trail {
            if trail.isRecorded {
                parts.append(row.kind == .checkIn ? String(localized: "已记录") : String(localized: "有记录"))
            } else if parts.isEmpty {
                parts.append(String(localized: "无记录"))
            }
            if trail.isRetroactive { parts.append(String(localized: "含补录")) }
        }
        return parts.joined(separator: " · ")
    }

    private func dayStatusText(_ snapshot: HabitDaySnapshot) -> String {
        var parts: [String] = []
        if snapshot.isFuture { parts.append(String(localized: "未来日期")) }
        else if snapshot.isBeforeCreation { parts.append(String(localized: "习惯创建前")) }
        if snapshot.isPausedDay { parts.append(String(localized: "暂停日（不算漏签）")) }
        if snapshot.hasRetroactive { parts.append(String(localized: "含补录")) }
        if parts.isEmpty {
            if snapshot.isRecorded {
                parts.append(String(localized: snapshot.isCheckInDone ? "已记录" : "有记录"))
            } else {
                parts.append(String(localized: "无记录"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func emptyText(_ row: HabitRowSnapshot) -> String {
        let dayStart = Calendar.current.startOfDay(for: day)
        if dayStart >= Calendar.current.startOfDay(for: Date()) && !Calendar.current.isDateInToday(day) {
            return String(localized: "未来日期还没有记录")
        }
        return String(localized: "这一天没有记录")
    }

    private func recordRow(_ record: HabitRecord, row: HabitRowSnapshot) -> some View {
        HStack(spacing: HoloSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                if row.kind == .checkIn {
                    Text(record.isCompleted ? String(localized: "已记录") : String(localized: "已取消"))
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                } else {
                    Text(record.formattedValue(unit: row.target?.unit))
                        .font(.holoBody.weight(.medium))
                        .foregroundColor(.holoToolText)
                }
                if let note = record.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.formattedTime)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                if record.isRetroactive {
                    Text(String(localized: "补录"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.holoPrimary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }

    /// 补录资格：有资格才给按钮，没有资格说明原因（方案 §5.4）
    private func retroactiveAction(_ row: HabitRowSnapshot) -> (title: String, mode: HabitRetroactiveMode)? {
        guard let habit = HabitRepository.shared.findHabit(by: row.id) else { return nil }
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([row.id]),
            now: Date()
        )
        guard let mode = HabitPresentationProjector.retroactiveMode(habit: habit, day: day, data: data) else {
            return nil
        }
        if Calendar.current.isDateInToday(day) {
            return nil // 今天走正常今日操作
        }
        return (mode == .sign ? String(localized: "补签这一天") : String(localized: "补记这一天的真实记录"), mode)
    }
}
