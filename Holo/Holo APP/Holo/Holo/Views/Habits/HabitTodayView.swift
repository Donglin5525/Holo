//
//  HabitTodayView.swift
//  Holo
//
//  今天页（2026-10 重构）：日期与已记录数量 → 滚动七天日期条 → 补签/暂停管理
//  → 每日分组连续列表 → 本周与本月分组。根导航仍在 HabitsView。
//

import SwiftUI
import Combine

struct HabitTodayView: View {

    @ObservedObject var model: HabitModuleViewModel
    let onOpenDetail: (UUID) -> Void
    let onOpenAddHabit: () -> Void

    // MARK: 弹层状态

    /// 测量输入目标（记录/再记录）
    @State private var measureInputTarget: HabitRowSnapshot?
    /// 补签/补记的习惯选择
    @State private var showRetroactiveHabitPicker = false
    /// 日期条选中的历史日（当日回看弹层）
    @State private var selectedHistoryDay: Date?
    /// 暂停管理入口 → 管理页已暂停分组
    let onOpenPausedManagement: () -> Void

    private var dailyRows: [HabitRowSnapshot] {
        model.filteredTodayRows.filter { $0.frequency == .daily }
    }

    private var periodRows: [HabitRowSnapshot] {
        model.filteredTodayRows.filter { $0.frequency != .daily }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.sm) {
                headerSection
                weekStrip
                filterAndEntries

                if model.filteredTodayRows.isEmpty {
                    emptyState
                } else {
                    if !dailyRows.isEmpty {
                        sectionTitle(String(localized: "每日习惯"))
                        ForEach(dailyRows) { row in
                            HabitRowView(
                                snapshot: row,
                                isSaving: model.coordinator.savingHabitIds.contains(row.id),
                                inlineErrorMessage: model.inlineError?.habitId == row.id ? model.inlineError?.message : nil,
                                onOpenDetail: { onOpenDetail(row.id) },
                                onToggleCheckIn: {
                                    Task { await model.record(kind: .toggleCheckIn, habitId: row.id) }
                                },
                                onIncrement: {
                                    Task { await model.record(kind: .increment(amount: 1), habitId: row.id) }
                                },
                                onDecrement: {
                                    Task { await model.record(kind: .removeLatestNumeric, habitId: row.id) }
                                },
                                onMeasureRecord: { measureInputTarget = row },
                                onOpenTrail: { onOpenDetail(row.id) }
                            )
                            .id(row.id)
                        }
                    }

                    if !periodRows.isEmpty {
                        sectionTitle(String(localized: "本周与本月"))
                        ForEach(periodRows) { row in
                            HabitRowView(
                                snapshot: row,
                                isSaving: model.coordinator.savingHabitIds.contains(row.id),
                                inlineErrorMessage: model.inlineError?.habitId == row.id ? model.inlineError?.message : nil,
                                onOpenDetail: { onOpenDetail(row.id) },
                                onToggleCheckIn: {
                                    Task { await model.record(kind: .toggleCheckIn, habitId: row.id) }
                                },
                                onIncrement: {
                                    Task { await model.record(kind: .increment(amount: 1), habitId: row.id) }
                                },
                                onDecrement: {
                                    Task { await model.record(kind: .removeLatestNumeric, habitId: row.id) }
                                },
                                onMeasureRecord: { measureInputTarget = row },
                                onOpenTrail: { }
                            )
                            .id(row.id)
                        }
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 页面内撤销提示（底部导航之上；导航由 HabitsView 层提供 inset）
            if let hint = model.undoHint {
                HabitRecordFeedbackView(hint: hint) {
                    Task { await model.undoLast() }
                } onExpire: {
                    model.expireUndoHint()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.undoHint)
        .sheet(item: $measureInputTarget) { snapshot in
            HabitMeasureInputSheet(snapshot: snapshot) { value, note in
                Task { await model.record(kind: .addNumeric(value: value), habitId: snapshot.id, note: note) }
            }
        }
        .sheet(isPresented: $showRetroactiveHabitPicker) {
            RetroactiveHabitPicker(model: model)
        }
        .sheet(item: selectedHistoryDayItemBinding) { day in
            HabitDayOverviewSheet(day: day.date, model: model, onOpenDetail: onOpenDetail)
        }
    }

    private var selectedHistoryDayItemBinding: Binding<HistoryDayItem?> {
        Binding(
            get: { selectedHistoryDay.map(HistoryDayItem.init) },
            set: { selectedHistoryDay = $0?.date }
        )
    }

    private struct HistoryDayItem: Identifiable {
        let date: Date
        var id: Date { date }
    }

    // MARK: 头部（日期 + 已记录数量）

    private var headerSection: some View {
        // 密度收紧（验收反馈 4）：日期与已记录数合并一行
        HStack(spacing: 6) {
            Text(dateLineText)
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
            Text("·")
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))
            Text(recordedLineText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(recordedLineColor)
        }
        .accessibilityElement(children: .combine)
    }

    private var dateLineText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMMd EEEE")
        return formatter.string(from: model.projectionNow)
    }

    private var recordedLineText: String {
        let total = model.todayRows.count
        guard total > 0 else {
            return String(localized: "还没有习惯在记录")
        }
        if model.recordedTodayCount == total {
            return String(localized: "已记录 \(total) 项，都留下了")
        }
        return String(localized: "已记录 \(model.recordedTodayCount) 项")
    }

    private var recordedLineColor: Color {
        if model.todayRows.isEmpty { return .holoToolTextSecondary }
        return model.recordedTodayCount == model.todayRows.count ? .holoPrimary : .holoToolTextSecondary
    }

    // MARK: 七天日期条（滚动七天，非自然周；未来不显示）

    private var weekStrip: some View {
        let calendar = Calendar.current
        let days = HabitPresentationProjector.rollingSevenDays(
            HabitProjectionData(recordsByHabit: [:], completedDaysByHabit: [:], dailyNumericByHabit: [:],
                                pauseWindowsByHabit: [:], now: model.projectionNow, calendar: calendar)
        )
        let today = calendar.startOfDay(for: model.projectionNow)

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                    let isToday = calendar.startOfDay(for: day) == today
                    let count = model.rollingSevenDayCounts[day] ?? 0
                    Button {
                        if !isToday {
                            selectedHistoryDay = day
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(dayLabel(day, calendar: calendar))
                                .font(.system(size: 10, weight: isToday ? .semibold : .regular))
                                .foregroundColor(isToday ? .white.opacity(0.85) : .holoToolTextSecondary)
                            Text(isToday ? String(localized: "今") : "\(count)")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundColor(isToday ? .white : (count > 0 ? .holoToolText : .holoToolTextSecondary.opacity(0.55)))
                        }
                        .frame(minWidth: 34, minHeight: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isToday ? Color.holoPrimary : Color.holoToolInset)
                        )
                    }
                    .buttonStyle(HoloPressStyle())
                    .disabled(isToday)
                    .accessibilityLabel(Text(fullDayAccessibility(day, count: count, isToday: isToday, calendar: calendar)))
                    .id(day)
                    }
                }
            }
            .padding(.vertical, 1)
            .onAppear {
                // 默认滚到今天（今天胶囊完整可见）
                proxy.scrollTo(today, anchor: .trailing)
            }
        }
    }

    private func dayLabel(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter.string(from: day)
    }

    private func fullDayAccessibility(_ day: Date, count: Int, isToday: Bool, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        let dateText = formatter.string(from: day)
        if isToday { return String(localized: "今天，已记录 \(count) 项") }
        return String(localized: "\(dateText)，已记录 \(count) 项")
    }

    // MARK: 快捷入口

    /// 筛选与快捷入口合并一行（验收反馈 4：密度）
    private var filterAndEntries: some View {
        HStack(spacing: 8) {
            filterChip(String(localized: "全部"), selected: model.todayFilter == .all) {
                model.todayFilter = .all
            }
            filterChip(String(localized: "未记录"), selected: model.todayFilter == .unrecorded) {
                model.todayFilter = .unrecorded
            }

            Spacer(minLength: 0)

            Button {
                showRetroactiveHabitPicker = true
            } label: {
                entryLabel(icon: "clock.arrow.circlepath",
                           text: String(localized: "补签"))
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("habit.today.retroactive")

            if model.pausedCount > 0 {
                Button {
                    onOpenPausedManagement()
                } label: {
                    entryLabel(icon: "pause.circle",
                               text: String(localized: "暂停 \(model.pausedCount)"))
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("habit.today.paused")
            }
        }
    }

    private func entryLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoToolText)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(Capsule().fill(Color.holoToolInset))
    }

    private func filterChip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .holoPrimary : .holoToolTextSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(
                    Capsule().fill(selected ? Color.holoPrimary.opacity(0.12) : Color.holoToolInset)
                )
        }
        .buttonStyle(HoloPressStyle())
    }

    // MARK: 分组标题

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.holoToolTextSecondary)
            .padding(.top, 2)
    }

    // MARK: 空状态（分形态，不伪装）

    @ViewBuilder
    private var emptyState: some View {
        if model.todayFilter == .unrecorded {
            VStack(spacing: HoloSpacing.md) {
                Text(String(localized: "今天的记录都留下了"))
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
                Button(String(localized: "查看全部")) {
                    model.todayFilter = .all
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if !model.pausedRows.isEmpty {
            // 无进行中但有暂停（§4.5）
            VStack(spacing: HoloSpacing.md) {
                Text(String(localized: "给日常留一点空隙"))
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
                Button {
                    onOpenPausedManagement()
                } label: {
                    Text(String(localized: "查看暂停习惯"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            // 从未创建
            VStack(spacing: HoloSpacing.md) {
                Text(String(localized: "建一个每天想留下痕迹的小事，从今天开始"))
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    onOpenAddHabit()
                } label: {
                    Text(String(localized: "创建第一个习惯"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("habit.today.createFirst")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - 测量输入弹层

/// 测量记录输入：有限非负数值（含真实 0），可选备注（方案 §8.2/§11.4）
struct HabitMeasureInputSheet: View {

    let snapshot: HabitRowSnapshot
    var onSave: (Double, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var note = ""
    @State private var errorMessage: String?
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            Text(String(localized: "记录\(snapshot.name)"))
                .font(.holoHeading)
                .foregroundColor(.holoToolText)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(unitPlaceholder, text: $valueText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundColor(.holoToolText)
                        .focused($valueFocused)
                        .accessibilityIdentifier("habit.measure.value")
                    if !unitText.isEmpty {
                        Text(unitText)
                            .font(.system(size: 15))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.holoError)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))

            TextField(String(localized: "备注（可选）"), text: $note)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .padding()
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))

            HStack(spacing: HoloSpacing.md) {
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "取消"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoToolText)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolInset))
                }
                .buttonStyle(HoloPressStyle())

                Button {
                    save()
                } label: {
                    Text(String(localized: "保存"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoToolOnAction)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("habit.record.save")
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.lg)
        .presentationDetents([.height(320)])
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { valueFocused = false }
            }
        }
        .onAppear { valueFocused = true }
    }

    private var unitText: String { snapshot.target?.unit ?? "" }

    private var unitPlaceholder: String {
        snapshot.kind == .measure ? String(localized: "输入今天的数值") : String(localized: "输入数量")
    }

    private func save() {
        // Locale 合法小数 + 有限值（方案 §11.4）；测量允许 0
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        guard let number = formatter.number(from: valueText.trimmingCharacters(in: .whitespaces)),
              let value = number as? Double, value.isFinite, value >= 0 else {
            errorMessage = String(localized: "请输入有效的数值（不能为空或负数）")
            valueFocused = true
            return
        }
        onSave(value, note.isEmpty ? nil : note)
        dismiss()
    }
}

// MARK: - 补签习惯选择

/// 首页补录入口：先选习惯，再进既有补签弹层（方案 §10.1）
private struct RetroactiveHabitPicker: View {

    @ObservedObject var model: HabitModuleViewModel
    @Environment(\.dismiss) private var dismiss

    /// 只提供支持的模式：好习惯（打卡/数值）且非归档（方案 §10.1 表格）
    private var eligibleRows: [HabitRowSnapshot] {
        model.todayRows.filter { !$0.isBadHabit }
    }

    var body: some View {
        NavigationStack {
            List(eligibleRows) { row in
                Button {
                    dismiss()
                    // 打开既有补签弹层（模式/日期由既有弹层承载）
                    PendingRetroactiveOpener.shared.open(habitId: row.id)
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        row.iconImage(size: 15)
                            .foregroundColor(Color(hex: row.colorHex))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .foregroundColor(.holoToolText)
                            Text(row.kind == .checkIn ? String(localized: "补签或补记") : String(localized: "补记历史数值"))
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(String(localized: "选择习惯"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 补签弹层的打开中转：习惯选择弹层 dismiss 后由宿主视图消费
/// （sheet 之上再开 sheet 需在非 sheet 层级触发）
@MainActor
final class PendingRetroactiveOpener: ObservableObject {
    static let shared = PendingRetroactiveOpener()
    @Published var habitId: UUID?
    func open(habitId: UUID) { self.habitId = habitId }
}

// MARK: - 当日回看弹层（日期条入口）

/// 某一天的记录总览（G2 简版：当日各习惯的记录状态与值；明细编辑入口在详情/日记录弹层）
private struct HabitDayOverviewSheet: View {

    let day: Date
    @ObservedObject var model: HabitModuleViewModel
    var onOpenDetail: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.todayRows) { row in
                    Button {
                        dismiss()
                        onOpenDetail(row.id)
                    } label: {
                        HStack {
                            row.iconImage(size: 14)
                                .foregroundColor(Color(hex: row.colorHex))
                                .frame(width: 26)
                            Text(row.name)
                                .foregroundColor(.holoToolText)
                            Spacer()
                            statusLabel(for: row)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        .presentationDetents([.medium])
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        return formatter.string(from: day)
    }

    @ViewBuilder
    private func statusLabel(for row: HabitRowSnapshot) -> some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let trail = row.trail.first { Calendar.current.startOfDay(for: $0.day) == dayStart }
        if let trail, trail.isRecorded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(hex: row.colorHex))
        } else {
            Text(String(localized: "无记录"))
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary.opacity(0.7))
        }
    }
}
