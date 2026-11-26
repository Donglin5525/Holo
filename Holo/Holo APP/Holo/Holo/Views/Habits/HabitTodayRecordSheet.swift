//
//  HabitTodayRecordSheet.swift
//  Holo
//
//  习惯今日详情抽屉（2026-11-19 V3 重构）：
//  顶部去重（居中日期/结算口径 + 左关闭 + 右 ··· 管理）；
//  身份区（图标 + 名称 + 今日状态 + 规则胶囊 + 描述）→ 3 列核心 KPI 卡片
//  → 交互式本月日历/近30天/数值走势卡片（点按日期查看明细与内联补录，复用 HoloBarChart/HoloMiniTrendChart）
//  → 纯本地节律观察（稀疏态自动降级为温和里程碑提示）
//  → 今天的记录 / 最近记录（支持行内快速写备注）→ 贴底主操作栏（打卡后主区转写备注，撤销退居侧边；计数型支持底栏直加直减）。
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
    /// 计数/测量主输入通道（容器侧挂 HabitMeasureInputSheet）
    var onRequestMeasureInput: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: 数据快照状态

    @State private var dayRecords: [HabitRecord] = []
    @State private var recentRecords: [HabitRecord] = []
    @State private var monthSnapshot: HabitRangeSnapshot?
    @State private var prevMonthSnapshot: HabitRangeSnapshot?
    @State private var last30Snapshot: HabitRangeSnapshot?
    @State private var recentNumericSnapshot: HabitRangeSnapshot?
    @State private var allTimeSnapshot: HabitRangeSnapshot?
    @State private var detailMeta = HabitTodayDetailMeta(
        reminderText: nil,
        folderName: nil,
        dayEndMinutes: 0,
        createdAt: Date()
    )
    /// 本月每日备注与打卡时刻（值快照，供日历点按明细条使用，不在 body 查库）
    @State private var dayNotes: [Date: String] = [:]
    @State private var dayTimes: [Date: String] = [:]

    @State private var drawerDetent: PresentationDetent = .large

    // MARK: 行内备注输入

    @State private var isEditingInlineNote = false
    @State private var inlineNoteDraft = ""
    @FocusState private var inlineNoteFocused: Bool

    // MARK: 生命周期与二级弹层状态（各挂独立节点，避免同节点双 sheet 互吞）

    @State private var pauseTarget: Habit? = nil
    @State private var pendingLifecycleAction: LifecycleAction? = nil
    @State private var sourceRoute: HabitSourceRoute?
    @State private var editingRecord: EditTarget?
    @State private var pendingDeleteRecordId: UUID?
    @State private var showDeleteConfirm = false
    @State private var retroTarget: HabitRetroactiveSheetContext? = nil
    @ObservedObject private var entitlement = HoloEntitlementState.shared

    private enum LifecycleAction: Identifiable {
        case archive, delete
        var id: Int { self == .archive ? 0 : 1 }
    }

    private struct EditTarget: Identifiable {
        let recordId: UUID
        var id: UUID { recordId }
    }

    private var row: HabitRowSnapshot? {
        model.todayRows.first { $0.id == habitId }
            ?? model.pausedRows.first { $0.id == habitId }
            ?? model.archivedRows.first { $0.id == habitId }
    }

    private var habitToday: Date {
        let calendar = Calendar.current
        guard let snapshot = allTimeSnapshot ?? monthSnapshot else {
            return calendar.startOfDay(for: model.projectionNow)
        }
        return snapshot.attributedDay(model.projectionNow, calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let row {
                        let summary = HabitTodayDetailSummary.build(
                            row: row,
                            meta: detailMeta,
                            monthSnapshot: monthSnapshot,
                            prevMonthSnapshot: prevMonthSnapshot,
                            last30Snapshot: last30Snapshot,
                            allTimeSnapshot: allTimeSnapshot,
                            today: habitToday
                        )
                        identityHeader(row, chips: summary.chips)
                        if !summary.kpis.isEmpty {
                            HabitTodayKPICard(
                                kpis: summary.kpis,
                                accent: Color(hex: row.colorHex),
                                countProgress: summary.countProgress
                            )
                        }
                        HabitTodayVizCard(
                            row: row,
                            monthSnapshot: monthSnapshot,
                            last30Snapshot: last30Snapshot,
                            recentNumericSnapshot: recentNumericSnapshot,
                            projectionNow: model.projectionNow,
                            habitToday: habitToday,
                            dayNotes: dayNotes,
                            dayTimes: dayTimes,
                            onOpenReview: {
                                dismiss()
                                onOpenReview(habitId)
                            },
                            onRequestRetroactive: row.kind == .checkIn && row.lifecycle == .active
                                ? { day in openRetroactive(preselectedDay: day) }
                                : nil
                        )
                        if (allTimeSnapshot?.recordedDayCount ?? 0) > 0 {
                            HabitTodayRhythmStrip(
                                model: summary.rhythm,
                                accent: Color(hex: row.colorHex)
                            )
                        }
                        if (allTimeSnapshot?.recordedDayCount ?? 0) > 0 || !dayRecords.isEmpty {
                            recordsSection(row)
                        }
                    } else {
                        Text(String(localized: "这个习惯已不可用"))
                            .holoText(.body)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.xs)
                .padding(.bottom, HoloSpacing.lg)
                .sheet(item: $retroTarget) { context in
                    HabitRetroactiveSheet(context: context)
                }
            }
            .background(Color.holoToolBackground)
            .safeAreaInset(edge: .bottom) {
                if let row {
                    primaryAction(row)
                }
            }
            .navigationTitle("")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.holoToolBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text(navDateBadgeText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                }
                ToolbarItem(placement: .primaryAction) {
                    lifecycleMenu
                }
            }
            .sheet(item: $pauseTarget) { habit in
                HabitPauseSheet(habit: habit, onPaused: { dismiss() })
            }
            .confirmationDialog(
                lifecycleConfirmTitle,
                isPresented: Binding(
                    get: { pendingLifecycleAction != nil },
                    set: { if !$0 { pendingLifecycleAction = nil } }
                ),
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
        .holoSheetShell()
        .presentationDetents([.medium, .large], selection: $drawerDetent)
        .presentationDragIndicator(.visible)
        .onAppear { reloadRecords() }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            reloadRecords()
        }
        .sheet(item: $sourceRoute) { route in HabitSourceDetailView(route: route) }
        .sheet(item: $editingRecord) { target in
            if let record = findRecord(target.recordId) {
                HabitRecordEditSheet(
                    record: record,
                    kind: row?.kind ?? .checkIn,
                    unit: row?.unit
                ) { value, note in
                    await model.record(
                        kind: .updateRecord(recordId: target.recordId, value: value, note: note),
                        habitId: habitId
                    )
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

    // MARK: 导航日期胶囊

    private static let navDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日 EEE")
        return formatter
    }()

    private var navDateBadgeText: String {
        let dateText = Self.navDateFormatter.string(from: habitToday)
        guard detailMeta.dayEndMinutes != 0 else { return dateText }
        let cutoff = HabitDayAttribution.displayText(
            hour: detailMeta.dayEndMinutes / 60,
            minute: detailMeta.dayEndMinutes % 60
        )
        return String(localized: "\(dateText) · \(cutoff) 结算")
    }

    // MARK: 1. 身份头部（图标 + 名称 + 今日状态胶囊 + 规则标签 + 描述）

    private func identityHeader(_ row: HabitRowSnapshot, chips: [String]) -> some View {
        let accent = Color(hex: row.colorHex)
        return HStack(alignment: .top, spacing: 13) {
            row.iconImage(size: 21)
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.13))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: HoloSpacing.sm) {
                    Text(row.name)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(2)
                    todayStatusBadge(row)
                }

                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.holoToolInset)
                                )
                        }
                    }
                }

                if let description = row.habitDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func todayStatusBadge(_ row: HabitRowSnapshot) -> some View {
        if row.lifecycle != .active {
            let label = row.lifecycle == .paused ? String(localized: "已暂停") : String(localized: "已归档")
            statusPill(label, text: .holoToolTextSecondary, bg: Color.holoToolInset)
        } else if row.kind == .checkIn {
            if row.isBadHabit {
                if row.today.isRecorded {
                    statusPill(String(localized: "今日已发生"), text: .holoToolError, bg: Color.holoToolError.opacity(0.1))
                } else {
                    statusPill(String(localized: "今日未发生"), text: .holoToolSuccess, bg: Color.holoToolSuccess.opacity(0.1))
                }
            } else if row.today.isRecorded {
                statusPill(String(localized: "今日已打卡"), text: .holoToolSuccess, bg: Color.holoToolSuccess.opacity(0.1))
            } else {
                statusPill(String(localized: "今日待打卡"), text: .holoToolTextSecondary, bg: Color.holoToolInset)
            }
        } else if row.today.isRecorded {
            statusPill(String(localized: "今日已记"), text: .holoToolSuccess, bg: Color.holoToolSuccess.opacity(0.1))
        } else {
            statusPill(String(localized: "今日未记"), text: .holoToolTextSecondary, bg: Color.holoToolInset)
        }
    }

    private func statusPill(_ title: String, text: Color, bg: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }

    // MARK: 2. 记录与备注列表

    private func recordsSection(_ row: HabitRowSnapshot) -> some View {
        let showsRecent = dayRecords.isEmpty
        let records = showsRecent ? recentRecords : dayRecords
        let accent = Color(hex: row.colorHex)

        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Text(showsRecent ? String(localized: "最近的记录") : String(localized: "今天的记录"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                    if !records.isEmpty {
                        Text(String(localized: "\(records.count) 条"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.holoToolInset))
                    }
                }
                Spacer()
                if dayRecords.count == 1, row.lifecycle == .active, !(row.kind == .checkIn && !row.isBadHabit) {
                    Button {
                        openInlineNoteComposer()
                    } label: {
                        Text(String(localized: "+ 写备注"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(accent)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 0) {
                if records.isEmpty {
                    Text(String(localized: "还没有记录，点击下方按钮开始第一笔。"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                } else {
                    let renderable = records.renderable
                    ForEach(Array(renderable.enumerated()), id: \.element.id) { index, record in
                        recordRow(record, row: row, showsDate: showsRecent, showDivider: index < renderable.count - 1)
                    }
                }

                if isEditingInlineNote {
                    inlineNoteComposer(accent: accent)
                }
            }
            .holoSurface(.independent)
        }
    }

    private func recordRow(_ record: HabitRecord, row: HabitRowSnapshot, showsDate: Bool, showDivider: Bool) -> some View {
        let accent = Color(hex: row.colorHex)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                Button {
                    editingRecord = EditTarget(recordId: record.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if showsDate {
                                Text(shortDate(record.date))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.holoToolTextSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.holoToolInset))
                            }
                            Text(record.formattedTime)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color.holoToolTextSecondary)
                            if record.isRetroactive {
                                Text(String(localized: "补录"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(accent.opacity(0.4))
                                    )
                            }
                        }

                        Text(recordTitle(record, row: row))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Color.holoToolText)

                        if let note = record.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                                        .fill(Color.holoToolInset.opacity(0.65))
                                )
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button(String(localized: "记录明细与每日确认")) {
                        sourceRoute = .recent(habitId)
                    }
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
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if showDivider {
                Rectangle()
                    .fill(Color.holoToolBorder.opacity(0.65))
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)
            }
        }
    }

    private func inlineNoteComposer(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.65))
                .frame(height: 0.5)

            TextField(String(localized: "记录一点此刻的感受或细节…"), text: $inlineNoteDraft, axis: .vertical)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1...4)
                .focused($inlineNoteFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.holoToolSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button(String(localized: "取消")) {
                    withAnimation(HoloAnimation.quick) {
                        isEditingInlineNote = false
                        inlineNoteFocused = false
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Button(String(localized: "保存备注")) {
                    saveInlineNote()
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous).fill(accent))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(Color.holoToolInset.opacity(0.5))
    }

    private func openInlineNoteComposer() {
        inlineNoteDraft = dayRecords.renderable.first?.note ?? ""
        withAnimation(HoloAnimation.quick) {
            isEditingInlineNote = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            inlineNoteFocused = true
        }
    }

    private func saveInlineNote() {
        guard let target = dayRecords.renderable.first else {
            isEditingInlineNote = false
            return
        }
        let trimmed = inlineNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordId = target.id
        let value = target.value?.doubleValue
        withAnimation(HoloAnimation.quick) {
            isEditingInlineNote = false
            inlineNoteFocused = false
        }
        Task {
            await model.record(
                kind: .updateRecord(recordId: recordId, value: value, note: trimmed.isEmpty ? nil : trimmed),
                habitId: habitId
            )
            HapticManager.success()
        }
    }

    private func recordTitle(_ record: HabitRecord, row: HabitRowSnapshot) -> String {
        if row.kind == .checkIn {
            return record.isCompleted
                ? (row.isBadHabit ? String(localized: "记录发生") : String(localized: "已完成打卡"))
                : String(localized: "已取消")
        }
        return record.formattedValue(unit: row.unit)
    }

    // MARK: 3. 贴底主操作栏（打卡后主区转写备注，撤销退居侧边；计数型支持底栏直加直减）

    @ViewBuilder
    private func primaryAction(_ row: HabitRowSnapshot) -> some View {
        if row.lifecycle == .active {
            let accent = Color(hex: row.colorHex)
            let isSaving = model.coordinator.savingHabitIds.contains(habitId)

            HStack(spacing: 10) {
                switch row.kind {
                case .checkIn where !row.isBadHabit:
                    if row.today.isRecorded {
                        Button {
                            openInlineNoteComposer()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(String(localized: "今日已完成 · 写条备注"))
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.holoToolSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(accent.opacity(0.5), lineWidth: 1)
                            )
                        }
                        .buttonStyle(HoloPressStyle())
                        .accessibilityIdentifier("habit.todayrecord.primary")

                        Button {
                            HapticManager.medium()
                            Task { await model.record(kind: .toggleCheckIn, habitId: habitId) }
                        } label: {
                            Text(String(localized: "撤销"))
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .padding(.horizontal, 14)
                                .frame(minWidth: 56, minHeight: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(Color.holoToolInset)
                                )
                        }
                        .buttonStyle(HoloPressStyle())
                    } else {
                        Button {
                            HapticManager.medium()
                            Task { await model.record(kind: .toggleCheckIn, habitId: habitId) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(String(localized: "完成今天打卡"))
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(accent)
                            )
                        }
                        .buttonStyle(HoloPressStyle())
                        .accessibilityIdentifier("habit.todayrecord.primary")

                        Button {
                            openRetroactive(preselectedDay: nil)
                        } label: {
                            Text(String(localized: "补录"))
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.holoToolText)
                                .padding(.horizontal, 14)
                                .frame(minWidth: 56, minHeight: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(Color.holoToolSurface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(HoloPressStyle())
                    }

                case .checkIn:
                    // 坏习惯（克制视角）
                    Button {
                        HapticManager.light()
                        Task { await model.record(kind: .toggleCheckIn, habitId: habitId) }
                    } label: {
                        Text(row.today.isRecorded
                             ? String(localized: "撤销今日发生记录")
                             : String(localized: "如实记录今天发生"))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(row.today.isRecorded ? Color.holoToolText : accent)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(row.today.isRecorded ? Color.holoToolInset : accent.opacity(0.13))
                            )
                    }
                    .buttonStyle(HoloPressStyle())
                    .accessibilityIdentifier("habit.todayrecord.primary")

                case .count:
                    Button {
                        HapticManager.light()
                        Task { await model.record(kind: .removeLatestNumeric, habitId: habitId) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(row.today.isRecorded ? Color.holoToolText : Color.holoToolTextSecondary)
                            .frame(width: 48, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.holoToolSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(HoloPressStyle())
                    .disabled(!row.today.isRecorded)

                    Button {
                        HapticManager.light()
                        Task { await model.record(kind: .increment(amount: 1), habitId: habitId) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            Text(row.unit.isEmpty ? String(localized: "记 1 次") : "1 \(row.unit)")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(accent)
                        )
                    }
                    .buttonStyle(HoloPressStyle())
                    .accessibilityIdentifier("habit.todayrecord.primary")

                    Button {
                        dismiss()
                        onRequestMeasureInput?(habitId)
                    } label: {
                        Text(String(localized: "记一笔"))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.holoToolText)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.holoToolSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(HoloPressStyle())

                case .measure:
                    Button {
                        dismiss()
                        onRequestMeasureInput?(habitId)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            Text(row.today.isRecorded
                                 ? String(localized: "再记录一次数值")
                                 : String(localized: "记录今天的数值"))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(accent)
                        )
                    }
                    .buttonStyle(HoloPressStyle())
                    .accessibilityIdentifier("habit.todayrecord.primary")
                }
            }
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.sm)
            .padding(.horizontal, HoloSpacing.page)
            .background(.ultraThinMaterial)
            .disabled(isSaving)
        }
    }

    // MARK: ··· 管理菜单

    private var lifecycleMenu: some View {
        Menu {
            Button {
                dismiss()
                onOpenSettings(habitId)
            } label: {
                Label(String(localized: "习惯设置"), systemImage: "slider.horizontal.3")
            }
            if row?.kind == .checkIn, row?.lifecycle == .active {
                Button {
                    openRetroactive(preselectedDay: nil)
                } label: {
                    Label(String(localized: "补录"), systemImage: "clock.arrow.circlepath")
                }
            }
            Button {
                dismiss()
                onOpenReview(habitId)
            } label: {
                Label(String(localized: "完整回顾"), systemImage: "chart.line.uptrend.xyaxis")
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
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(String(localized: "习惯管理")))
        .accessibilityIdentifier("habit.todayrecord.manage")
    }

    private func openRetroactive(preselectedDay: Date?) {
        guard let habit = HabitRepository.shared.findHabit(by: habitId) else { return }
        retroTarget = HabitRetroactiveSheetContext(
            habit: habit,
            preselectedDay: preselectedDay,
            mode: .sign
        )
    }

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

    // MARK: 数据加载与快照构建

    private func reloadRecords() {
        guard let habit = HabitRepository.shared.findHabit(by: habitId) else {
            dayRecords = []
            recentRecords = []
            monthSnapshot = nil
            prevMonthSnapshot = nil
            last30Snapshot = nil
            recentNumericSnapshot = nil
            allTimeSnapshot = nil
            dayNotes = [:]
            dayTimes = [:]
            return
        }

        dayRecords = HabitRepository.shared.getTodayRecords(for: habit)

        let reminderText: String? = {
            guard habit.isCheckInType, habit.habitReminderMode == .solo else { return nil }
            let t = habit.reminderTime
            return String(format: "%02d:%02d", t.hour, t.minute)
        }()
        detailMeta = HabitTodayDetailMeta(
            reminderText: reminderText,
            folderName: nil,
            dayEndMinutes: habit.dayEndMinutes,
            createdAt: habit.createdAt
        )

        let lifecycle: HabitLifecycle = {
            if habit.isArchived { return .archived }
            return habit.isPaused ? .paused : .active
        }()
        let info = HabitReviewHabitInfo(habit: habit, lifecycle: lifecycle)
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([habitId]),
            dayEndMinutesByHabit: [habitId: habit.dayEndMinutes],
            now: model.projectionNow
        )

        let calendar = Calendar.current
        let attributedToday = HabitDayAttribution.attributedDay(
            model.projectionNow,
            dayEndMinutes: habit.dayEndMinutes,
            calendar: calendar
        )
        let currentMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: attributedToday)
        ) ?? attributedToday
        let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonthStart) ?? currentMonthStart

        monthSnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .month(currentMonthStart), data: data)
        prevMonthSnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .month(prevMonthStart), data: data)
        last30Snapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .lastDays(30), data: data)
        recentNumericSnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .recentRecords(count: 10), data: data)
        allTimeSnapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .all, data: data)

        refreshRecentRecords()
        refreshMonthDayMetadata(dayEndMinutes: habit.dayEndMinutes)
    }

    private func refreshRecentRecords() {
        guard dayRecords.isEmpty, let snapshot = allTimeSnapshot else {
            recentRecords = []
            return
        }
        let latestFacts = snapshot.records.sorted { $0.date > $1.date }.prefix(3)
        recentRecords = latestFacts.compactMap { findRecord($0.id) }
    }

    private func refreshMonthDayMetadata(dayEndMinutes: Int) {
        guard let monthSnapshot else {
            dayNotes = [:]
            dayTimes = [:]
            return
        }
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var notes: [Date: String] = [:]
        var times: [Date: String] = [:]

        for fact in monthSnapshot.records {
            let dayStart = calendar.startOfDay(for: fact.date)
            times[dayStart] = timeFormatter.string(from: fact.recordedAt)
            if let record = findRecord(fact.id), let note = record.note, !note.isEmpty {
                notes[dayStart] = note
            }
        }
        dayNotes = notes
        dayTimes = times
    }

    private func findRecord(_ recordId: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        return try? HabitRepository.shared.context.fetch(request).first
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter
    }()

    private func shortDate(_ date: Date) -> String {
        Self.shortDateFormatter.string(from: date)
    }
}
