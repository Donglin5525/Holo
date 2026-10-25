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
    @State private var snapshot: HabitRangeSnapshot?
    /// 本期 vs 上期对比（方案A：替代旧摘要区，回答「有没有进步」）
    @State private var comparison: HabitPeriodComparison?
    /// 打卡型每周走势（方案A：打卡型第一次有走势图）
    @State private var weeklyTrend: (mode: HabitWeeklyTrendMode, bars: [HabitWeeklyBar])?
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
                rangeChips
                Button("记录明细与每日确认") {
                    sourceRoute = HabitSourceRoute(habitID: habitId, start: snapshot.interval.start, endExclusive: snapshot.interval.end)
                }.holoText(.supporting).frame(minHeight: 44).foregroundStyle(Color.holoToolAction)
                if let comparison {
                    periodCompareCard(comparison, info: snapshot.info)
                        .padding(.top, 14)
                }
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

    // MARK: 范围切换（2026-10-13 整改：内联一排胶囊点一下即切，删掉弹窗滚轮）

    /// 快捷档（行首动态插入「过去月」胶囊：从回顾整体页带月份进来时不丢上下文）
    private var quickRanges: [HabitReviewRange] {
        [.month(currentMonthStart), .lastDays(30), .lastDays(90), .all]
    }

    private func isQuickRangeSelected(_ range: HabitReviewRange) -> Bool {
        selectedRange == range
    }

    /// 从整体页继承的是过去月：行首插入该月胶囊（选中态），点快捷档即回
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

    private var rangeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let pastMonth = inheritedPastMonth {
                    rangeChip(monthText(pastMonth), selected: true) {
                        rangeSheetShown = true
                    }
                    .accessibilityIdentifier("habit.single.range.past")
                }
                rangeChip(String(localized: "本月"), selected: isQuickRangeSelected(.month(currentMonthStart))) {
                    applyRange(.month(currentMonthStart))
                }
                .accessibilityIdentifier("habit.single.range.month")
                rangeChip(String(localized: "近30天"), selected: isQuickRangeSelected(.lastDays(30))) {
                    applyRange(.lastDays(30))
                }
                .accessibilityIdentifier("habit.single.range.d30")
                rangeChip(String(localized: "近90天"), selected: isQuickRangeSelected(.lastDays(90))) {
                    applyRange(.lastDays(90))
                }
                .accessibilityIdentifier("habit.single.range.d90")
                rangeChip(String(localized: "全部"), selected: isQuickRangeSelected(.all)) {
                    applyRange(.all)
                }
                .accessibilityIdentifier("habit.single.range.all")
                Button {
                    rangeSheetShown = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Capsule().strokeBorder(Color.holoToolBorder.opacity(0.7))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "更多范围")))
                .accessibilityIdentifier("habit.single.range.more")
            }
            .padding(.vertical, 2)
        }
        .padding(.top, 4)
    }

    private func rangeChip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .holoPrimary : .holoToolTextSecondary)
                .padding(.horizontal, 13)
                .frame(minHeight: 34)
                .background(
                    Capsule().fill(selected ? Color.holoPrimary.opacity(0.14) : Color.holoToolInset)
                )
                .overlay(
                    Capsule().strokeBorder(selected ? Color.holoPrimary.opacity(0.5) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(HoloPressStyle())
    }

    private func monthText(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yyyy年M月")
        return formatter.string(from: month)
    }

    // MARK: 本期 vs 上期对比卡（2026-10-13 整改瘦身：两行结构，删装饰性迷你折线）

    private var summarySeparator: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(height: 0.5)
    }

    @ViewBuilder
    private func periodCompareCard(_ comparison: HabitPeriodComparison, info: HabitReviewHabitInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(compareCaption(comparison, info: info))
                .font(.system(size: 10.5))
                .foregroundColor(.holoToolTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compareMainValue(comparison, info: info))
                    .font(.system(size: 21, weight: .semibold).monospacedDigit())
                    .foregroundColor(.holoToolText)
                if let delta = compareDelta(comparison, info: info) {
                    Text(delta.text)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(delta.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(delta.color.opacity(0.14)))
                }
                Spacer(minLength: 4)
                Text(compareSubline(comparison, info: info))
                    .font(.system(size: 11))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { summarySeparator }
        .overlay(alignment: .bottom) { summarySeparator }
        .accessibilityElement(children: .combine)
    }

    /// 标题行：「本月 vs 上月同期」/「最近 30 天 vs 前 30 天」
    private func compareCaption(_ comparison: HabitPeriodComparison, info: HabitReviewHabitInfo) -> String {
        let currentLabel: String
        if case .month(let monthStart) = selectedRange {
            let calendar = Calendar.current
            let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
            currentLabel = calendar.isDate(monthStart, equalTo: current, toGranularity: .month)
                ? String(localized: "本月") : String(localized: "该月")
        } else {
            currentLabel = selectedRange.label(now: model.projectionNow, calendar: .current)
        }
        guard comparison.previous != nil else {
            return currentLabel
        }
        return "\(currentLabel) vs \(comparison.previousLabel)"
    }

    /// 主数字：打卡=记录天数 / 计数=累计 / 测量=均值
    private func compareMainValue(_ comparison: HabitPeriodComparison, info: HabitReviewHabitInfo) -> String {
        switch info.kind {
        case .checkIn:
            let noun = info.isBadHabit ? String(localized: "发生") : String(localized: "记录")
            return "\(noun) \(comparison.current.recordedDays) \(String(localized: "天"))"
        case .count:
            let total = HabitPresentationProjector.formatValue(comparison.current.countTotal ?? 0)
            return info.unit.isEmpty ? total : "\(total) \(info.unit)"
        case .measure:
            guard let avg = comparison.current.measureAverage else { return "—" }
            let text = HabitPresentationProjector.formatValue(avg)
            return info.unit.isEmpty ? text : "\(text) \(info.unit)"
        }
    }

    /// 变化胶囊：好习惯升=绿、坏习惯降=绿；测量型只标方向不判好坏（增减目标因人而异）
    private func compareDelta(_ comparison: HabitPeriodComparison, info: HabitReviewHabitInfo) -> (text: String, color: Color)? {
        guard let previous = comparison.previous else { return nil }
        let good = Color(hex: "#5BC98A")
        let bad = Color(hex: "#F27A7A")
        let neutral = Color.holoToolText
        func capsule(_ value: Double, _ text: String) -> (String, Color)? {
            guard abs(value) > 0.0001 else { return nil }
            let isGoodDirection = info.isBadHabit ? value < 0 : value > 0
            let color: Color = info.kind == .measure ? neutral : (isGoodDirection ? good : bad)
            return (text, color)
        }
        switch info.kind {
        case .checkIn:
            if info.frequency == .daily && !info.isBadHabit,
               let cur = comparison.current.completion, let prev = previous.completion {
                let diff = (cur - prev) * 100
                return capsule(diff, String(localized: "\(diff >= 0 ? "↑" : "↓") \(Int(abs(diff).rounded()))%"))
            }
            let diff = Double(comparison.current.recordedDays - previous.recordedDays)
            return capsule(diff, String(localized: "\(diff >= 0 ? "↑" : "↓") \(Int(abs(diff))) \(String(localized: "天"))"))
        case .count:
            guard let curTotal = comparison.current.countTotal, let prevTotal = previous.countTotal else { return nil }
            let curRate = dailyRate(curTotal, days: comparison.current.validDays)
            let prevRate = dailyRate(prevTotal, days: previous.validDays)
            let diff = curRate - prevRate
            guard abs(diff) > 0.05 else { return nil }
            let text = HabitPresentationProjector.formatValue(abs(diff))
            return capsule(diff, String(localized: "日均 \(diff >= 0 ? "↑" : "↓") \(text)"))
        case .measure:
            guard let cur = comparison.current.measureAverage, let prev = previous.measureAverage else { return nil }
            let diff = cur - prev
            let text = HabitPresentationProjector.formatValue(abs(diff))
            return capsule(diff, String(localized: "\(diff >= 0 ? "↑" : "↓") \(text)"))
        }
    }

    private func dailyRate(_ total: Double, days: Int) -> Double {
        guard days > 0 else { return 0 }
        return total / Double(days)
    }

    /// 副行：完成率口径 / 上期值 / 上期均值
    private func compareSubline(_ comparison: HabitPeriodComparison, info: HabitReviewHabitInfo) -> String {
        guard let previous = comparison.previous else {
            return String(localized: "还没有更早的记录")
        }
        switch info.kind {
        case .checkIn:
            if info.frequency == .daily && !info.isBadHabit,
               let cur = comparison.current.completion {
                return String(localized: "完成率 \(Int((cur * 100).rounded()))%")
            }
            return String(localized: "上期\(info.isBadHabit ? "发生" : "记录") \(previous.recordedDays) \(String(localized: "天"))")
        case .count:
            let cur = dailyRate(comparison.current.countTotal ?? 0, days: comparison.current.validDays)
            let curText = HabitPresentationProjector.formatValue(cur)
            return String(localized: "日均 \(curText)")
        case .measure:
            let prevText = HabitPresentationProjector.formatValue(previous.measureAverage ?? 0)
            return String(localized: "上期均值 \(prevText)\(info.unit.isEmpty ? "" : " \(info.unit)")")
        }
    }

    // MARK: 打卡型趋势视图（每周完成率/天数柱；柱顶标数值，不靠图注嘴补）

    @ViewBuilder
    private func weeklyChartView(_ info: HabitReviewHabitInfo) -> some View {
        if let trend = weeklyTrend {
            if trend.bars.isEmpty || trend.bars.allSatisfy({ $0.days == 0 }) {
                Text(String(localized: "这个范围还没有可统计的周。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                WeeklyRateChart(
                    bars: trend.bars,
                    mode: trend.mode,
                    color: Color(hex: info.colorHex),
                    isBadHabit: info.isBadHabit,
                    today: model.projectionNow,
                    selectedWeek: $selectedWeek
                )
                .frame(minHeight: 220)
            }
        }
    }

    @State private var selectedWeek: Date?

    // MARK: 可视化（打卡型=每周走势+记录日历上下并存，东林认可的原型屏C形态；
    // 数值型保留「趋势⇄日历」切换——体重看趋势、日历核对，二选一合理）

    @ViewBuilder
    private func vizSection(_ snapshot: HabitRangeSnapshot) -> some View {
        if snapshot.info.kind == .checkIn {
            VStack(alignment: .leading, spacing: 12) {
                Text(weeklyTrend?.mode.title ?? String(localized: "每周完成率"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .padding(.top, 16)
                weeklyChartView(snapshot.info)

                Text(snapshot.info.isBadHabit
                     ? String(localized: "发生日历")
                     : String(localized: "记录日历"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .padding(.top, 8)
                if vizMode == .dates {
                    dateListView(snapshot)
                } else {
                    calendarView(snapshot)
                }

                // 窄屏/大字号或 VoiceOver 的日期列表入口（§7.2）
                Button {
                    withAnimation(HoloAnimation.quick) {
                        vizMode = vizMode == .dates ? .calendar : .dates
                    }
                } label: {
                    Text(vizMode == .dates ? String(localized: "返回日历") : String(localized: "按日期选择"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(vizTitle(snapshot.info))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolText)
                    Spacer()
                    vizSwitch
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

                if vizMode == .calendar || vizMode == .dates {
                    Button {
                        withAnimation(HoloAnimation.quick) {
                            vizMode = vizMode == .dates ? .calendar : .dates
                        }
                    } label: {
                        Text(vizMode == .dates ? String(localized: "返回日历") : String(localized: "按日期选择"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoPrimary)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func vizTitle(_ info: HabitReviewHabitInfo) -> String {
        switch vizMode {
        case .dates: return String(localized: "按日期查看")
        case .calendar:
            return info.isBadHabit ? String(localized: "发生日历") : String(localized: "记录日历")
        case .trend:
            if info.kind == .checkIn {
                return weeklyTrend?.mode.title ?? String(localized: "每周完成率")
            }
            return info.kind == .count
                ? String(localized: "每天的累计量")
                : String(localized: "每天的最新值")
        }
    }

    /// 趋势 / 日历 互斥切换（所有类型；打卡型的趋势=每周完成率/天数柱）
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
                Circle().fill(Color.holoToolBorder.opacity(0.7)).frame(width: 4, height: 4)
                Text(String(localized: "未记录"))
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
            .frame(minHeight: 230)
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

    // MARK: 更多范围（上月 / 自定义；快捷档已内联在切换条里）

    private var rangeSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "更多范围"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(String(localized: "摘要、图和明细使用同一个范围。"))
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.top, 4)
                .padding(.bottom, 14)

            if let prev = Calendar.current.date(byAdding: .month, value: -1, to: currentMonthStart) {
                rangeOption(monthText(prev), for: .month(prev))
                    .padding(.bottom, 12)
            }

            ReviewCustomRangeForm { start, end in
                applyRange(.custom(start: start, end: end))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.md)
        .presentationDetents([.height(360)])
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
        // 翻月状态归位到新范围的「末月」（最近的月份）：.all 的范围首日是公元 1 年，
        // 按首月归位会把日历翻到 0001/1 空白月（2026-10-13 判读实锤）；末月总是有意义的近期
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
            selectedRange = .month(model.overviewMonth)
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
        weeklyTrend = HabitReviewProjector.weeklyTrend(snapshot: snap, data: data)
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
                    .foregroundColor(.holoToolError)
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

// MARK: - 每周走势图（打卡型：完成率柱 / 每周天数柱；财务图表套件同款画法）

/// 与 ReviewTrendChart 同一套几何与交互规则（ReviewTrendChartLayout 复用）：
/// 柱宽同参封顶、X 刻度 chartOverlay 自绘、横向拖动/点按沿途选中、气泡跟随。
struct WeeklyRateChart: View {
    let bars: [HabitWeeklyBar]
    let mode: HabitWeeklyTrendMode
    let color: Color
    let isBadHabit: Bool
    let today: Date
    @Binding var selectedWeek: Date?
    @State private var selection: String?

    var body: some View {
        HoloBarChart(buckets: bars.map { bar in
            HoloChartBucket(id: String(bar.weekStart.timeIntervalSince1970),
                            label: HoloChartFormat.date(bar.weekStart),
                            detail: HoloChartFormat.date(bar.weekStart) + " 起",
                            values: [mode == .completionRate ? bar.fraction.map { $0 * 100 } : (bar.days > 0 ? Double(bar.recordedDays) : nil)],
                            isFuture: bar.weekStart > today)
        }, series: [.init(id: "habit", title: mode == .completionRate ? "完成率" : (isBadHabit ? "发生天数" : "记录天数"), color: color)],
           selection: $selection, height: 140, yDomain: mode == .completionRate ? 0...100 : 0...8,
           valueText: { mode == .completionRate ? "\(HoloChartFormat.number($0))%" : "\(Int($0)) 天" },
           onInspect: { bucket in selectedWeek = bars.first { String($0.weekStart.timeIntervalSince1970) == bucket.id }?.weekStart })
        .onChange(of: mode) { _, _ in selection = nil; selectedWeek = nil }
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

// MARK: - 回顾趋势图（计数柱 / 测量分段点线；拖动沿途选中）

struct ReviewTrendChart: View {
    let values: [HabitDailyNumericValue]
    let kind: HabitRowKind
    let color: Color
    let unit: String
    let interval: DateInterval
    let today: Date
    let selectedDay: Date?
    var onSelectDay: (Date) -> Void
    var sparseCollapse = false
    @State private var selection: String?

    private var buckets: [HoloChartBucket] {
        let range = ReviewTrendChartLayout.chartRange(interval: interval, today: today, values: values,
                                                    calendar: .current, sparseCollapse: sparseCollapse)
        let end = Calendar.current.date(byAdding: .day, value: range.dayCount - 1, to: range.start) ?? range.start
        return HoloChartFormat.days(from: range.start, through: end, values: values.map { ($0.date, $0.value) })
    }
    private var series: [HoloChartSeries] { [.init(id: "habit", title: kind == .count ? "记录量" : "测量值", color: color)] }
    private func format(_ value: Double) -> String { HabitPresentationProjector.formatValue(value) + (unit.isEmpty ? "" : " \(unit)") }
    private func inspect(_ bucket: HoloChartBucket) {
        if let timestamp = Double(bucket.id) { onSelectDay(Date(timeIntervalSince1970: timestamp)) }
    }
    var body: some View {
        Group {
            if kind == .count {
                HoloBarChart(buckets: buckets, series: series, selection: $selection, height: 150,
                             valueText: format, onInspect: inspect)
            } else {
                HoloLineChart(buckets: buckets, series: series, selection: $selection, height: 150,
                              valueText: format, onInspect: inspect)
            }
        }
        .onChange(of: selectedDay) { _, day in selection = day.map { String(Calendar.current.startOfDay(for: $0).timeIntervalSince1970) } }
    }
}
