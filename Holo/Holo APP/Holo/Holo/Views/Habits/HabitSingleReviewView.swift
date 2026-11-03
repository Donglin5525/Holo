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
    /// 当前选中的趋势柱（周/月）；日历随它翻月
    @State private var snapshot: HabitRangeSnapshot?
    /// 本期 vs 上期对比（方案A：替代旧摘要区，回答「有没有进步」）
    @State private var comparison: HabitPeriodComparison?
    /// 趋势柱（打卡 = 完成率/天数；计数 = 合计）。范围落在一个自然月内时为 nil（直接看日历）
    @State private var trend: HabitTrend?
    /// 全量最近一次测量值（范围内无记录时的大数字回落值，2026-11-02：记录没丢，只是不在本期）
    @State private var latestOverall: (value: Double, day: Date)?
    @State private var selectedBar: HabitTrendBar?
    @State private var sourceRoute: HabitSourceRoute?
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
        // 本页是 ZStack 覆盖层（非 push），右滑返回 = 回顾整体页一层；
        // 容器级「右滑关模块」手势在本页期间已整层失效让位（见 HabitModuleContainer）
        .swipeBackToDismiss { model.reviewRoute = .overview }
        .onAppear {
            if snapshot == nil { initializeState() }
            rebuild()
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            rebuild()
        }
        .sheet(item: $sourceRoute) { route in HabitSourceDetailView(route: route) }
        .sheet(isPresented: $rangeSheetShown) { rangeSheet }
        .sheet(item: $editingRecord) { target in
            if let record = findRecord(target.recordId) {
                HabitRecordEditSheet(
                    record: record,
                    kind: snapshot?.info.kind ?? .checkIn,
                    unit: snapshot?.info.unit
                ) { value, note in
                    await model.record(kind: .updateRecord(recordId: target.recordId,
                                                          value: value, note: note),
                                       habitId: habitId)
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
                rangeRow
                statsLine(snapshot, comparison: comparison)
                    .padding(.top, 10)
                vizSection(snapshot)
                NavigationLink {
                    HabitSourceDetailView(route: HabitSourceRoute(
                        habitID: habitId, start: snapshot.interval.start, endExclusive: snapshot.interval.end))
                } label: {
                    Label(String(localized: "全部记录"), systemImage: "list.bullet")
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                if let day = selectedDay {
                    dayDetailSection(snapshot, day: day)
                        .id(day)
                } else if snapshot.elapsedDays > 0 {
                    Text(String(localized: "选择一个日期，查看那一天的真实记录。"))
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
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
                if let description = habit?.habitDescription {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                headerSubtitle(info)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 14)
    }

    /// 头部副行：只在状态需要说明时出现（暂停/归档），不占位念 slogan
    @ViewBuilder
    private func headerSubtitle(_ info: HabitReviewHabitInfo) -> some View {
        switch info.lifecycle {
        case .paused:
            Text(String(localized: "已暂停 · 历史保留"))
        case .archived:
            Text(String(localized: "已归档 · 历史保留"))
        case .active:
            EmptyView()
        }
    }

    private func iconBox(_ info: HabitReviewHabitInfo) -> some View {
        let color = Color(hex: info.colorHex)
        return SnapshotIconBox(icon: info.icon, isCustomIcon: info.isCustomIcon, color: color)
    }

    // MARK: 范围（灰轨白块分段，§8.8.3 唯一样式；其余范围走「···」弹层）

    /// 从整体页继承的是过去月：分段首位插入该月（选中态），点快捷档即回
    private var inheritedPastMonth: Date? {
        if case .month(let monthStart) = selectedRange {
            let calendar = Calendar.current
            let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
            if !calendar.isDate(monthStart, equalTo: current, toGranularity: .month) {
                return monthStart
            }
        }
        return nil
    }

    private var quickRanges: [HabitReviewRange] {
        var ranges: [HabitReviewRange] = []
        if let pastMonth = inheritedPastMonth { ranges.append(.month(pastMonth)) }
        ranges.append(.month(currentMonthStart))
        if snapshot?.info.kind == .checkIn {
            ranges.append(.lastDays(30))
            ranges.append(.lastDays(90))
        } else {
            ranges.append(.recentRecords(count: HabitReviewRange.defaultRecentCount))
        }
        ranges.append(.all)
        return ranges
    }

    private var rangeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(quickRanges.indices, id: \.self) { index in
                        rangeSegment(quickRanges[index])
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.holoToolInset))
                Button {
                    rangeSheetShown = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.holoToolBorder.opacity(0.7))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "选范围")))
                .accessibilityIdentifier("habit.single.range.more")
            }
            Text(rangeDatesText)
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
        }
        .padding(.top, 4)
    }

    private func rangeSegment(_ range: HabitReviewRange) -> some View {
        let selected = selectedRange == range
        return Button {
            applyRange(range)
        } label: {
            Text(rangeShortTitle(range))
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .holoToolText : .holoToolTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Color.holoToolSurface : .clear)
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1.5, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(rangeAXId(range))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 范围行日期：本月 =「11月」；过去月 =「2026年10月」；其余 =「M月d日 – M月d日」（全部从创建日起）
    private var rangeDatesText: String {
        let calendar = Calendar.current
        if case .month(let monthStart) = selectedRange {
            return calendar.isDate(monthStart, equalTo: model.projectionNow, toGranularity: .month)
                ? monthOnlyText(monthStart) : monthText(monthStart)
        }
        guard let snapshot else { return "" }
        let start = HabitReviewProjector.effectiveStart(snapshot, calendar: calendar)
        // 「最近记录」的区间终点是最后记录日（interval.end 是明天零点的占位，写出来会和横轴对不上）
        let end: Date
        if case .recentRecords = selectedRange, let last = snapshot.dailyValues.last?.date {
            end = last
        } else {
            end = calendar.date(byAdding: .day, value: -1, to: snapshot.interval.end) ?? snapshot.interval.end
        }
        var text = "\(mdText(start)) – \(mdText(end))"
        if case .recentRecords(let count) = selectedRange {
            text = String(localized: "最近 \(min(count, snapshot.dailyValues.count)) 次 · ") + text
        }
        return text
    }

    private func rangeShortTitle(_ range: HabitReviewRange) -> String {
        switch range {
        case .month(let monthStart):
            return Calendar.current.isDate(monthStart, equalTo: model.projectionNow, toGranularity: .month)
                ? String(localized: "本月") : monthOnlyText(monthStart)
        case .lastDays(let days): return String(localized: "近\(days)天")
        case .recentRecords: return String(localized: "最近记录")
        case .all: return String(localized: "全部")
        case .custom: return String(localized: "自定义")
        }
    }

    private func rangeAXId(_ range: HabitReviewRange) -> String {
        switch range {
        case .month: return "habit.single.range.month"
        case .lastDays(30): return "habit.single.range.d30"
        case .lastDays(90): return "habit.single.range.d90"
        case .lastDays: return "habit.single.range.days"
        case .recentRecords: return "habit.single.range.recent"
        case .all: return "habit.single.range.all"
        case .custom: return "habit.single.range.custom"
        }
    }

    // MARK: 统计行（每个数字直接回答一个问题）

    @ViewBuilder
    private func statsLine(_ snapshot: HabitRangeSnapshot, comparison: HabitPeriodComparison?) -> some View {
        HStack(alignment: .bottom) {
            currentStat(snapshot, comparison: comparison)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                secondaryStat(snapshot, comparison: comparison)
                if let comparison, let text = previousStatText(snapshot, comparison: comparison) {
                    Text(text)
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
        }
    }

    /// 左侧主数字
    @ViewBuilder
    private func currentStat(_ snapshot: HabitRangeSnapshot, comparison: HabitPeriodComparison?) -> some View {
        let info = snapshot.info
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            switch info.kind {
            case .checkIn:
                Text(verbatim: "\(snapshot.recordedDayCount)")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Text(info.isBadHabit
                    ? String(localized: "天发生")
                    : String(localized: "/ \(comparison?.current.validDays ?? snapshot.elapsedDays) 天"))
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            case .count:
                Text(verbatim: HabitPresentationProjector.formatValue(snapshot.countTotal ?? 0))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Text(info.unit.isEmpty ? String(localized: "合计") : String(localized: "合计 \(info.unit)"))
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            case .measure:
                Text(verbatim: measureMainValue(snapshot))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Text(verbatim: measureMainUnit(snapshot))
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
    }

    /// 右侧数字：打卡完成率 / 计数日均 / 测量变化
    @ViewBuilder
    private func secondaryStat(_ snapshot: HabitRangeSnapshot, comparison: HabitPeriodComparison?) -> some View {
        let info = snapshot.info
        switch info.kind {
        case .checkIn where info.frequency == .daily && !info.isBadHabit:
            if let completion = comparison?.current.completion {
                statValue("\(Int((completion * 100).rounded()))%", caption: String(localized: "完成率"))
            }
        case .checkIn:
            EmptyView()
        case .count:
            let days = max(snapshot.elapsedDays, 1)
            statValue(HabitPresentationProjector.formatValue((snapshot.countTotal ?? 0) / Double(days)),
                      caption: String(localized: "日均 \(info.unit)"))
        case .measure:
            if let change = measureChange(snapshot) {
                statValue(HabitPresentationProjector.formatValue(abs(change)) + (info.unit.isEmpty ? "" : " \(info.unit)"),
                          caption: String(localized: change > 0 ? "涨了" : "降了"))
            }
        }
    }

    private func statValue(_ value: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: caption)
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
            Text(verbatim: value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.holoToolText)
        }
    }

    /// 上期对比（上期没有有效天不比；「全部」不比）
    private func previousStatText(_ snapshot: HabitRangeSnapshot,
                                  comparison: HabitPeriodComparison) -> String? {
        guard let previous = comparison.previous else { return nil }
        let info = snapshot.info
        switch info.kind {
        case .checkIn where info.frequency == .daily && !info.isBadHabit:
            guard let completion = previous.completion else { return nil }
            return String(localized: "\(comparison.previousLabel) \(Int((completion * 100).rounded()))%")
        case .checkIn:
            return String(localized: "\(comparison.previousLabel) \(previous.recordedDays) 天")
        case .count:
            guard let total = previous.countTotal else { return nil }
            let text = HabitPresentationProjector.formatValue(total)
            return String(localized: "\(comparison.previousLabel) \(text)\(info.unit.isEmpty ? "" : " \(info.unit)")")
        case .measure:
            guard let average = previous.measureAverage else { return nil }
            let text = HabitPresentationProjector.formatValue(average)
            return String(localized: "\(comparison.previousLabel) \(text)\(info.unit.isEmpty ? "" : " \(info.unit)")")
        }
    }

    // MARK: 测量型数字口径（最近一次 + 变化）

    /// 大数字 = 最近一次测量值；范围内无记录时回落到全量最近一次（记录没丢，只是不在本期）
    private func measureMainValue(_ snapshot: HabitRangeSnapshot) -> String {
        let latest = snapshot.latestMeasure ?? latestOverall
        return latest.map { HabitPresentationProjector.formatValue($0.value) } ?? "—"
    }

    private func measureMainUnit(_ snapshot: HabitRangeSnapshot) -> String {
        guard let latest = snapshot.latestMeasure ?? latestOverall else { return "" }
        let unit = snapshot.info.unit.isEmpty ? "" : snapshot.info.unit
        let calendar = Calendar.current
        let dayText = "\(calendar.component(.month, from: latest.day))/\(calendar.component(.day, from: latest.day))"
        return unit.isEmpty ? dayText : "\(unit) · \(dayText)"
    }

    /// 变化 = 范围内最早 → 最晚之差（至少 2 个不同的日子才有）
    private func measureChange(_ snapshot: HabitRangeSnapshot) -> Double? {
        guard let first = snapshot.dailyValues.first, let last = snapshot.dailyValues.last,
              first.date != last.date else { return nil }
        return last.value - first.value
    }

    private func monthOnlyText(_ month: Date) -> String {
        String(localized: "\(Calendar.current.component(.month, from: month))月")
    }

    private func mdText(_ date: Date) -> String {
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private func monthText(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
        return formatter.string(from: month)
    }

    private var summarySeparator: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(height: 0.5)
    }

    // MARK: 可视化（打卡 = 趋势柱 + 日历常驻；数值 = 趋势 | 日历 切换）

    @ViewBuilder
    private func vizSection(_ snapshot: HabitRangeSnapshot) -> some View {
        if snapshot.info.kind == .checkIn {
            VStack(alignment: .leading, spacing: 8) {
                if let trend {
                    trendChartSection(trend, info: snapshot.info)
                }
                calendarView(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(snapshot.info.kind == .count ? amountTrendTitle
                                                        : numericChartTitle(snapshot.info))
                        .holoText(.supporting)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    vizSwitch
                }
                .padding(.top, 10)
                if vizMode == .trend {
                    numericTrendView(snapshot)
                } else {
                    calendarView(snapshot)
                }
            }
        }
    }

    /// 打卡型趋势标题
    private var trendTitle: String {
        guard let trend else { return "" }
        switch (trend.mode, trend.granularity) {
        case (.completionRate, .week): return String(localized: "每周完成率")
        case (.completionRate, .month): return String(localized: "每月完成率")
        case (.weeklyDays, .week): return String(localized: "每周记录天数")
        case (.weeklyDays, .month): return String(localized: "每月记录天数")
        case (_, .day): return String(localized: "每天")
        case (.amount, _): return ""   // 计数型走 amountTrendTitle
        }
    }

    /// 计数型趋势标题（跟粒度走，量词用习惯自己的单位）
    private var amountTrendTitle: String {
        guard let trend, let info = snapshot?.info else { return "" }
        let unit = info.unit.isEmpty ? "" : "（\(info.unit)）"
        switch trend.granularity {
        case .day: return String(localized: "每天\(unit)")
        case .week: return String(localized: "每周\(unit)")
        case .month: return String(localized: "每月\(unit)")
        }
    }

    private func trendChartSection(_ trend: HabitTrend, info: HabitReviewHabitInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trendTitle)
                .holoText(.supporting)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)
                .padding(.top, 10)
            HabitTrendBarChart(trend: trend, color: Color(hex: info.colorHex), unit: info.unit) { bar in
                selectBar(bar)
            }
        }
    }

    private func selectBar(_ bar: HabitTrendBar) {
        selectedBar = bar
        // 日历联动：周柱看周四所在月、月/日柱看柱首月
        let calendar = Calendar.current
        let anchor = trend?.granularity == .week
            ? (calendar.date(byAdding: .day, value: 3, to: bar.start) ?? bar.start)
            : bar.start
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) ?? calendarMonth
        if month != calendarMonth { calendarMonth = month }
    }

    /// 数值型图表标题：计数用习惯自己的单位说话，测量直接用习惯名
    private func numericChartTitle(_ info: HabitReviewHabitInfo) -> String {
        if info.kind == .count {
            return info.unit.isEmpty ? String(localized: "每天") : String(localized: "每天（\(info.unit)）")
        }
        return info.unit.isEmpty ? info.name : String(localized: "\(info.name)（\(info.unit)）")
    }

    /// 趋势 / 日历 互斥切换（灰轨白块，与范围分段同一语言）
    private var vizSwitch: some View {
        HStack(spacing: 0) {
            vizSegment(String(localized: "趋势"), active: vizMode == .trend) {
                if vizMode != .trend { vizMode = .trend }
            }
            vizSegment(String(localized: "日历"), active: vizMode == .calendar) {
                if vizMode != .calendar { vizMode = .calendar }
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.holoToolInset))
    }

    private func vizSegment(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .holoToolText : .holoToolTextSecondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.holoToolSurface : .clear)
                        .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1.5, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
    // MARK: 日历

    private func calendarView(_ snapshot: HabitRangeSnapshot) -> some View {
        VStack(spacing: 8) {
            if case .month = selectedRange {
                // 月范围：日历就是这个月（范围行已写明月份；补顶距，别贴着统计行）
                Color.clear.frame(height: 16)
            } else {
                // 跨月范围：范围内翻月（只改显示月，不改统计范围）
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
                Circle().fill(Color.holoToolBorder.opacity(0.7)).frame(width: 4, height: 4)
                Text(String(localized: "未记录"))
            }
            HStack(spacing: 4) {
                Rectangle().fill(Color.holoToolTextSecondary.opacity(0.45)).frame(width: 6, height: 1)
                Text(String(localized: "暂停"))
            }
        }
        .font(.system(size: 12))
        .foregroundColor(.holoToolTextSecondary)
    }

    // MARK: 数值型趋势（计数 = 柱；测量 = 点线；横轴首尾 = 所选范围）

    @ViewBuilder
    private func numericTrendView(_ snapshot: HabitRangeSnapshot) -> some View {
        if snapshot.info.kind == .count {
            if let trend {
                HabitTrendBarChart(trend: trend, color: Color(hex: snapshot.info.colorHex),
                                   unit: snapshot.info.unit) { bar in
                    selectBar(bar)
                }
            } else {
                Text(numericEmptyTitle(snapshot))
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        } else if snapshot.dailyValues.isEmpty {
            VStack(spacing: 10) {
                Text(numericEmptyTitle(snapshot))
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                if let latest = latestOverall {
                    Button {
                        onGoTodayRecord(habitId)
                    } label: {
                        Text(String(localized: "记一记"))
                            .holoText(.supporting)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoToolAction)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            MeasureTrendChart(snapshot: snapshot, now: model.projectionNow, selectedDay: selectedDay) { day in
                selectDay(day)
            }
        }
    }

    private func numericEmptyTitle(_ snapshot: HabitRangeSnapshot) -> String {
        if case .month = selectedRange { return String(localized: "这个月还没有记录") }
        return String(localized: "这个范围还没有记录")
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
                                 ? String(localized: "补录这一天")
                                 : String(localized: "补录这一天"))
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

    // MARK: 选范围弹层（快捷档之外的范围；§8.8 统一壳）

    private struct RangeSheet: View {
        let currentRange: HabitReviewRange
        var onPick: (HabitReviewRange) -> Void
        var onDismiss: () -> Void

        @State private var customStart = Date()
        @State private var customEnd = Date()

        private var today: Date { Calendar.current.startOfDay(for: Date()) }
        private var lastMonth: Date {
            let calendar = Calendar.current
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            return calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? today
        }
        private var yearStart: Date {
            let calendar = Calendar.current
            return calendar.date(from: calendar.dateComponents([.year], from: today)) ?? today
        }
        private var customValid: Bool {
            let calendar = Calendar.current
            let s = calendar.startOfDay(for: customStart)
            let e = calendar.startOfDay(for: customEnd)
            return s <= e && e <= today
        }

        var body: some View {
            HoloSheetScaffold(
                title: String(localized: "选范围"),
                onClose: onDismiss,
                primaryTitle: String(localized: "用这个范围"),
                primaryAction: customValid
                    ? { onPick(.custom(start: Calendar.current.startOfDay(for: customStart),
                                      end: Calendar.current.startOfDay(for: customEnd))) }
                    : nil,
                primaryDisabled: !customValid
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    quickOption(String(localized: "上个月"), for: .month(lastMonth))
                    quickOption(String(localized: "今年"), for: .custom(start: yearStart, end: today))

                    Text(String(localized: "自定义"))
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.top, 10)
                    HStack(spacing: 10) {
                        datePicker(String(localized: "开始"), selection: $customStart)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13))
                            .foregroundColor(.holoToolTextSecondary)
                        datePicker(String(localized: "结束"), selection: $customEnd)
                    }
                    if !customValid {
                        Text(String(localized: "开始要早于结束，且不能选未来"))
                            .holoText(.metadata)
                            .foregroundColor(.holoToolError)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            }
            .presentationDetents([.height(420)])
            .onAppear {
                // 自定义默认值 = 最近 30 天（dateInterval 对「最近记录」返回 distantPast 占位，
                // 直接取会落到两年前，2026-11-03 判读实锤）
                let calendar = Calendar.current
                customEnd = today
                customStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            }
        }

        private func quickOption(_ title: String, for range: HabitReviewRange) -> some View {
            Button {
                onPick(range)
            } label: {
                HStack {
                    Text(title)
                        .holoText(.body)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    if currentRange == range {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoToolAction)
                    }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private func datePicker(_ label: String, selection: Binding<Date>) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                DatePicker(label, selection: selection,
                           in: ...today, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rangeSheet: some View {
        RangeSheet(currentRange: selectedRange) { range in
            rangeSheetShown = false
            applyRange(range)
        } onDismiss: {
            rangeSheetShown = false
        }
    }

    private var currentMonthStart: Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    private func applyRange(_ range: HabitReviewRange) {
        selectedRange = range
        selectedDay = nil
        selectedBar = nil
        rangeSheetShown = false
        // 日历默认看范围里最近的月份（.all 的首日是公元 1 年，按首月归位会翻到空白月）
        let calendar = Calendar.current
        let rangeEnd = range.dateInterval(now: model.projectionNow, calendar: calendar).end
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: rangeEnd))
            ?? calendarMonth
        calendarMonth = min(endMonth, currentMonthStart)
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
            dayEndMinutesByHabit: [habitId: habit.dayEndMinutes],
            now: model.projectionNow
        )
        return HabitPresentationProjector.retroactiveMode(habit: habit, day: day, data: data)
    }

    /// 不可补的原因说明（§7.3：说明原因，不给无响应按钮）；「今天」按习惯结算时间
    private func ineligibleReason(_ day: Date, info: HabitReviewDay) -> String? {
        let dayStart = Calendar.current.startOfDay(for: day)
        let todayStart = habit?.currentDay(now: model.projectionNow)
            ?? Calendar.current.startOfDay(for: model.projectionNow)
        guard dayStart < todayStart else {
            return dayStart > todayStart ? String(localized: "未来日期不可记录") : nil
        }
        if info.isBeforeCreation { return String(localized: "习惯创建前不可补录") }
        if info.isPaused { return String(localized: "暂停日不算漏签") }
        guard let habit else { return nil }
        if habit.isBadHabit { return String(localized: "这个减少的习惯不支持补录") }
        return nil
    }

    // MARK: 数据

    private struct RecordTarget: Identifiable {
        let recordId: UUID
        var id: UUID { recordId }
    }

    private func initializeState() {
        guard let habit else { return }
        if let entryRange = model.singleReviewEntryRange {
            selectedRange = entryRange
            model.singleReviewEntryRange = nil
        } else {
            // 数值型默认「最近记录」（低频记录也在一屏内），打卡型维持本月月历
            selectedRange = model.defaultSingleReviewRange(isCheckIn: habit.isCheckInType)
        }
        vizMode = habit.isCheckInType ? .calendar : .trend
        calendarMonth = model.overviewMonth
    }

    private func rebuild() {
        guard let habit else { return }
        let info = HabitReviewHabitInfo(habit: habit, lifecycle: lifecycle)
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([habitId]),
            dayEndMinutesByHabit: [habitId: habit.dayEndMinutes],
            now: model.projectionNow
        )
        let snap = HabitReviewProjector.rangeSnapshot(info: info, range: selectedRange, data: data)
        snapshot = snap
        comparison = HabitReviewProjector.periodComparison(snapshot: snap, data: data)
        switch info.kind {
        case .checkIn: trend = HabitReviewProjector.checkInTrend(snapshot: snap, data: data)
        case .count: trend = HabitReviewProjector.countTrend(snapshot: snap, data: data)
        case .measure: trend = nil
        }
        // 测量型大数字的回落值：全量最近一次（范围内没记时也说得出上次是多少）
        if info.kind == .measure {
            let allSnap = HabitReviewProjector.rangeSnapshot(info: info, range: .all, data: data)
            latestOverall = allSnap.latestMeasure.map { (value: $0.value, day: $0.day) }
        } else {
            latestOverall = nil
        }
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

// MARK: - 趋势柱图（打卡完成率/天数、计数合计；财务图表套件同款画法）

/// 与财务图表同一套几何与交互规则：柱宽同参封顶、X 刻度 chartOverlay 自绘、
/// 拖动/点按沿途选中；默认选中最后一根（最近一期先说话，2026-11-02 轴即范围整改）
struct HabitTrendBarChart: View {
    let trend: HabitTrend
    let color: Color
    var unit: String = ""
    var onInspect: (HabitTrendBar) -> Void

    @State private var selection: String?

    private var isRate: Bool { trend.mode == .completionRate }
    private var isAmount: Bool { trend.mode == .amount }

    private var series: [HoloChartSeries] {
        [.init(id: "habit",
               title: trend.granularity == .day || isAmount
                   ? String(localized: "合计")
                   : (isRate ? String(localized: "完成率") : String(localized: "记录")),
               color: color)]
    }

    private var buckets: [HoloChartBucket] {
        trend.bars.map { bar in
            HoloChartBucket(
                id: String(bar.start.timeIntervalSince1970),
                label: axisLabel(bar.start),
                detail: readoutLabel(bar),
                values: [value(for: bar)],
                isFuture: bar.isFuture
            )
        }
    }

    private func value(for bar: HabitTrendBar) -> Double? {
        if trend.granularity == .day || isAmount { return bar.total }
        if isRate { return bar.fraction.map { $0 * 100 } }
        return bar.days > 0 ? Double(bar.recordedDays) : nil
    }

    private func axisLabel(_ date: Date) -> String {
        switch trend.granularity {
        case .day, .week:
            return HoloChartFormat.date(date)
        case .month:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("M月")
            return formatter.string(from: date)
        }
    }

    /// 读数小字：周/月写起止与分母（「10/26 – 11/1 · 7/7 天」），天写整日
    private func readoutLabel(_ bar: HabitTrendBar) -> String {
        switch trend.granularity {
        case .day:
            return HoloChartFormat.date(bar.start, template: "yMEd")
        case .week:
            let calendar = Calendar.current
            let last = calendar.date(byAdding: .day, value: -1, to: bar.end) ?? bar.start
            return "\(HoloChartFormat.date(bar.start)) – \(HoloChartFormat.date(last)) · \(bar.recordedDays)/\(bar.days) \(String(localized: "天"))"
        case .month:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("y年M月")
            return "\(formatter.string(from: bar.start)) · \(bar.recordedDays)/\(bar.days) \(String(localized: "天"))"
        }
    }

    private var yDomain: ClosedRange<Double>? {
        switch (trend.mode, trend.granularity) {
        case (.completionRate, _): return 0...100
        case (.weeklyDays, .week): return 0...7
        case (.weeklyDays, .month): return 0...31
        case (.amount, _), (_, .day): return nil
        }
    }

    var body: some View {
        HoloBarChart(
            buckets: buckets,
            series: series,
            selection: $selection,
            height: 140,
            yDomain: yDomain,
            summary: "",
            summaryValues: isRate ? [nil] : nil,
            valueText: { value in
                if trend.granularity == .day || isAmount {
                    return HabitPresentationProjector.formatValue(value)
                        + (unit.isEmpty ? "" : " \(unit)")
                }
                if isRate { return "\(Int(value.rounded()))%" }
                return "\(Int(value)) \(String(localized: "天"))"
            },
            defaultSelectsLastBucket: true,
            slotTicks: trend.granularity == .day
                ? mondayTickIndices
                : (trend.granularity == .month ? Array(trend.bars.indices) : nil),
            onInspect: { bucket in
                if let bar = trend.bars.first(where: { String($0.start.timeIntervalSince1970) == bucket.id }) {
                    onInspect(bar)
                }
            }
        )
    }

    /// 按天粒度的刻度统一放每周一（与回顾日历周一首列同语言）；最后一天若不是周一也补一枚，
    /// 柱子永远对准自己的日期（2026-11-03 判读实锤：等分索引刻度会把「11/2」读成「11/1」）
    private var mondayTickIndices: [Int] {
        let calendar = Calendar.current
        var result: [Int] = []
        for (index, bar) in trend.bars.enumerated()
        where calendar.component(.weekday, from: bar.start) == 2 {
            result.append(index)
        }
        if let last = trend.bars.indices.last, result.last != last {
            result.append(last)
        }
        return result
    }
}

// MARK: - 测量型点线（横轴首尾 = 所选范围；点按真实日期落位）

struct MeasureTrendChart: View {
    let snapshot: HabitRangeSnapshot
    let now: Date
    var selectedDay: Date?
    var onSelectDay: (Date) -> Void

    @State private var selection: String?

    private var calendar: Calendar { .current }

    private var axis: (start: Date, dayCount: Int) {
        HabitReviewProjector.measureAxis(snapshot: snapshot, calendar: calendar)
    }

    private var buckets: [HoloChartBucket] {
        guard axis.dayCount > 0 else { return [] }
        return snapshot.dailyValues.map { daily in
            let day = calendar.startOfDay(for: daily.date)
            let offset = calendar.dateComponents([.day], from: axis.start, to: day).day ?? 0
            return HoloChartBucket(
                id: String(day.timeIntervalSince1970),
                label: HoloChartFormat.date(day),
                detail: HoloChartFormat.date(day, template: "yMEd"),
                values: [daily.value],
                position: Double(max(offset, 0))
            )
        }
    }

    /// 横轴 = 范围首尾；单点时以点为中心留一天
    private var domain: ClosedRange<Double> {
        let upper = Double(max(axis.dayCount - 1, 0))
        return upper == 0 ? -1...1 : 0...upper
    }

    private var ticks: [HoloChartTick] {
        var result = [HoloChartTick(position: domain.lowerBound, label: HoloChartFormat.date(axis.start))]
        let lastDay = calendar.date(byAdding: .day, value: axis.dayCount - 1, to: axis.start) ?? axis.start
        if axis.dayCount > 1 {
            result.append(HoloChartTick(position: domain.upperBound, label: HoloChartFormat.date(lastDay)))
        }
        if axis.dayCount > 45 {
            let middle = calendar.date(byAdding: .day, value: axis.dayCount / 2, to: axis.start) ?? lastDay
            result.insert(HoloChartTick(position: Double(axis.dayCount / 2), label: HoloChartFormat.date(middle)),
                          at: 1)
        }
        return result
    }

    var body: some View {
        HoloLineChart(
            buckets: buckets,
            series: [.init(id: "habit", title: snapshot.info.name, color: Color(hex: snapshot.info.colorHex))],
            selection: $selection,
            height: 160,
            summary: "",
            valueText: { value in
                HabitPresentationProjector.formatValue(value)
                    + (snapshot.info.unit.isEmpty ? "" : " \(snapshot.info.unit)")
            },
            defaultSelectsLastBucket: true,
            alwaysShowPoints: true,
            positionDomain: domain,
            positionTicks: ticks,
            onInspect: { bucket in
                if let timestamp = Double(bucket.id) {
                    onSelectDay(Date(timeIntervalSince1970: timestamp))
                }
            }
        )
        .onChange(of: selectedDay) { _, day in
            selection = day.map { String(calendar.startOfDay(for: $0).timeIntervalSince1970) }
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
                    // 暂停：小横线（与图例同语言；整排「休」字曾把月历下半打成死灰）
                    Rectangle()
                        .fill(Color.holoToolTextSecondary.opacity(0.45))
                        .frame(width: 6, height: 1.5)
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
        } else if !info.isFuture && !info.isBeforeCreation {
            // 真实未记录日才画灰点；未来与创建前留干净空格
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
        HoloChartGeometry.bucketIndex(x: touchXInPlot, width: plotWidth, count: dayCount, clamped: true)
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

    /// 测量型记录点布局（position 域）：只建记录日桶、按距首记录日的天数定位。
    /// 桶全为有效值 → 折线一条贯通，断档在时间轴上如实留白（旧「一天一槽」画法
    /// 在断续记录下连线压成竖线、孤点断线，2026-10-26 东林「乱糟糟」实锤）；
    /// 命中按最近记录点，不会再落到空日子触发「补录这一天」
    static func measurePositions(values: [HabitDailyNumericValue], calendar: Calendar) -> (start: Date, positions: [Double]) {
        guard let first = values.first else { return (calendar.startOfDay(for: Date()), []) }
        let start = calendar.startOfDay(for: first.date)
        let positions = values.map { value -> Double in
            let offset = calendar.dateComponents([.day], from: start, to: value.date).day ?? 0
            return Double(max(offset, 0))
        }
        return (start, positions)
    }

    /// 图域（起日 + 天数）。月/近 N 天保持完整范围（空槽如实留白，末日不超今天）；
    /// 超长范围（全部记录/多年自定义）收敛到首末记录日，否则一天一槽细到不可读。
    /// `sparseCollapse`（概览弹层等稀疏场景）：记录跨度 ≤6 天时同样收敛到首末记录日
    /// 并前后各留 1 天呼吸位（末日不越今天、至少 3 槽）——30 个槽里孤零零一根
    /// 细柱/一个点既难看又没信息量（2026-10-11 东林实报「细细长长一条」）。
    static func chartRange(interval: DateInterval, today: Date,
                           values: [HabitDailyNumericValue], calendar: Calendar,
                           sparseCollapse: Bool = false) -> (start: Date, dayCount: Int) {
        let nominalStart = calendar.startOfDay(for: interval.start)
        let rangeEndDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let nominalEnd = min(calendar.startOfDay(for: rangeEndDay), calendar.startOfDay(for: today))
        let spanDays = calendar.dateComponents([.day], from: nominalStart, to: nominalEnd).day ?? 0
        let valueDays = values.map { calendar.startOfDay(for: $0.date) }
        if spanDays > 366 {
            let first = valueDays.min() ?? nominalStart
            let last = max(valueDays.max() ?? nominalEnd, first)
            let count = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            return (first, max(count, 1))
        }
        if sparseCollapse, let first = valueDays.min(), let last = valueDays.max() {
            let span = calendar.dateComponents([.day], from: first, to: last).day ?? 0
            if span <= 6 {
                let todayStart = calendar.startOfDay(for: today)
                var start = calendar.date(byAdding: .day, value: -1, to: first) ?? first
                var end = min(calendar.date(byAdding: .day, value: 1, to: last) ?? last, todayStart)
                let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
                if count < 3 {
                    // 末日已顶到今天（如只有今天一条记录）：向前补足 3 槽
                    end = max(end, start)
                    start = calendar.date(byAdding: .day, value: -2, to: end) ?? start
                }
                let padded = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
                return (start, max(padded, 3))
            }
        }
        return (nominalStart, max(spanDays, 0) + 1)
    }
}
