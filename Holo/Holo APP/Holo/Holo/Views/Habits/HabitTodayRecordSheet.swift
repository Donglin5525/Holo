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
    /// 最近 30 天快照（趋势图 / 缝线 / 统计行）
    @State private var historySnapshot: HabitRangeSnapshot?
    /// 全量快照（「上次记录」不受 30 天窗截断）
    @State private var allTimeSnapshot: HabitRangeSnapshot?
    /// 趋势图选中日（气泡/高亮带由图表组件自绘）
    @State private var selectedTrendDay: Date?

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
                        primaryAction(row)
                        reviewEntry(row)
                        settingsEntry(row)
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
                .padding(.bottom, 30)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(row?.name ?? String(localized: "今天的记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
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
                    isCountType: row?.kind == .count,
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

    /// 大数字区内容：label（小字定性）/ value（大数字）/ sub（次行说明）
    private struct HeroContent {
        let label: String
        let value: String
        let sub: String
    }

    private func todaySummary(_ row: HabitRowSnapshot) -> some View {
        let content = hero(row)
        return VStack(alignment: .leading, spacing: 4) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { separatorLine }
        .overlay(alignment: .bottom) { separatorLine }
        .accessibilityElement(children: .combine)
    }

    private func hero(_ row: HabitRowSnapshot) -> HeroContent {
        let unit = historySnapshot?.info.unit ?? row.target?.unit ?? ""
        switch row.kind {
        case .measure:
            if let value = row.today.todayValue {
                return HeroContent(label: String(localized: "今天"),
                                   value: valueWithUnit(value, unit: unit),
                                   sub: subtitleText(row))
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
                if let last = lastCheckInDateText {
                    parts.append(String(localized: "上次 \(last)"))
                }
                if !row.today.isRecorded {
                    parts.append(String(localized: "别断了今天"))
                }
                return HeroContent(label: streak.kindName,
                                   value: "\(streak.value) \(streak.unitName)",
                                   sub: parts.isEmpty ? statusText(row) : parts.joined(separator: " · "))
            }
            return HeroContent(label: String(localized: "今天"),
                               value: todayValueText(row),
                               sub: subtitleText(row))
        }
    }

    /// 全量范围内最近一次有效打卡时刻（如「10月10日 21:14」）
    private var lastCheckInDateText: String? {
        guard let fact = allTimeSnapshot?.records.filter({ $0.isCompleted })
            .max(by: { $0.date < $1.date }) else { return nil }
        return shortDateTime(fact.date)
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
                if !dayRecords.isEmpty {
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

    // MARK: 最近 30 天（趋势图 / 打卡缝线 / 统计行）

    private func historySection(_ row: HabitRowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HabitReviewRange.lastDays(30).label(now: model.projectionNow, calendar: .current))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoToolText)

            if let snapshot = historySnapshot {
                if snapshot.records.isEmpty {
                    Text(String(localized: "最近 30 天还没有记录。"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                } else if snapshot.info.kind == .checkIn {
                    historyStitches(snapshot, accent: Color(hex: row.colorHex))
                    stitchLegend(accent: Color(hex: row.colorHex))
                    statsLine(snapshot)
                } else {
                    // 复用回顾页趋势图：拖动沿途选中 + 数值气泡，无值日如实「无记录」；
                    // 稀疏收敛=只有零星几天记录时图域收到首末记录日，不出「30 槽孤柱」
                    ReviewTrendChart(
                        values: snapshot.dailyValues,
                        kind: snapshot.info.kind,
                        color: Color(hex: row.colorHex),
                        unit: snapshot.info.unit,
                        interval: snapshot.interval,
                        today: model.projectionNow,
                        selectedDay: selectedTrendDay,
                        onSelectDay: { day in
                            selectedTrendDay = Calendar.current.startOfDay(for: day)
                        },
                        sparseCollapse: true
                    )
                    .frame(height: 200)
                    // 自绘 X 刻度溢出图框下缘约 17pt（组件既定行为，与回顾页同源），
                    // 图下排文字必须预留，否则与最左刻度叠压（判读两轮实锤）
                    .padding(.bottom, 18)
                    statsLine(snapshot)
                }
            }
        }
        .accessibilityIdentifier("habit.todayrecord.history")
    }

    @ViewBuilder
    private func statsLine(_ snapshot: HabitRangeSnapshot) -> some View {
        if let text = historyStatsText(snapshot) {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
        }
    }

    private func historyStatsText(_ snapshot: HabitRangeSnapshot) -> String? {
        let days = snapshot.recordedDayCount
        switch snapshot.info.kind {
        case .checkIn:
            return String(localized: "记了 \(days) 天")
        case .measure:
            guard days > 0 else { return nil }
            let avg = snapshot.dailyValues.reduce(0.0) { $0 + $1.value } / Double(days)
            let avgText = valueWithUnit(avg, unit: snapshot.info.unit)
            return String(localized: "记了 \(days) 天 · 均值 \(avgText)")
        case .count:
            guard days > 0 else { return nil }
            let perDay = (snapshot.countTotal ?? 0) / Double(days)
            let perDayText = valueWithUnit(perDay, unit: snapshot.info.unit)
            return String(localized: "记了 \(days) 天 · 日均 \(perDayText)")
        }
    }

    /// 打卡型 30 天点阵（大实心圆=已记录 / 空心圆=补录 / 小灰点=未记录 / 搭线=暂停 /
    /// 空圈游标=今天）。第一版用了卡片缝线针法（6×3pt 细针+2.5pt 针眼），在弹层里
    /// 密度低时几乎不可见（2026-10-11 东林实报「没看到任何图标」），改用大号圆点语言
    private func historyStitches(_ snapshot: HabitRangeSnapshot, accent: Color) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: model.projectionNow)
        return HStack(spacing: 0) {
            ForEach(historyDays(snapshot), id: \.self) { day in
                historyStitch(
                    snapshot.day(day, today: model.projectionNow, calendar: calendar),
                    accent: accent,
                    isToday: calendar.isDate(day, inSameDayAs: today)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func historyStitch(_ info: HabitReviewDay, accent: Color, isToday: Bool) -> some View {
        ZStack {
            if info.isBeforeCreation {
                // 创建前：空位不渲染（那时还没有这个习惯，不是漏做）
                EmptyView()
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
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(String(localized: "有记录"))
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
                .foregroundColor(Color(hex: row.colorHex))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: row.colorHex).opacity(0.12))
                )
            }
            .buttonStyle(HoloPressStyle())
            .disabled(model.coordinator.savingHabitIds.contains(habitId))
        }
    }

    // MARK: 习惯设置入口

    private func settingsEntry(_ row: HabitRowSnapshot) -> some View {
        Button {
            dismiss()
            onOpenSettings(habitId)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 26)
                Text(String(localized: "习惯设置"))
                    .font(.holoBody)
                    .foregroundColor(.holoToolText)
                Spacer()
                Text(String(localized: "目标、提醒、暂停与归档"))
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 查看完整回顾（单习惯回顾整页：趋势 / 日历 / 逐日明细 / 补录）

    private func reviewEntry(_ row: HabitRowSnapshot) -> some View {
        Button {
            dismiss()
            onOpenReview(habitId)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: row.colorHex))
                    .frame(width: 26)
                Text(String(localized: "查看完整回顾"))
                    .font(.holoBody)
                    .foregroundColor(.holoToolText)
                Spacer()
                Text(String(localized: "趋势 · 日历 · 逐日明细"))
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { separatorLine }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("habit.todayrecord.review")
    }

    // MARK: 数据

    private struct EditTarget: Identifiable {
        let recordId: UUID
        var id: UUID { recordId }
    }

    @State private var editingRecord: EditTarget?
    @State private var pendingDeleteRecordId: UUID?
    @State private var showDeleteConfirm = false

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

    /// 与单习惯回顾页同一投影管道（HabitReviewProjector），30 天窗供图表、
    /// 全量窗供「上次记录」——30 天外的前史不断档。
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
        historySnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .lastDays(30), data: data)
        allTimeSnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .all, data: data)
    }

    private func findRecord(_ recordId: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        return try? HabitRepository.shared.context.fetch(request).first
    }
}
