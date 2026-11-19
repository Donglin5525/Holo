//
//  HabitTodayVizCard.swift
//  Holo
//
//  习惯今日详情抽屉：交互式本月日历 / 近 30 天节奏 / 数值走势卡片（叶子组件）。
//  图表复用公共组件 HoloBarChart / HoloMiniTrendChart（图表规范 V3 唯一实现）。
//

import SwiftUI

struct HabitTodayVizCard: View {
    enum VizTab: String, Equatable {
        case calendar
        case last30
        case chart
    }

    let row: HabitRowSnapshot
    let monthSnapshot: HabitRangeSnapshot?
    let last30Snapshot: HabitRangeSnapshot?
    let recentNumericSnapshot: HabitRangeSnapshot?
    let projectionNow: Date
    let habitToday: Date
    /// 每日备注摘要（startOfDay -> 备注文本，值快照避免 body 内查库）
    let dayNotes: [Date: String]
    /// 每日最近打卡时刻（startOfDay -> HH:mm）
    let dayTimes: [Date: String]
    let onOpenReview: () -> Void
    let onRequestRetroactive: ((Date) -> Void)?

    @State private var activeTab: VizTab
    @State private var selectedDay: Date
    @State private var selectedBarId: String? = nil

    private let calendar = Calendar.current
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    init(
        row: HabitRowSnapshot,
        monthSnapshot: HabitRangeSnapshot?,
        last30Snapshot: HabitRangeSnapshot?,
        recentNumericSnapshot: HabitRangeSnapshot?,
        projectionNow: Date,
        habitToday: Date,
        dayNotes: [Date: String],
        dayTimes: [Date: String],
        onOpenReview: @escaping () -> Void,
        onRequestRetroactive: ((Date) -> Void)? = nil
    ) {
        self.row = row
        self.monthSnapshot = monthSnapshot
        self.last30Snapshot = last30Snapshot
        self.recentNumericSnapshot = recentNumericSnapshot
        self.projectionNow = projectionNow
        self.habitToday = habitToday
        self.dayNotes = dayNotes
        self.dayTimes = dayTimes
        self.onOpenReview = onOpenReview
        self.onRequestRetroactive = onRequestRetroactive
        let defaultTab: VizTab = row.kind == .checkIn ? .calendar : .chart
        _activeTab = State(initialValue: defaultTab)
        _selectedDay = State(initialValue: habitToday)
    }

    private var accent: Color { Color(hex: row.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            switch row.kind {
            case .checkIn:
                if activeTab == .last30 {
                    last30Matrix
                } else {
                    monthCalendarSection
                }
            case .count:
                if activeTab == .calendar {
                    monthCalendarSection
                } else {
                    countBarChartSection
                }
            case .measure:
                measureTrendSection
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .holoSurface(.independent)
        .accessibilityIdentifier("habit.todayrecord.history")
        .onChange(of: habitToday) { _, newToday in
            selectedDay = newToday
        }
    }

    // MARK: 卡片头部 + 分段控件（§8.8.3 灰轨白块唯一样式）

    private var headerRow: some View {
        HStack(alignment: .center, spacing: HoloSpacing.sm) {
            Text(cardTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1)

            Spacer(minLength: 8)

            switch row.kind {
            case .checkIn:
                segmentedControl(
                    first: (String(localized: "本月"), .calendar),
                    second: (String(localized: "近30天"), .last30)
                )
            case .count:
                segmentedControl(
                    first: (String(localized: "走势"), .chart),
                    second: (String(localized: "月历"), .calendar)
                )
            case .measure:
                if let rangeText = measureRangeText {
                    Text(rangeText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.holoToolInset))
                }
            }
        }
    }

    private var cardTitle: String {
        let monthNum = calendar.component(.month, from: habitToday)
        switch row.kind {
        case .checkIn:
            return activeTab == .last30
                ? String(localized: "近 30 天节奏")
                : String(localized: "\(monthNum) 月打卡日历")
        case .count:
            return activeTab == .calendar
                ? String(localized: "\(monthNum) 月记录日历")
                : String(localized: "近 10 天走势")
        case .measure:
            return String(localized: "最近记录走势")
        }
    }

    private func segmentedControl(first: (String, VizTab), second: (String, VizTab)) -> some View {
        HStack(spacing: 2) {
            segButton(title: first.0, tab: first.1)
            segButton(title: second.0, tab: second.1)
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.holoToolInset))
    }

    private func segButton(title: String, tab: VizTab) -> some View {
        let selected = activeTab == tab
        return Button {
            HapticManager.light()
            withAnimation(HoloAnimation.quick) { activeTab = tab }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.holoToolText : Color.holoToolTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.holoToolSurface : .clear)
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1.5, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 1. 本月交互式日历（周一优先）

    private var monthCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 星期标题
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.75))
                        .frame(maxWidth: .infinity)
                }
            }

            // 日期格
            let cells = monthGridCells()
            let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(cells) { cell in
                    if let day = cell.date, let snapshot = monthSnapshot {
                        let info = snapshot.day(day, today: projectionNow, calendar: calendar)
                        calendarCell(day: day, info: info)
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }

            // 选中日内联明细条
            if let snapshot = monthSnapshot {
                dayInspectorBar(snapshot: snapshot)
            }

            // 图例 + 完整回顾入口
            footerRow(legend: calendarLegend)
        }
    }

    private struct CalendarCellSlot: Identifiable {
        let id: String
        let date: Date?
    }

    private func monthGridCells() -> [CalendarCellSlot] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: habitToday)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            return []
        }
        // Swift weekday: 1=Sun, 2=Mon... -> Monday-first offset (0..6)
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingEmpty = (firstWeekday + 5) % 7

        var slots: [CalendarCellSlot] = (0..<leadingEmpty).map {
            CalendarCellSlot(id: "empty-\($0)", date: nil)
        }
        for offset in 0..<dayRange.count {
            if let date = calendar.date(byAdding: .day, value: offset, to: monthStart) {
                let dayStart = calendar.startOfDay(for: date)
                slots.append(CalendarCellSlot(id: "day-\(offset + 1)", date: dayStart))
            }
        }
        return slots
    }

    private func calendarCell(day: Date, info: HabitReviewDay) -> some View {
        let dayNum = calendar.component(.day, from: day)
        let isToday = calendar.isDate(day, inSameDayAs: habitToday)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isInteractive = !info.isBeforeCreation && !info.isFuture

        let fillColor: Color = {
            if info.isBeforeCreation || info.isFuture { return .clear }
            if info.isRecorded {
                return info.isRetroactive ? accent.opacity(0.14) : accent
            }
            if info.isPaused { return .clear }
            return Color.holoToolInset
        }()

        let textColor: Color = {
            if info.isBeforeCreation || info.isFuture { return Color.holoToolTextSecondary.opacity(0.32) }
            if info.isRecorded {
                return info.isRetroactive ? accent : Color.white
            }
            return Color.holoToolText.opacity(0.7)
        }()

        let isMissedPast = !info.isBeforeCreation && !info.isFuture && !info.isRecorded && !info.isPaused

        return Button {
            guard isInteractive else { return }
            HapticManager.light()
            withAnimation(HoloAnimation.quick) { selectedDay = day }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)

                if info.isRecorded, info.isRetroactive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent, lineWidth: 1.4)
                } else if info.isPaused, !info.isBeforeCreation, !info.isFuture {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.holoToolBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else if isMissedPast {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.holoToolBorder.opacity(0.7), lineWidth: 0.6)
                }

                if isToday, !isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent, lineWidth: 1.6)
                }

                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.holoToolText.opacity(0.75), lineWidth: 1.6)
                }

                Text("\(dayNum)")
                    .font(.system(size: 12.5, weight: (info.isRecorded || isToday) ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(textColor)

                if isToday {
                    Circle()
                        .fill(info.isRecorded && !info.isRetroactive ? Color.white : accent)
                        .frame(width: 4, height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 3)
                } else if info.isRecorded, info.isRetroactive {
                    Circle()
                        .fill(accent)
                        .frame(width: 4, height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 3)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
    }

    private func dayInspectorBar(snapshot: HabitRangeSnapshot) -> some View {
        let dayStart = calendar.startOfDay(for: selectedDay)
        let info = snapshot.day(dayStart, today: projectionNow, calendar: calendar)
        let dateText = formatMonthDayWeekday(dayStart)
        let note = dayNotes[dayStart]
        let time = dayTimes[dayStart]
        let isToday = calendar.isDate(dayStart, inSameDayAs: habitToday)

        let mainText: String = {
            if row.kind == .count {
                if let val = info.dailyValue {
                    let vText = HabitPresentationProjector.formatValue(val)
                    return "\(dateText) · \(vText) \(row.unit)".trimmingCharacters(in: .whitespaces)
                }
                return "\(dateText) · " + String(localized: "无记录")
            }
            if row.isBadHabit {
                if info.isRecorded {
                    let suffix = time.map { " \($0)" } ?? ""
                    return "\(dateText) · " + String(localized: "记录发生") + suffix
                }
                return "\(dateText) · " + String(localized: "未发生（保持克制）")
            }
            if info.isRecorded {
                let verb = info.isRetroactive ? String(localized: "已补录") : String(localized: "已打卡")
                let suffix = time.map { " · \($0)" } ?? ""
                return "\(dateText) · \(verb)\(suffix)"
            }
            if info.isPaused {
                return "\(dateText) · " + String(localized: "已暂停")
            }
            return "\(dateText) · " + String(localized: "未打卡")
        }()

        let subText: String? = {
            if let note, !note.isEmpty { return note }
            if row.isBadHabit {
                return info.isRecorded ? nil : (isToday ? String(localized: "今天继续保持") : String(localized: "安稳度过这一天"))
            }
            if info.isRecorded { return nil }
            return isToday ? String(localized: "今天还未完成记录") : String(localized: "这天漏卡了")
        }()

        let canRetro = row.kind == .checkIn
            && !row.isBadHabit
            && row.lifecycle == .active
            && !info.isRecorded
            && !info.isPaused
            && !info.isBeforeCreation
            && !info.isFuture
            && !isToday
            && onRequestRetroactive != nil

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mainText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                if let subText {
                    Text(subText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if canRetro, let onRequestRetroactive {
                Button {
                    HapticManager.light()
                    onRequestRetroactive(dayStart)
                } label: {
                    Text(String(localized: "补录这天"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                                .fill(Color.holoToolSurface)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.holoToolInset.opacity(0.65))
        )
    }

    private var calendarLegend: some View {
        HStack(spacing: 10) {
            if row.isBadHabit {
                legendItem(swatch: RoundedRectangle(cornerRadius: 3).fill(accent), text: String(localized: "发生"))
                legendItem(
                    swatch: RoundedRectangle(cornerRadius: 3)
                        .fill(Color.holoToolInset)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.holoToolBorder.opacity(0.75), lineWidth: 0.6)),
                    text: String(localized: "未发生")
                )
            } else {
                legendItem(swatch: RoundedRectangle(cornerRadius: 3).fill(accent), text: String(localized: "已完成"))
                legendItem(
                    swatch: RoundedRectangle(cornerRadius: 3)
                        .fill(accent.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(accent, lineWidth: 1.2)),
                    text: String(localized: "补录")
                )
                legendItem(
                    swatch: RoundedRectangle(cornerRadius: 3)
                        .fill(Color.holoToolInset)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.holoToolBorder.opacity(0.75), lineWidth: 0.6)),
                    text: String(localized: "未记录")
                )
            }
        }
    }

    private func legendItem<S: View>(swatch: S, text: String) -> some View {
        HStack(spacing: 4) {
            swatch.frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary)
        }
    }

    // MARK: 2. 近 30 天紧凑点阵（10×3）

    private var last30Matrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            let days = last30Days()
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 10)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(days, id: \.self) { day in
                    if let snapshot = last30Snapshot {
                        let info = snapshot.day(day, today: projectionNow, calendar: calendar)
                        matrix30Cell(info: info, isToday: calendar.isDate(day, inSameDayAs: habitToday))
                    }
                }
            }

            footerRow(legend: Text(String(localized: "过去 30 天节奏（从左到右至今天）"))
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary))
        }
    }

    private func last30Days() -> [Date] {
        (0..<30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: habitToday).map { calendar.startOfDay(for: $0) }
        }
    }

    @ViewBuilder
    private func matrix30Cell(info: HabitReviewDay, isToday: Bool) -> some View {
        ZStack {
            if info.isBeforeCreation {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.holoToolBorder.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else if info.isRecorded {
                if info.isRetroactive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(0.2))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(accent, lineWidth: 1.3))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent)
                }
            } else if info.isPaused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.holoToolBorder, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.holoToolInset)
            }
            if isToday {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.holoToolText.opacity(0.75), lineWidth: 1.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: 3. 计数型走势图（复用公共件 HoloBarChart）

    private var countBarChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let buckets = countLast10Buckets()
            let hasAny = buckets.contains { $0.value(forSeries: 0) != nil }
            if !hasAny {
                Text(String(localized: "近 10 天还没有记录，记一笔即可看到每日走势。"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .padding(.vertical, 12)
            } else {
                let rules: [HoloChartRule] = {
                    guard let target = row.target?.value, target > 0 else { return [] }
                    let label = String(localized: "目标 \(HabitPresentationProjector.formatValue(target))")
                    return [HoloChartRule(value: target, label: label, color: accent)]
                }()
                HoloBarChart(
                    buckets: buckets,
                    series: [HoloChartSeries(id: "count", title: row.name, color: accent)],
                    selection: $selectedBarId,
                    height: 136,
                    summary: String(localized: "点按或横滑查看每日数值"),
                    valueText: { val in
                        let formatted = HabitPresentationProjector.formatValue(val)
                        return row.unit.isEmpty ? formatted : "\(formatted) \(row.unit)"
                    },
                    defaultSelectsLastBucket: true,
                    xAxisTickStyle: .dayWithMonthAnchor,
                    rules: rules
                )
            }
            footerRow(legend: Text(String(localized: "点按柱体查看当日数值"))
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary))
        }
    }

    private func countLast10Buckets() -> [HoloChartBucket] {
        let valueByDay: [Date: Double] = Dictionary(
            (last30Snapshot?.dailyValues ?? []).map { (calendar.startOfDay(for: $0.date), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let creationDay = last30Snapshot?.creationDay(calendar: calendar)
        let days: [Date] = (0..<10).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: habitToday) else { return nil }
            let dayStart = calendar.startOfDay(for: d)
            if let creationDay, dayStart < creationDay { return nil }
            return dayStart
        }
        return days.map { day in
            HoloChartBucket(
                id: String(Int(day.timeIntervalSince1970)),
                label: HoloChartFormat.date(day),
                detail: HoloChartFormat.date(day, template: "yMMMd"),
                values: [valueByDay[day]],
                date: day
            )
        }
    }

    // MARK: 4. 测量型走势图（复用公共件 HoloMiniTrendChart）

    private var measureTrendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let dailyValues = recentNumericSnapshot?.dailyValues ?? []
            if dailyValues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "还没有测量记录"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.holoToolText)
                    Text(String(localized: "记下第一笔后，趋势与变化会立即显示在这里。"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                .padding(.vertical, 8)
            } else {
                let singlePrefix = (recentNumericSnapshot?.records.count ?? 0) > 1
                    ? String(localized: "当日最新")
                    : String(localized: "唯一记录")
                HoloMiniTrendChart(
                    points: dailyValues.map { .init(date: $0.date, value: $0.value) },
                    color: accent,
                    title: row.name,
                    valueText: { value in
                        let text = HabitPresentationProjector.formatValue(value)
                        return row.unit.isEmpty ? text : "\(text) \(row.unit)"
                    },
                    deltaRisingIsBad: nil,
                    height: 62,
                    singlePointPrefix: singlePrefix
                )
            }
            let caption: String = {
                if dailyValues.count >= 2 {
                    return String(localized: "按真实记录日期排布，断档如实拉开")
                }
                if dailyValues.count == 1 {
                    return String(localized: "按日取最新值 · 再记一天连成走势线")
                }
                return ""
            }()
            footerRow(legend: Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary))
        }
    }

    private var measureRangeText: String? {
        guard let values = recentNumericSnapshot?.dailyValues,
              let first = values.first, let last = values.last,
              !calendar.isDate(first.date, inSameDayAs: last.date) else { return nil }
        return "\(HoloChartFormat.date(first.date)) – \(HoloChartFormat.date(last.date))"
    }

    // MARK: 页脚（图例 + 完整回顾直达）

    private func footerRow<L: View>(legend: L) -> some View {
        HStack(alignment: .center, spacing: 8) {
            legend
            Spacer(minLength: 8)
            Button {
                HapticManager.light()
                onOpenReview()
            } label: {
                HStack(spacing: 2) {
                    Text(String(localized: "完整回顾"))
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func formatMonthDayWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日 EEE")
        return formatter.string(from: date)
    }
}
