//
//  HabitTodayRecordSheet.swift
//  Holo
//
//  习惯概览弹层（2026-10-11 方案A升级，V2 §5.2 起步）：标题=习惯名；
//  大数字区在今日无记录时给「上次记录」（测量）或「连续打卡 N 天」（打卡）；
//  新增「最近 30 天」迷你趋势（数值型复用回顾页 ReviewTrendChart，图表规范
//  硬规则 5：触碰/拖动查看具体数据）与打卡缝线；今天的记录列表（可编辑可删除）
//  与主动作保留；底部「查看完整回顾」直达单习惯回顾整页 + 习惯设置入口。
//

import SwiftUI
import CoreData

struct HabitTodayRecordSheet: View {

    /// 目标习惯（仅持 id；快照数据从模型取，弹层生命周期内自动刷新）
    let habitId: UUID
    @ObservedObject var model: HabitModuleViewModel
    /// 打开习惯设置（容器接 AddHabitSheet 编辑态）
    var onOpenSettings: (UUID) -> Void
    /// 查看完整回顾（容器接单习惯回顾整页）
    var onOpenReview: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dayRecords: [HabitRecord] = []
    /// 近 7 天快照（近况一眼；方案A：30 天大图已撤，走势与对比去长期回顾）
    @State private var historySnapshot: HabitRangeSnapshot?
    /// 全量快照（「上次记录」不受 7 天窗截断）
    @State private var allTimeSnapshot: HabitRangeSnapshot?

    // MARK: 生命周期管理（方案A配套：··· 直达暂停/归档/删除，不再埋在设置表单底部）

    @State private var pauseTarget: Habit? = nil
    @State private var pendingLifecycleAction: LifecycleAction? = nil
    @ObservedObject private var entitlement = HoloEntitlementState.shared

    private enum LifecycleAction: Identifiable {
        case archive, delete
        var id: Int { self == .archive ? 0 : 1 }
    }

    private var row: HabitRowSnapshot? {
        model.todayRows.first { $0.id == habitId }
            ?? model.pausedRows.first { $0.id == habitId }
            ?? model.archivedRows.first { $0.id == habitId }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if let row {
                        header(row)
                        todaySummary(row)
                        historySection(row)
                        recordsSection(row)
                    } else {
                        Text(String(localized: "这个习惯已不可用"))
                            .holoText(.body)
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.md)
                // 补签直达挂本节点（···菜单入口，2026-10-15）：与 pauseTarget /
                // editingRecord 分属三个节点，同链多 sheet 会互吞
                .sheet(item: $retroTarget) { context in
                    HabitRetroactiveSheet(context: context)
                }
            }
            .background(Color.holoToolBackground)
            // 主操作贴底（§8.7 定式 9 / §8.8 规则 2）：打卡按钮固定在弹层底部
            // 安全区，无数据时不再悬在屏中、下方留大片空白
            .safeAreaInset(edge: .bottom) {
                if let row {
                    primaryAction(row)
                }
            }
            .navigationTitle(row?.name ?? String(localized: "今天的记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    lifecycleMenu
                }
            }
            // 暂停 sheet 挂本节点（与 editingRecord 的 sheet 分属不同节点，同节点双 sheet 会互吞）
            .sheet(item: $pauseTarget) { habit in
                HabitPauseSheet(habit: habit, onPaused: {
                    // 暂停确认成功：收起整个弹层回页面
                    dismiss()
                })
            }
            // 生命周期确认（与「删除记录」确认分节点）
            .confirmationDialog(
                lifecycleConfirmTitle,
                isPresented: Binding(
                    get: { pendingLifecycleAction != nil },
                    set: { if !$0 { pendingLifecycleAction = nil } }),
                titleVisibility: .visible
            ) {
                Button(lifecycleConfirmButtonTitle, role: .destructive) {
                    if let action = pendingLifecycleAction {
                        switch action {
                        case .archive:
                            performLifecycle { try HabitRepository.shared.archiveHabitById(habitId) }
                        case .delete:
                            performLifecycle { try HabitRepository.shared.deleteHabitById(habitId) }
                        }
                    }
                    pendingLifecycleAction = nil
                }
                Button(String(localized: "取消"), role: .cancel) { pendingLifecycleAction = nil }
            } message: {
                Text(lifecycleConfirmMessage)
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { reloadRecords() }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            reloadRecords()
        }
        .sheet(item: $editingRecord) { target in
            if let record = findRecord(target.recordId) {
                HabitRecordEditSheet(
                    record: record,
                    kind: row?.kind ?? .checkIn,
                    unit: row?.target?.unit
                ) { value, note in
                    Task {
                        await model.record(kind: .updateRecord(recordId: target.recordId,
                                                               value: value, note: note),
                                           habitId: habitId)
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "删除这条记录？"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除这条记录"), role: .destructive) {
                if let recordId = pendingDeleteRecordId {
                    Task {
                        await model.record(kind: .deleteRecord(recordId: recordId), habitId: habitId)
                    }
                }
                pendingDeleteRecordId = nil
            }
            Button(String(localized: "取消"), role: .cancel) { pendingDeleteRecordId = nil }
        } message: {
            Text(String(localized: "只删除\(row?.name ?? "")选定的这一条记录"))
        }
    }

    // MARK: 头部（习惯 + 完整日期）

    private func header(_ row: HabitRowSnapshot) -> some View {
        HStack(spacing: HoloSpacing.md) {
            row.iconImage(size: 19)
                .foregroundColor(Color(hex: row.colorHex))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: row.colorHex).opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text(fullTodayText)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer()
        }
        .padding(.top, HoloSpacing.xs)
    }

    private var fullTodayText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        return formatter.string(from: model.projectionNow)
    }

    // MARK: 大数字区（今天优先；今天无记录时给历史锚点）
    // 2026-10-15 P2 收敛：底部「查看长期回顾/习惯设置」两行撤光，「看进度」
    // 并进本区右侧——点整个数字卡直达单习惯回顾（设置只在 ··· 菜单）

    /// 大数字区内容：label（小字定性）/ value（大数字）/ sub（次行说明）
    private struct HeroContent {
        let label: String
        let value: String
        let sub: String
    }

    private func todaySummary(_ row: HabitRowSnapshot) -> some View {
        let content = hero(row)
        return Button {
            dismiss()
            onOpenReview(habitId)
        } label: {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.label)
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                    Text(content.value)
                        .font(.system(size: 25, weight: .semibold).monospacedDigit())
                        .foregroundColor(.holoToolText)
                    Text(content.sub)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(hex: row.colorHex))
                    HStack(spacing: 2) {
                        Text(String(localized: "看进度"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color(hex: row.colorHex))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(hex: row.colorHex).opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.holoToolInset.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(String(localized: "查看这个习惯的进度与走势")))
    }

    private func hero(_ row: HabitRowSnapshot) -> HeroContent {
        let unit = historySnapshot?.info.unit ?? row.target?.unit ?? ""
        switch row.kind {
        case .measure:
            if let value = row.today.todayValue {
                // 今天已记录：副行给上一次测量（不重复今天值）
                var sub = statusText(row)
                if let prev = previousMeasureBeforeToday {
                    sub = String(localized: "上次 \(valueWithUnit(prev.value, unit: unit)) · \(shortDate(prev.day))")
                }
                return HeroContent(label: String(localized: "今天"),
                                   value: valueWithUnit(value, unit: unit),
                                   sub: sub)
            }
            if let latest = allTimeSnapshot?.latestMeasure {
                let calendar = Calendar.current
                let daysAgo = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: latest.day),
                    to: calendar.startOfDay(for: model.projectionNow)).day ?? 0
                let dateText = shortDate(latest.day)
                let sub = daysAgo > 0
                    ? String(localized: "\(dateText) · \(daysAgo) 天前")
                    : dateText
                return HeroContent(label: String(localized: "上次记录"),
                                   value: valueWithUnit(latest.value, unit: unit),
                                   sub: sub)
            }
            return HeroContent(label: String(localized: "今天"), value: "—", sub: statusText(row))
        case .count:
            return HeroContent(label: String(localized: "今天"),
                               value: todayValueText(row),
                               sub: subtitleText(row))
        case .checkIn:
            if !row.isBadHabit, let streak = row.streak, streak.value > 0 {
                var parts: [String] = []
                if !row.today.isRecorded, let last = lastCheckInDateText {
                    parts.append(String(localized: "上次 \(last)"))
                }
                if !row.today.isRecorded {
                    parts.append(String(localized: "别断了今天"))
                }
                return HeroContent(label: streak.kindName,
                                   value: "\(streak.value) \(streak.unitName)",
                                   sub: parts.isEmpty ? statusText(row) : parts.joined(separator: " · "))
            }
            let valueText = todayValueText(row)
            let subText = subtitleText(row)
            return HeroContent(label: String(localized: "今天"),
                               value: valueText,
                               sub: subText == valueText ? "" : subText)
        }
    }

    /// 全量范围内最近一次有效打卡时刻（如「10月10日 21:14」）
    private var lastCheckInDateText: String? {
        guard let fact = allTimeSnapshot?.records.filter({ $0.isCompleted })
            .max(by: { $0.date < $1.date }) else { return nil }
        return shortDateTime(fact.date)
    }

    /// 今天之前的最近一次测量（今天已记录时副行锚点，不重复今天值）
    private var previousMeasureBeforeToday: (value: Double, day: Date)? {
        guard let snapshot = allTimeSnapshot else { return nil }
        let todayStart = Calendar.current.startOfDay(for: model.projectionNow)
        return snapshot.dailyValues
            .filter { Calendar.current.startOfDay(for: $0.date) < todayStart }
            .last
            .map { (value: $0.value, day: $0.date) }
    }

    private func valueWithUnit(_ value: Double, unit: String) -> String {
        let text = HabitPresentationProjector.formatValue(value)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    private func todayValueText(_ row: HabitRowSnapshot) -> String {
        switch row.kind {
        case .checkIn:
            if row.today.isRecorded {
                return row.isBadHabit ? String(localized: "已记录发生") : String(localized: "已记录")
            }
            return String(localized: "未记录")
        case .count, .measure:
            guard let value = row.today.todayValue else { return "—" }
            let unit = row.target?.unit ?? ""
            return "\(HabitPresentationProjector.formatValue(value)) \(unit)".trimmingCharacters(in: .whitespaces)
        }
    }

    private func subtitleText(_ row: HabitRowSnapshot) -> String {
        row.today.periodValueText ?? statusText(row)
    }

    private func statusText(_ row: HabitRowSnapshot) -> String {
        if row.isBadHabit {
            return row.today.isRecorded ? String(localized: "已记录发生") : String(localized: "未记录")
        }
        return row.today.isRecorded ? String(localized: "已记录") : String(localized: "未记录")
    }

    private var separatorLine: some View {
        Rectangle().fill(Color.holoToolBorder.opacity(0.5)).frame(height: 0.5)
    }

    // MARK: 今日记录列表

    private func recordsSection(_ row: HabitRowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "今天的记录"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Spacer()
                if dayRecords.count > 1 {
                    Text(String(localized: "\(dayRecords.count) 条"))
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.holoToolInset))
                }
            }
            .padding(.bottom, 4)

            if dayRecords.isEmpty {
                Text(String(localized: "今天还没有记录。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(dayRecords) { record in
                    recordRow(record, row: row)
                }
            }
        }
    }

    private func recordRow(_ record: HabitRecord, row: HabitRowSnapshot) -> some View {
        HStack(alignment: .center, spacing: HoloSpacing.sm) {
            Button {
                editingRecord = EditTarget(recordId: record.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.formattedTime)
                            .font(.system(size: 10))
                            .foregroundColor(.holoToolTextSecondary)
                        if record.isRetroactive {
                            Text(String(localized: "补录"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(hex: row.colorHex))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color(hex: row.colorHex).opacity(0.35)))
                        }
                    }
                    Text(recordTitle(record, row: row))
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
                    editingRecord = EditTarget(recordId: record.id)
                } label: {
                    Label(String(localized: "编辑记录"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDeleteRecordId = record.id
                    showDeleteConfirm = true
                } label: {
                    Label(String(localized: "删除记录"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .overlay(alignment: .bottom) { separatorLine }
    }

    private func recordTitle(_ record: HabitRecord, row: HabitRowSnapshot) -> String {
        if row.kind == .checkIn {
            return record.isCompleted
                ? (row.isBadHabit ? String(localized: "记录发生") : String(localized: "打卡记录"))
                : String(localized: "已取消")
        }
        return record.formattedValue(unit: row.target?.unit)
    }

    // MARK: 近 7 天（方案A：弹层回归操作层，只留一眼近况；走势与对比去长期回顾）

    private func historySection(_ row: HabitRowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "近 7 天"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoToolText)

            if let snapshot = historySnapshot {
                if snapshot.records.isEmpty {
                    Text(String(localized: "近 7 天还没有记录。"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                } else if snapshot.info.kind == .checkIn {
                    historyStitches(snapshot, accent: Color(hex: row.colorHex))
                    stitchLegend(accent: Color(hex: row.colorHex))
                } else {
                    HabitMiniTrendLine(
                        values: snapshot.dailyValues.map { ($0.date, $0.value) },
                        color: Color(hex: row.colorHex),
                        today: model.projectionNow
                    )
                    .frame(height: 52)
                    Text(String(localized: "只留一眼近况；走势与对比都在长期回顾里看。"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
        }
        .accessibilityIdentifier("habit.todayrecord.history")
    }

    /// 打卡型 30 天点阵（大实心圆=已记录 / 空心圆=补录 / 小灰点=未记录 / 搭线=暂停 /
    /// 空圈游标=今天）。第一版用了卡片缝线针法（6×3pt 细针+2.5pt 针眼），在弹层里
    /// 密度低时几乎不可见（2026-10-11 东林实报「没看到任何图标」），改用大号圆点语言
    private func historyStitches(_ snapshot: HabitRangeSnapshot, accent: Color) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: model.projectionNow)
        let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
        return HStack(spacing: 0) {
            ForEach(historyDays(snapshot), id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: today)
                VStack(spacing: 5) {
                    historyStitch(
                        snapshot.day(day, today: model.projectionNow, calendar: calendar),
                        accent: accent,
                        isToday: isToday
                    )
                    .frame(height: 26)
                    Text(weekdaySymbols[calendar.component(.weekday, from: day) - 1])
                        .font(.system(size: 10, weight: isToday ? .semibold : .regular))
                        .foregroundColor(isToday ? accent : .holoToolTextSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func historyStitch(_ info: HabitReviewDay, accent: Color, isToday: Bool) -> some View {
        ZStack {
            if info.isBeforeCreation {
                // 创建前：淡点占位（格子恒在，语义「那时还没有这个习惯」，不整格消失留白）
                Circle()
                    .fill(Color.holoToolTextSecondary.opacity(0.12))
                    .frame(width: 3.5, height: 3.5)
            } else if info.isRecorded {
                if info.isRetroactive {
                    Circle()
                        .fill(Color.holoToolSurface)
                        .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                }
            } else if info.isPaused {
                Capsule()
                    .fill(Color.holoToolBorder.opacity(0.8))
                    .frame(width: 7, height: 2)
            } else {
                Circle()
                    .fill(Color.holoToolTextSecondary.opacity(0.3))
                    .frame(width: 4.5, height: 4.5)
            }
            if isToday {
                Circle()
                    .strokeBorder(accent.opacity(0.75), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .offset(y: -9)
            }
        }
        .frame(height: 26)
    }

    /// 点阵图例（第一版无图例，判读与用户都读不出标记含义）
    private func stitchLegend(accent: Color) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(String(localized: "有记录"))
            }
            HStack(spacing: 4) {
                Circle().fill(Color.holoToolSurface)
                    .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                Text(String(localized: "补录"))
            }
            HStack(spacing: 4) {
                Circle().strokeBorder(accent.opacity(0.75), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                Text(String(localized: "今天"))
            }
        }
        .font(.system(size: 10.5))
        .foregroundColor(.holoToolTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func historyDays(_ snapshot: HabitRangeSnapshot) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: model.projectionNow)
        let end = min(snapshot.interval.end,
                      calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        var days: [Date] = []
        var current = snapshot.interval.start
        while current < end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    // MARK: 日期格式化

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter.string(from: date)
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日 HH:mm")
        return formatter.string(from: date)
    }

    // MARK: 主动作（与今天页同一协调器）

    @ViewBuilder
    private func primaryAction(_ row: HabitRowSnapshot) -> some View {
        if row.lifecycle == .active {
            // 取消打卡是毁连续的高危动作：红色样式警示，与记录行拉开间距
            let isCancelAction = row.kind == .checkIn && row.today.isRecorded && !row.isBadHabit
            Button {
                switch row.kind {
                case .checkIn:
                    Task { await model.record(kind: .toggleCheckIn, habitId: habitId) }
                case .count, .measure:
                    // 计数/测量从主列表的既有输入通道进入（弹层内不复制第二套键盘）
                    dismiss()
                    onRequestMeasureInput?(habitId)
                }
            } label: {
                HStack(spacing: 6) {
                    switch row.kind {
                    case .checkIn:
                        Image(systemName: row.today.isRecorded ? "xmark" : "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text(row.today.isRecorded
                             ? (row.isBadHabit ? String(localized: "取消发生记录") : String(localized: "取消打卡"))
                             : (row.isBadHabit ? String(localized: "记录发生") : String(localized: "打卡")))
                    case .count:
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        Text(String(localized: "增加一次"))
                    case .measure:
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        Text(row.today.isRecorded ? String(localized: "再记录一次") : String(localized: "记录今天的数值"))
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isCancelAction ? .holoError : Color(hex: row.colorHex))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isCancelAction
                              ? Color.holoError.opacity(0.1)
                              : Color(hex: row.colorHex).opacity(0.12))
                )
            }
            .buttonStyle(HoloPressStyle())
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.sm)
            .padding(.horizontal, HoloSpacing.lg)
            .background(.ultraThinMaterial)
            .disabled(model.coordinator.savingHabitIds.contains(habitId))
            .accessibilityIdentifier("habit.todayrecord.primary")
        }
    }

    // MARK: ··· 管理菜单（设置/补签/暂停/归档/删除一手可达；动作按生命周期动态出）

    private var lifecycleMenu: some View {
        Menu {
            Button {
                dismiss()
                onOpenSettings(habitId)
            } label: {
                Label(String(localized: "习惯设置"), systemImage: "slider.horizontal.3")
            }
            if row?.kind == .checkIn, row?.lifecycle == .active,
               let habit = HabitRepository.shared.findHabit(by: habitId) {
                Button {
                    retroTarget = HabitRetroactiveSheetContext(
                        habit: habit,
                        preselectedDay: nil,
                        mode: .sign
                    )
                } label: {
                    Label(String(localized: "补签"), systemImage: "clock.arrow.circlepath")
                }
            }
            Divider()
            switch row?.lifecycle ?? .active {
            case .active:
                Button(action: requestPause) {
                    Label(entitlement.isPlusActive
                          ? String(localized: "暂停习惯")
                          : String(localized: "暂停习惯 · Plus"),
                          systemImage: "pause.circle")
                }
                Button {
                    pendingLifecycleAction = .archive
                } label: {
                    Label(String(localized: "归档习惯"), systemImage: "archivebox")
                }
            case .paused:
                Button {
                    performLifecycle { try HabitRepository.shared.resumeHabitById(habitId) }
                } label: {
                    Label(String(localized: "恢复习惯"), systemImage: "play.circle")
                }
                Button {
                    pendingLifecycleAction = .archive
                } label: {
                    Label(String(localized: "归档习惯"), systemImage: "archivebox")
                }
            case .archived:
                Button {
                    performLifecycle { try HabitRepository.shared.unarchiveHabitById(habitId) }
                } label: {
                    Label(String(localized: "取消归档"), systemImage: "archivebox")
                }
            }
            Divider()
            Button(role: .destructive) {
                pendingLifecycleAction = .delete
            } label: {
                Label(String(localized: "删除习惯"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(String(localized: "习惯管理")))
        .accessibilityIdentifier("habit.todayrecord.manage")
    }

    /// 暂停按 Plus 权益执行（与设置表单同款契约：真实权益确认后才开弹层）
    private func requestPause() {
        if entitlement.isPlusActive {
            pauseTarget = HabitRepository.shared.findHabit(by: habitId)
        } else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .habitPause) {
                await MainActor.run {
                    pauseTarget = HabitRepository.shared.findHabit(by: habitId)
                }
            }
        }
    }

    /// 生命周期动作：成功关弹层回页面；失败说明且状态保持原样
    private func performLifecycle(_ work: () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch {
            HoloToastCenter.shared.show(String(localized: "操作没有成功，状态保持原样。请重试。"), type: .info)
        }
    }

    private var lifecycleConfirmTitle: String {
        pendingLifecycleAction == .archive
            ? String(localized: "归档这个习惯？")
            : String(localized: "删除这个习惯？")
    }

    private var lifecycleConfirmButtonTitle: String {
        pendingLifecycleAction == .archive
            ? String(localized: "确认归档")
            : String(localized: "删除习惯与记录")
    }

    private var lifecycleConfirmMessage: String {
        let name = row?.name ?? ""
        if pendingLifecycleAction == .archive {
            return String(localized: "归档「\(name)」后，它会从今天隐藏，历史记录全部保留。")
        }
        return String(localized: "删除「\(name)」及全部记录？这项删除无法恢复。")
    }

    // MARK: 数据

    private struct EditTarget: Identifiable {
        let recordId: UUID
        var id: UUID { recordId }
    }

    @State private var editingRecord: EditTarget?
    @State private var pendingDeleteRecordId: UUID?
    @State private var showDeleteConfirm = false
    /// ··· 菜单直达补签（窗口内漏卡日自选；无可补日弹层内有空态说明）
    @State private var retroTarget: HabitRetroactiveSheetContext? = nil

    /// 计数/测量主输入通道（容器侧挂 HabitMeasureInputSheet）
    var onRequestMeasureInput: ((UUID) -> Void)? = nil

    private func reloadRecords() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        dayRecords = HabitRepository.shared.getRecords(from: dayStart, to: dayEnd)
            .filter { $0.habitId == habitId }
        rebuildHistory()
    }

    /// 与单习惯回顾页同一投影管道（HabitReviewProjector），7 天窗供近况一眼、
    /// 全量窗供「上次记录」——7 天外的前史不断档。
    private func rebuildHistory() {
        guard let habit = HabitRepository.shared.findHabit(by: habitId) else {
            historySnapshot = nil
            allTimeSnapshot = nil
            return
        }
        let lifecycle: HabitLifecycle = {
            if habit.isArchived { return .archived }
            return habit.isPaused ? .paused : .active
        }()
        let info = HabitReviewHabitInfo(habit: habit, lifecycle: lifecycle)
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([habitId]),
            now: model.projectionNow
        )
        historySnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .lastDays(7), data: data)
        allTimeSnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .all, data: data)
    }

    private func findRecord(_ recordId: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        return try? HabitRepository.shared.context.fetch(request).first
    }
}

// MARK: - 近 7 天迷你折线（数值型弹层；末点空心=今天游标）

struct HabitMiniTrendLine: View {

    let values: [(date: Date, value: Double)]
    let color: Color
    let today: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if values.count >= 2 {
                let lo = values.map(\.value).min() ?? 0
                let hi = values.map(\.value).max() ?? 1
                let span = max(hi - lo, 0.0001)
                let points = values.enumerated().map { index, item in
                    CGPoint(x: w * CGFloat(index) / CGFloat(values.count - 1),
                            y: h - 4 - (h - 8) * CGFloat((item.value - lo) / span))
                }
                ZStack {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    ForEach(points.indices, id: \.self) { index in
                        let isLast = index == points.count - 1
                        Circle()
                            .fill(isLast ? Color.holoToolBackground : color)
                            .frame(width: isLast ? 6 : 4.4)
                            .overlay(Circle().strokeBorder(color, lineWidth: 1.4)
                                .frame(width: 6, height: 6)
                                .opacity(isLast ? 1 : 0))
                            .position(points[index])
                    }
                }
            } else if values.count == 1 {
                Circle()
                    .strokeBorder(color, lineWidth: 1.6)
                    .frame(width: 6, height: 6)
                    .position(x: w / 2, y: h / 2)
            }
        }
        .accessibilityHidden(true)
    }
}
