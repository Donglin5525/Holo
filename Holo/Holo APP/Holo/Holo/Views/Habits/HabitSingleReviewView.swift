//
//  HabitSingleReviewView.swift
//  Holo
//
//  单习惯回顾（V2 §7）：唯一的统计详情页。
//  习惯名/状态 → 一个范围控制 → 两项以内结果 → 一块主要可视化（打卡日历 /
//  数值趋势可切换日历，互斥）→ 被选日期明细（编辑/删除/合规补录）。
//  不出现「月度概览」「全部习惯统计」「详细统计」；返回整体用返回键。
//

import SwiftUI
import Charts
import CoreData

struct HabitSingleReviewView: View {

    let habitId: UUID
    @ObservedObject var model: HabitModuleViewModel
    /// 打开习惯设置（右上更多 → AddHabitSheet 编辑态）
    var onOpenSettings: (UUID) -> Void
    /// 「去今天记录」：回今天并定位该习惯
    var onGoTodayRecord: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: 页内状态（§A18：范围内唯一时间语义）

    @State private var selectedRange: HabitReviewRange = .month(Date())
    @State private var vizMode: VizMode = .calendar
    @State private var selectedDay: Date?
    @State private var calendarMonth: Date = Date()
    @State private var snapshot: HabitRangeSnapshot?
    @State private var rangeSheetShown = false
    @State private var editingRecord: RecordTarget?
    @State private var pendingDeleteRecord: HabitRecord?
    @State private var retroContext: HabitRetroactiveSheetContext?

    enum VizMode: Equatable {
        case calendar
        case trend
        case dates
    }

    private var habit: Habit? { HabitRepository.shared.findHabit(by: habitId) }

    private var lifecycle: HabitLifecycle {
        guard let habit else { return .active }
        if habit.isArchived { return .archived }
        return habit.isPaused ? .paused : .active
    }

    // MARK: Body

    var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else if let habit {
                unavailableState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.holoToolBackground)
        .onAppear {
            if snapshot == nil { initializeState() }
            rebuild()
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            rebuild()
        }
        .sheet(isPresented: $rangeSheetShown) { rangeSheet }
        .sheet(item: $editingRecord) { target in
            if let record = findRecord(target.recordId) {
                HabitRecordEditSheet(
                    record: record,
                    isCountType: snapshot?.info.kind == .count,
                    unit: snapshot?.info.unit
                ) { value, note in
                    Task {
                        await model.record(kind: .updateRecord(recordId: target.recordId,
                                                               value: value, note: note),
                                           habitId: habitId)
                    }
                }
            }
        }
        .sheet(item: $retroContext) { context in
            HabitRetroactiveSheet(context: context)
        }
        .confirmationDialog(
            String(localized: "删除这条记录？"),
            isPresented: Binding(get: { pendingDeleteRecord != nil },
                                 set: { if !$0 { pendingDeleteRecord = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除这条记录"), role: .destructive) {
                if let record = pendingDeleteRecord {
                    Task {
                        await model.record(kind: .deleteRecord(recordId: record.id), habitId: habitId)
                    }
                }
                pendingDeleteRecord = nil
            }
            Button(String(localized: "取消"), role: .cancel) { pendingDeleteRecord = nil }
        } message: {
            Text(String(localized: "只删除\(snapshot?.info.name ?? "")选定的这一条记录"))
        }
    }

    // MARK: 主内容

    private func content(_ snapshot: HabitRangeSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerHead(snapshot.info)
                rangeControl
                summarySection(snapshot)
                vizSection(snapshot)
                if let day = selectedDay {
                    dayDetailSection(snapshot, day: day)
                        .id(day)
                } else {
                    Text(String(localized: "选择一个日期，查看那一天的真实记录。"))
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 40)
        }
    }

    /// 习惯已删除：明确说明，不重建占位（V2 §9）
    private var unavailableState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "archivebox")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.holoToolTextSecondary)
            Text(String(localized: "这个习惯已不可用"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(String(localized: "可以返回继续查看其他记录。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 头部（习惯名 + 当前状态）

    private func headerHead(_ info: HabitReviewHabitInfo) -> some View {
        HStack(spacing: HoloSpacing.md) {
            iconBox(info)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text(headerSubtitle(info))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func headerSubtitle(_ info: HabitReviewHabitInfo) -> String {
        switch info.lifecycle {
        case .paused: return String(localized: "当前已暂停 · 历史保留")
        case .archived: return String(localized: "当前已归档 · 历史保留")
        case .active:
            return info.isBadHabit
                ? String(localized: "按真实发生记录")
                : String(localized: "每一次记录，都在这里")
        }
    }

    private func iconBox(_ info: HabitReviewHabitInfo) -> some View {
        let color = Color(hex: info.colorHex)
        return SnapshotIconBox(icon: info.icon, isCustomIcon: info.isCustomIcon, color: color)
    }

    // MARK: 范围控制

    private var rangeControl: some View {
        Button {
            rangeSheetShown = true
        } label: {
            HStack {
                Text(selectedRange.label(now: model.projectionNow, calendar: .current))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoToolText)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.holoToolBorder.opacity(0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("habit.single.range")
        .accessibilityLabel(Text(String(localized: "时间范围")))
    }

    // MARK: 结果摘要（最多两项）

    private func summarySection(_ snapshot: HabitRangeSnapshot) -> some View {
        let info = snapshot.info
        return HStack(spacing: 0) {
            switch info.kind {
            case .checkIn:
                summaryCell(
                    value: "\(snapshot.recordedDayCount)", unit: String(localized: "天"),
                    title: info.isBadHabit ? String(localized: "有发生记录的日子") : String(localized: "有记录的日子"))
            case .count:
                summaryCell(
                    value: HabitPresentationProjector.formatValue(snapshot.countTotal ?? 0),
                    unit: info.unit,
                    title: String(localized: "所选范围累计"))
                verticalDivider
                summaryCell(
                    value: "\(snapshot.recordedDayCount)", unit: String(localized: "天"),
                    title: String(localized: "有记录的日子"))
            case .measure:
                if let latest = snapshot.latestMeasure {
                    summaryCell(
                        value: HabitPresentationProjector.formatValue(latest.value),
                        unit: info.unit,
                        title: String(localized: "所选范围最近值 · \(shortDate(latest.day))"))
                } else {
                    summaryCell(value: "—", unit: "", title: String(localized: "所选范围最近值"))
                }
                verticalDivider
                summaryCell(
                    value: "\(snapshot.recordedDayCount)", unit: String(localized: "天"),
                    title: String(localized: "有记录的日子"))
            }
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { summarySeparator }
        .overlay(alignment: .bottom) { summarySeparator }
        .padding(.top, 14)
    }

    private var summarySeparator: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(height: 0.5)
    }

    private var verticalDivider: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(width: 0.5, height: 40)
    }

    private func summaryCell(value: String, unit: String, title: String) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .medium).monospacedDigit())
                    .foregroundColor(.holoToolText)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: 可视化（一块主要图，互斥）

    private func vizSection(_ snapshot: HabitRangeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(vizTitle(snapshot.info))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Spacer()
                if snapshot.info.kind != .checkIn {
                    vizSwitch
                }
            }
            .padding(.top, 16)

            switch vizMode {
            case .calendar:
                calendarView(snapshot)
            case .trend:
                trendView(snapshot)
            case .dates:
                dateListView(snapshot)
            }

            // 窄屏/大字号或 VoiceOver 的日期列表入口（§7.2：不把精确点选作唯一入口）
            Button {
                withAnimation(HoloAnimation.quick) {
                    vizMode = vizMode == .dates
                        ? (snapshot.info.kind == .checkIn ? .calendar : .trend)
                        : .dates
                }
            } label: {
                Text(vizMode == .dates ? String(localized: "返回图表") : String(localized: "按日期选择"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private func vizTitle(_ info: HabitReviewHabitInfo) -> String {
        switch vizMode {
        case .dates: return String(localized: "按日期查看")
        case .calendar:
            return info.isBadHabit ? String(localized: "发生日历") : String(localized: "记录日历")
        case .trend:
            return info.kind == .count
                ? String(localized: "每天的累计量")
                : String(localized: "每天的最新值")
        }
    }

    /// 趋势 / 日历 互斥切换（数值型；打卡型固定日历）
    private var vizSwitch: some View {
        HStack(spacing: 2) {
            modeChip(String(localized: "趋势"), active: vizMode == .trend,
                     identifier: "habit.single.viz.trend") {
                vizMode = .trend
            }
            modeChip(String(localized: "日历"), active: vizMode == .calendar,
                     identifier: "habit.single.viz.calendar") {
                vizMode = .calendar
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.holoToolInset))
    }

    private func modeChip(_ text: String, active: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .holoToolText : .holoToolTextSecondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.holoToolSurface : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: 日历

    private func calendarView(_ snapshot: HabitRangeSnapshot) -> some View {
        VStack(spacing: 8) {
            // 非「月」范围：范围内翻月（只改显示月，不改统计范围，§7.2）
            if case .month = selectedRange {
                EmptyView()
            } else {
                calendarMonthNav(snapshot)
            }
            ReviewCalendarGrid(
                month: selectedRange.calendarDisplayMonth(fallback: calendarMonth),
                snapshot: snapshot,
                selectedDay: selectedDay,
                today: model.projectionNow
            ) { day in
                selectDay(day)
            }
            calendarLegend(snapshot.info)
        }
    }

    private func calendarMonthNav(_ snapshot: HabitRangeSnapshot) -> some View {
        let calendar = Calendar.current
        let rangeStartMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: snapshot.interval.start)) ?? calendarMonth
        let rangeEndMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: snapshot.interval.end.addingTimeInterval(-1))) ?? calendarMonth
        let canPrev = calendarMonth > rangeStartMonth
        let canNext = calendarMonth < rangeEndMonth
        return HStack {
            Button {
                calendarMonth = calendar.date(byAdding: .month, value: -1, to: calendarMonth) ?? calendarMonth
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!canPrev)
            .accessibilityLabel(Text(String(localized: "范围内上一个月")))

            Spacer()
            Text(monthTitle(calendarMonth))
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
            Spacer()

            Button {
                calendarMonth = calendar.date(byAdding: .month, value: 1, to: calendarMonth) ?? calendarMonth
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!canNext)
            .accessibilityLabel(Text(String(localized: "范围内下一个月")))
        }
    }

    private func calendarLegend(_ info: HabitReviewHabitInfo) -> some View {
        let color = Color(hex: info.colorHex)
        return HStack(spacing: 14) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(info.isBadHabit ? String(localized: "有发生记录") : String(localized: "有记录"))
            }
            HStack(spacing: 4) {
                Circle().strokeBorder(color, lineWidth: 1).frame(width: 6, height: 6)
                Text(String(localized: "补录"))
            }
            HStack(spacing: 4) {
                Rectangle().fill(Color.holoToolTextSecondary.opacity(0.45)).frame(width: 6, height: 1)
                Text(String(localized: "暂停"))
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.holoToolTextSecondary)
    }

    // MARK: 趋势图（计数柱 / 测量分段点线）

    @ViewBuilder
    private func trendView(_ snapshot: HabitRangeSnapshot) -> some View {
        if snapshot.dailyValues.isEmpty {
            Text(String(localized: "这个范围还没有数值记录。\n无记录不会被填成 0。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ReviewTrendChart(
                values: snapshot.dailyValues,
                kind: snapshot.info.kind,
                color: Color(hex: snapshot.info.colorHex),
                unit: snapshot.info.unit,
                interval: snapshot.interval,
                today: model.projectionNow,
                selectedDay: selectedDay,
                onSelectDay: { day in selectDay(day) }
            )
            .frame(height: 200)
            Text(snapshot.info.kind == .count
                 ? String(localized: "每根柱子是当天的累计量。点记录可核对明细。")
                 : String(localized: "每个点是当天最后一次测量，缺失日不连线。点记录可核对明细。"))
                .font(.system(size: 10))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.top, 6)
        }
    }

    // MARK: 按日期列表（大字号/VoiceOver 同构入口）

    private func dateListView(_ snapshot: HabitRangeSnapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(daysIn(snapshot.interval).reversed(), id: \.self) { day in
                let info = snapshot.day(day, today: model.projectionNow, calendar: .current)
                Button {
                    selectDay(day)
                } label: {
                    HStack {
                        Text(shortDate(day))
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolText)
                        Spacer()
                        Text(dayStatusText(info, snapshot: snapshot))
                            .font(.system(size: 11))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) { summarySeparator }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(fullDate(day))，\(dayStatusText(info, snapshot: snapshot))"))
            }
        }
    }

    // MARK: 日期明细

    private func dayDetailSection(_ snapshot: HabitRangeSnapshot, day: Date) -> some View {
        let info = snapshot.day(day, today: model.projectionNow, calendar: .current)
        let dayRecords = records(on: day, snapshot: snapshot)
        return VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(height: 0.5)
                .padding(.top, 18)

            HStack {
                Text(fullDate(day))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Spacer()
                if !dayRecords.isEmpty {
                    Text(String(localized: "\(dayRecords.count) 条"))
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.holoToolInset))
                }
            }
            .padding(.top, 10)

            Text(dayStatusText(info, snapshot: snapshot))
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)

            if dayRecords.isEmpty {
                Text(String(localized: "这一天还没有留下记录。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.holoToolInset))

                if let retro = retroactiveEntry(day, info: info) {
                    Button {
                        if let habit {
                            retroContext = HabitRetroactiveSheetContext(
                                habit: habit, preselectedDay: day, mode: retro)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 13))
                            Text(retro == .sign
                                 ? String(localized: "补签这一天")
                                 : String(localized: "补记这一天"))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: snapshot.info.colorHex))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(hex: snapshot.info.colorHex).opacity(0.5))
                        )
                    }
                    .buttonStyle(HoloPressStyle())
                    .padding(.top, 4)
                } else if let reason = ineligibleReason(day, info: info) {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.85))
                }
            } else {
                ForEach(dayRecords) { record in
                    recordRow(record, snapshot: snapshot)
                }
            }

            // 今天且进行中：去今天记录（不在统计页常驻另一套打卡/加减，§7.3）
            if Calendar.current.isDateInToday(day), lifecycle == .active {
                Button {
                    onGoTodayRecord(habitId)
                } label: {
                    HStack(spacing: 5) {
                        Text(String(localized: "去今天记录"))
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 4)
            }
        }
    }

    private func recordRow(_ record: HabitRecord, snapshot: HabitRangeSnapshot) -> some View {
        HStack(alignment: .center, spacing: HoloSpacing.sm) {
            Button {
                editingRecord = RecordTarget(recordId: record.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.formattedTime)
                            .font(.system(size: 10))
                            .foregroundColor(.holoToolTextSecondary)
                        if record.isRetroactive {
                            Text(String(localized: "补录"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(hex: snapshot.info.colorHex))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color(hex: snapshot.info.colorHex).opacity(0.35)))
                        }
                    }
                    Text(recordTitle(record, snapshot: snapshot))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoToolText)
                    if let note = record.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    editingRecord = RecordTarget(recordId: record.id)
                } label: {
                    Label(String(localized: "编辑记录"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDeleteRecord = record
                } label: {
                    Label(String(localized: "删除记录"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 38, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .overlay(alignment: .bottom) { summarySeparator }
    }

    private func recordTitle(_ record: HabitRecord, snapshot: HabitRangeSnapshot) -> String {
        if snapshot.info.kind == .checkIn {
            return record.isCompleted
                ? (snapshot.info.isBadHabit ? String(localized: "记录发生") : String(localized: "打卡记录"))
                : String(localized: "已取消")
        }
        return record.formattedValue(unit: snapshot.info.unit)
    }

    // MARK: 范围弹层

    private var rangeSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "时间范围"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(String(localized: "摘要、图和明细使用同一个范围。这里改变范围，不会改动整体回顾的月份。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.top, 4)
                .padding(.bottom, 14)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                rangeOption(String(localized: "本月"), for: .month(currentMonthStart))
                if let prev = Calendar.current.date(byAdding: .month, value: -1, to: currentMonthStart) {
                    rangeOption(String(localized: "上月"), for: .month(prev))
                }
                rangeOption(String(localized: "最近 7 天"), for: .lastDays(7))
                rangeOption(String(localized: "最近 30 天"), for: .lastDays(30))
                rangeOption(String(localized: "最近 90 天"), for: .lastDays(90))
                rangeOption(String(localized: "全部记录"), for: .all)
            }
            .padding(.bottom, 16)

            ReviewCustomRangeForm { start, end in
                applyRange(.custom(start: start, end: end))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.md)
        .presentationDetents([.large])
    }

    private var currentMonthStart: Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    private func rangeOption(_ title: String, for range: HabitReviewRange) -> some View {
        Button {
            applyRange(range)
        } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(selectedRange == range ? .holoPrimary : .holoToolText)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selectedRange == range
                                      ? Color.holoPrimary
                                      : Color.holoToolBorder.opacity(0.7))
                )
        }
        .buttonStyle(HoloPressStyle())
    }

    private func applyRange(_ range: HabitReviewRange) {
        selectedRange = range
        selectedDay = nil
        rangeSheetShown = false
        // 翻月状态归位到新范围（月范围显示月直接派生自范围，此赋值让切回
        // 跨月范围时日历从范围首月起步，不停在无关月份）
        let calendar = Calendar.current
        let rangeStart = range.dateInterval(now: model.projectionNow, calendar: calendar).start
        calendarMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: rangeStart)) ?? calendarMonth
        rebuild()
    }

    // MARK: 状态与资格文案

    private func dayStatusText(_ info: HabitReviewDay, snapshot: HabitRangeSnapshot) -> String {
        var parts: [String] = []
        if info.isBeforeCreation {
            parts.append(String(localized: "习惯创建前"))
        } else if info.isFuture {
            parts.append(String(localized: "未来日期"))
        }
        if info.isRecorded {
            if snapshot.info.kind == .checkIn {
                parts.append(snapshot.info.isBadHabit
                             ? String(localized: "有发生记录")
                             : String(localized: "已记录"))
            } else if let value = info.dailyValue {
                parts.append("\(HabitPresentationProjector.formatValue(value)) \(snapshot.info.unit)")
            }
            if info.isRetroactive { parts.append(String(localized: "含补录")) }
            if info.isPaused { parts.append(String(localized: "暂停期间有记录")) }
        } else if info.isPaused {
            parts.append(String(localized: "暂停日"))
        } else if !info.isBeforeCreation && !info.isFuture {
            parts.append(String(localized: "无记录"))
        }
        return parts.joined(separator: " · ")
    }

    /// 补录入口（V1 既有资格真源：窗口内 sign / 窗口外 backfill；§10）
    private func retroactiveEntry(_ day: Date, info: HabitReviewDay) -> HabitRetroactiveMode? {
        guard let habit, lifecycle == .active else { return nil }
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([habitId]),
            now: model.projectionNow
        )
        return HabitPresentationProjector.retroactiveMode(habit: habit, day: day, data: data)
    }

    /// 不可补的原因说明（§7.3：说明原因，不给无响应按钮）
    private func ineligibleReason(_ day: Date, info: HabitReviewDay) -> String? {
        let dayStart = Calendar.current.startOfDay(for: day)
        let todayStart = Calendar.current.startOfDay(for: model.projectionNow)
        guard dayStart < todayStart else {
            return dayStart > todayStart ? String(localized: "未来日期不可记录") : nil
        }
        if info.isBeforeCreation { return String(localized: "习惯创建前不可补录") }
        if info.isPaused { return String(localized: "暂停日不算漏签") }
        guard let habit else { return nil }
        if habit.isBadHabit { return String(localized: "这个减少的习惯不支持补录") }
        if habit.isCheckInType, habit.habitFrequency != .daily {
            return String(localized: "周/月习惯按周期记录，不补每日漏签")
        }
        return nil
    }

    // MARK: 数据

    private struct RecordTarget: Identifiable {
        let recordId: UUID
        var id: UUID { recordId }
    }

    private func initializeState() {
        guard let habit else { return }
        selectedRange = .month(model.overviewMonth)
        vizMode = habit.isCheckInType ? .calendar : .trend
        calendarMonth = model.overviewMonth
    }

    private func rebuild() {
        guard let habit else { return }
        let info = HabitReviewHabitInfo(habit: habit, lifecycle: lifecycle)
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([habitId]),
            now: model.projectionNow
        )
        snapshot = HabitReviewProjector.rangeSnapshot(info: info, range: selectedRange, data: data)
        // 选中日失效（范围切换后外置）时清空
        if let day = selectedDay, let snap = snapshot,
           !snap.containsDay(day, calendar: .current) {
            selectedDay = nil
        }
    }

    private func selectDay(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
    }

    private func records(on day: Date, snapshot: HabitRangeSnapshot) -> [HabitRecord] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        return snapshot.records
            .filter { calendar.startOfDay(for: $0.date) == dayStart }
            .compactMap { fact -> HabitRecord? in
                let request = HabitRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", fact.id as CVarArg)
                request.fetchLimit = 1
                return try? HabitRepository.shared.context.fetch(request).first
            }
    }

    private func findRecord(_ recordId: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        return try? HabitRepository.shared.context.fetch(request).first
    }

    private func daysIn(_ interval: DateInterval) -> [Date] {
        let calendar = Calendar.current
        var days: [Date] = []
        var current = interval.start
        while current < interval.end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter.string(from: date)
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
        return formatter.string(from: month)
    }
}

// MARK: - 图标盒（值快照渲染）

private struct SnapshotIconBox: View {
    let icon: String
    let isCustomIcon: Bool
    let color: Color

    private struct Renderer: HabitIconRenderable {
        let icon: String
        let isCustomIcon: Bool
    }

    var body: some View {
        Renderer(icon: icon, isCustomIcon: isCustomIcon)
            .iconImage(size: 20)
            .foregroundColor(color)
            .frame(width: 42, height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
    }
}

// MARK: - 自定义范围表单

private struct ReviewCustomRangeForm: View {

    var onApply: (Date, Date) -> Void

    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.startOfDay(for: Date())
    @State private var errorMessage: String?

    private var dateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        return today...today
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "自定义范围"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoToolTextSecondary)
            HStack(spacing: 8) {
                DatePicker(String(localized: "开始日期"), selection: $start, in: dateRange,
                           displayedComponents: .date)
                    .labelsHidden()
                DatePicker(String(localized: "结束日期"), selection: $end, in: dateRange,
                           displayedComponents: .date)
                    .labelsHidden()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.holoError)
            }
            Button {
                let calendar = Calendar.current
                let s = calendar.startOfDay(for: start)
                let e = calendar.startOfDay(for: end)
                let today = calendar.startOfDay(for: Date())
                guard s <= e, e <= today else {
                    errorMessage = String(localized: "请选择有效的开始和结束日期，不能选择未来日期。")
                    return
                }
                onApply(s, e)
            } label: {
                Text(String(localized: "应用这个范围"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.holoToolBorder.opacity(0.7))
                    )
            }
            .buttonStyle(HoloPressStyle())
        }
    }
}

// MARK: - 回顾日历格（V2 新组件：记录与表现分字段，不复用旧 hasRecord 语义）

struct ReviewCalendarGrid: View {

    let month: Date
    let snapshot: HabitRangeSnapshot
    let selectedDay: Date?
    let today: Date
    var onSelectDay: (Date) -> Void

    private var calendar: Calendar { .current }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
    }

    private var days: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
    }

    /// 周一首列的偏移
    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday + 5) % 7
    }

    private var weekdaySymbols: [String] {
        let all = calendar.shortWeekdaySymbols
        return Array(all[1...]) + [all[0]]
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 4)

            let cells = days
            let blanks = leadingBlanks
            let rows = Int(ceil(Double(blanks + cells.count) / 7.0))
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = row * 7 + column - blanks
                        if index >= 0 && index < cells.count {
                            dayCell(cells[index])
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 45)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let info = snapshot.day(day, today: today, calendar: calendar)
        let accent = Color(hex: snapshot.info.colorHex)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let inRange = snapshot.containsDay(day, calendar: calendar)
        let disabled = !inRange || info.isBeforeCreation || info.isFuture

        return Button {
            onSelectDay(day)
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday(day) ? .bold : .regular).monospacedDigit())
                    .foregroundColor(isToday(day) ? accent : .holoToolText)
                if info.isPaused && !info.isRecorded {
                    Text(String(localized: "休"))
                        .font(.system(size: 8))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(height: 5)
                } else {
                    mark(info, accent: accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 45)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(cellBackground(info, accent: accent))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? accent : .clear, lineWidth: 1.5)
            )
            .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text("\(fullDate(day))，\(dayAccessibilityStatus(info))"))
    }

    private func isToday(_ day: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: today)
    }

    @ViewBuilder
    private func mark(_ info: HabitReviewDay, accent: Color) -> some View {
        if info.isRecorded {
            if info.isRetroactive {
                Circle()
                    .strokeBorder(accent, lineWidth: 1)
                    .frame(width: 6, height: 6)
            } else {
                Circle().fill(accent).frame(width: 5, height: 5)
            }
        } else {
            Circle().fill(Color.holoToolBorder.opacity(0.7)).frame(width: 4, height: 4)
        }
    }

    private func cellBackground(_ info: HabitReviewDay, accent: Color) -> Color {
        if info.isRecorded { return accent.opacity(0.12) }
        if info.isPaused { return Color.holoToolInset }
        return .clear
    }

    private func dayAccessibilityStatus(_ info: HabitReviewDay) -> String {
        if info.isBeforeCreation { return String(localized: "习惯创建前") }
        if info.isFuture { return String(localized: "未来日期") }
        if info.isRecorded { return String(localized: "有记录") }
        if info.isPaused { return String(localized: "暂停日") }
        return String(localized: "无记录")
    }

    private func fullDate(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        return formatter.string(from: day)
    }
}

// MARK: - 回顾趋势图几何（纯函数，单测锁定）

/// 与财务统计图同一套既定画法（东林 2026-10-07 拍板不重复造轮子）：
/// 每个自然日一个槽位、柱宽 pt 封顶、X 刻度全部 chartOverlay 自绘
/// （AxisValueLabel 摆放位置不可控会右偏，财务同病 d5406381d 已治）、
/// 拖动/点按沿槽位连续选中当天（横向手势独占，纵向交还页面滚动）。
enum ReviewTrendChartLayout {

    /// 柱宽（pt）：与财务 ChartBarPairLayout.barWidth 同参（>14 槽 3.2 / 否则 6）；
    /// 槽位极窄（如「全部记录」跨年）时按槽宽收缩，下限 1pt
    static func barWidthPt(dayCount: Int, slotWidthPt: CGFloat) -> CGFloat {
        let base: CGFloat = dayCount > 14 ? 3.2 : 6
        guard slotWidthPt > 0 else { return base }
        return max(min(base, slotWidthPt * 0.7), 1)
    }

    /// X 域：槽位下标 0...dayCount-1 居中，两侧各留半槽
    static func xDomain(dayCount: Int) -> ClosedRange<Double> {
        -0.5...(Double(max(dayCount, 1)) - 0.5)
    }

    /// 自然日在域内的槽位下标（以 rangeStart 为 0；域外返回 nil）
    static func slotIndex(of day: Date, rangeStart: Date, dayCount: Int, calendar: Calendar) -> Int? {
        let offset = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: rangeStart), to: calendar.startOfDay(for: day)).day ?? 0
        guard offset >= 0, offset < max(dayCount, 1) else { return nil }
        return offset
    }

    /// 触摸点（绘图区坐标）→ 槽位下标（钳到两端；拖动沿途连续选中）
    static func touchedSlot(touchXInPlot: CGFloat, plotWidth: CGFloat, dayCount: Int) -> Int? {
        guard dayCount > 0, plotWidth > 0 else { return nil }
        let slot = Int((touchXInPlot / plotWidth * CGFloat(dayCount)).rounded(.down))
        return min(max(slot, 0), dayCount - 1)
    }

    /// 刻度槽位：≤10 天逐日标注；更长走财务同款稀疏节奏（5 格均匀 + 末日）
    static func tickSlots(dayCount: Int) -> [Int] {
        guard dayCount > 0 else { return [] }
        guard dayCount > 10 else { return Array(0..<dayCount) }
        let step = Double(dayCount - 1) / 5
        var slots = (0..<5).map { index in
            min(Int((Double(index) * step).rounded()), dayCount - 2)
        }
        slots.append(dayCount - 1)
        return slots
    }

    /// 图域（起日 + 天数）。月/近 N 天保持完整范围（空槽如实留白，末日不超今天）；
    /// 超长范围（全部记录/多年自定义）收敛到首末记录日，否则一天一槽细到不可读。
    static func chartRange(interval: DateInterval, today: Date,
                           values: [HabitDailyNumericValue], calendar: Calendar) -> (start: Date, dayCount: Int) {
        let nominalStart = calendar.startOfDay(for: interval.start)
        let rangeEndDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let nominalEnd = min(calendar.startOfDay(for: rangeEndDay), calendar.startOfDay(for: today))
        let spanDays = calendar.dateComponents([.day], from: nominalStart, to: nominalEnd).day ?? 0
        if spanDays > 366 {
            let valueDays = values.map { calendar.startOfDay(for: $0.date) }
            let first = valueDays.min() ?? nominalStart
            let last = max(valueDays.max() ?? nominalEnd, first)
            let count = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            return (first, max(count, 1))
        }
        return (nominalStart, max(spanDays, 0) + 1)
    }
}

// MARK: - 回顾趋势图（计数柱 / 测量分段点线；拖动沿途选中）

struct ReviewTrendChart: View {

    let values: [HabitDailyNumericValue]
    let kind: HabitRowKind
    let color: Color
    let unit: String
    /// 图表覆盖的完整范围（柱子按真实日期落位，缺失日留空槽）
    let interval: DateInterval
    /// 当前时刻（域终点钳到今天，未来日不占槽）
    let today: Date
    let selectedDay: Date?
    var onSelectDay: (Date) -> Void

    private struct SlotValue: Identifiable {
        let slot: Int
        let date: Date
        let value: Double
        var id: Int { slot }
    }

    private struct Segment: Identifiable {
        let id: Int
        let points: [SlotValue]
    }

    private var calendar: Calendar { .current }

    private var chartRange: (start: Date, dayCount: Int) {
        ReviewTrendChartLayout.chartRange(interval: interval, today: today,
                                          values: values, calendar: calendar)
    }

    private func slotValues(range: (start: Date, dayCount: Int)) -> [SlotValue] {
        values.compactMap { item in
            guard let slot = ReviewTrendChartLayout.slotIndex(
                of: item.date, rangeStart: range.start, dayCount: range.dayCount, calendar: calendar)
            else { return nil }
            return SlotValue(slot: slot, date: item.date, value: item.value)
        }
    }

    /// 测量折线分段：相邻槽位间隔 >1 天即断段（缺失日不连线）
    private func segments(of points: [SlotValue]) -> [Segment] {
        var segments: [[SlotValue]] = []
        var current: [SlotValue] = []
        for item in points {
            if let last = current.last, item.slot - last.slot > 1 {
                segments.append(current)
                current = [item]
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.enumerated().map { Segment(id: $0.offset, points: $0.element) }
    }

    private var normalizedSelected: Date? {
        selectedDay.map { calendar.startOfDay(for: $0) }
    }

    private var yDomain: ClosedRange<Double> {
        let nums = values.map(\.value)
        let minVal = nums.min() ?? 0
        let maxVal = nums.max() ?? 1
        if kind == .count {
            return 0...max(maxVal, 1)
        }
        if maxVal == minVal {
            return max(minVal - 1, 0)...(maxVal + 1)
        }
        let pad = (maxVal - minVal) * 0.2
        return max(minVal - pad, 0)...(maxVal + pad)
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geometry in
            let range = chartRange
            let slotWidthPt = ChartBarPairLayout.estimatedSlotWidthPt(
                containerWidthPt: geometry.size.width,
                pointCount: range.dayCount
            )
            chart(range: range,
                  barWidthPt: ReviewTrendChartLayout.barWidthPt(dayCount: range.dayCount, slotWidthPt: slotWidthPt))
        }
    }

    private func chart(range: (start: Date, dayCount: Int), barWidthPt: CGFloat) -> some View {
        Chart {
            if kind == .count {
                countMarks(range: range, barWidthPt: barWidthPt)
            } else {
                measureMarks(range: range)
            }
        }
        .chartXScale(domain: ReviewTrendChartLayout.xDomain(dayCount: range.dayCount))
        .chartYScale(domain: yDomain)
        // X 刻度已由 chartOverlay 自绘（与柱子同一坐标系）；必须显式隐藏默认轴——
        // 不提供 chartXAxis 时 Charts 会自画一套数字刻度（0...N-1），与自绘日期
        // 同位叠加，真机上呈「日期重叠乱码」（2026-10-07 东林真机实锤）
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.holoToolBorder.opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(HabitPresentationProjector.formatValue(v))
                            .font(.system(size: 9))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.padding(.leading, 2)
                .padding(.trailing, 2)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                if let plotFrame {
                    // —— X 轴刻度自绘：与柱子/高亮带共用 position(forX:) 同一坐标系，
                    //    位置即数据点位置（财务 2026-10-07 同款修法）——
                    ForEach(ReviewTrendChartLayout.tickSlots(dayCount: range.dayCount), id: \.self) { slot in
                        if let xPos = proxy.position(forX: Double(slot)) {
                            Text(axisLabel(slot: slot, rangeStart: range.start))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .position(x: plotFrame.minX + xPos, y: plotFrame.maxY + 10)
                        }
                    }

                    // —— 选中日：柱后淡色高亮带 + 数值气泡（拖动沿途实时跟随）——
                    if let slot = selectedSlot(range: range),
                       let xPos = proxy.position(forX: Double(slot)) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.holoToolText.opacity(0.05))
                            .frame(width: plotFrame.width / CGFloat(range.dayCount), height: plotFrame.height)
                            .position(x: plotFrame.minX + xPos, y: plotFrame.midY)

                        let detail = tooltipDetail(slot: slot, range: range)
                        VStack(spacing: 2) {
                            Text(detail.date)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                            Text(detail.value)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(color)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.holoToolSurface)
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        )
                        .fixedSize()
                        .position(x: min(max(plotFrame.minX + xPos, 60), geometry.size.width - 60),
                                  y: min(max(plotFrame.minY + plotFrame.height * 0.14, 16), geometry.size.height - 16))
                    }

                    // —— 手势：横向拖动/点按选中当天，纵向交还页面滚动（财务同款组件）——
                    DirectionalChartGestureOverlay(
                        onChanged: { location in
                            selectNearest(location, proxy: proxy, plotFrame: plotFrame, range: range)
                        },
                        onEnded: { _ in },
                        onCancelled: {},
                        onTap: { location in
                            selectNearest(location, proxy: proxy, plotFrame: plotFrame, range: range)
                        }
                    )
                }
            }
        }
    }

    @ChartContentBuilder
    private func countMarks(range: (start: Date, dayCount: Int), barWidthPt: CGFloat) -> some ChartContent {
        ForEach(slotValues(range: range)) { item in
            BarMark(
                x: .value("日期", Double(item.slot)),
                y: .value("值", item.value),
                width: .fixed(barWidthPt)
            )
            .foregroundStyle(color.opacity(item.date == normalizedSelected ? 1.0 : 0.65))
            .cornerRadius(3)
        }
    }

    @ChartContentBuilder
    private func measureMarks(range: (start: Date, dayCount: Int)) -> some ChartContent {
        let points = slotValues(range: range)
        ForEach(segments(of: points)) { segment in
            ForEach(segment.points) { item in
                LineMark(
                    x: .value("日期", Double(item.slot)),
                    y: .value("值", item.value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        ForEach(points) { item in
            PointMark(
                x: .value("日期", Double(item.slot)),
                y: .value("值", item.value)
            )
            .foregroundStyle(color)
            .symbolSize(item.date == normalizedSelected ? 60 : 30)
        }
    }

    // MARK: 选中与命中

    private func selectedSlot(range: (start: Date, dayCount: Int)) -> Int? {
        guard let day = normalizedSelected else { return nil }
        return ReviewTrendChartLayout.slotIndex(of: day, rangeStart: range.start,
                                                dayCount: range.dayCount, calendar: calendar)
    }

    private func selectNearest(_ location: CGPoint, proxy: ChartProxy, plotFrame: CGRect?,
                               range: (start: Date, dayCount: Int)) {
        guard let plotFrame,
              let slot = ReviewTrendChartLayout.touchedSlot(
                  touchXInPlot: location.x - plotFrame.minX,
                  plotWidth: plotFrame.width,
                  dayCount: range.dayCount),
              let day = calendar.date(byAdding: .day, value: slot, to: range.start)
        else { return }
        onSelectDay(day)
    }

    /// 气泡文案：当天有值显示数值，无值如实说无记录
    private func tooltipDetail(slot: Int, range: (start: Date, dayCount: Int)) -> (date: String, value: String) {
        let day = calendar.date(byAdding: .day, value: slot, to: range.start) ?? range.start
        let dayStart = calendar.startOfDay(for: day)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        let valueText: String
        if let value = values.first(where: { calendar.startOfDay(for: $0.date) == dayStart })?.value {
            let formatted = HabitPresentationProjector.formatValue(value)
            valueText = unit.isEmpty ? formatted : "\(formatted) \(unit)"
        } else {
            valueText = String(localized: "无记录")
        }
        return (formatter.string(from: day), valueText)
    }

    private func axisLabel(slot: Int, rangeStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let day = calendar.date(byAdding: .day, value: slot, to: rangeStart) ?? rangeStart
        return formatter.string(from: day)
    }
}
