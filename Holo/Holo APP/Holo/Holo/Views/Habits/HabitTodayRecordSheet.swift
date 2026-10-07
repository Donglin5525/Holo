//
//  HabitTodayRecordSheet.swift
//  Holo
//
//  「今天的记录」弹层（V2 §5.2）：习惯名 + 完整日期 → 今日合计/最新值 →
//  今天每条记录（时间/值/备注/补录标识，可编辑可删除）→ 主动作 → 习惯设置入口。
//  不含月历、趋势、时间范围切换和累计仪表盘。
//

import SwiftUI
import CoreData

struct HabitTodayRecordSheet: View {

    /// 目标习惯（仅持 id；快照数据从模型取，弹层生命周期内自动刷新）
    let habitId: UUID
    @ObservedObject var model: HabitModuleViewModel
    /// 打开习惯设置（容器接 AddHabitSheet 编辑态）
    var onOpenSettings: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dayRecords: [HabitRecord] = []

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
                        recordsSection(row)
                        primaryAction(row)
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
            .navigationTitle(String(localized: "今天的记录"))
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

    // MARK: 今日合计 / 最新值

    private func todaySummary(_ row: HabitRowSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(todayValueText(row))
                    .font(.system(size: 25, weight: .semibold).monospacedDigit())
                    .foregroundColor(.holoToolText)
                Text(subtitleText(row))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { separatorLine }
        .overlay(alignment: .bottom) { separatorLine }
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
                Text(row.lifecycle == .active
                     ? String(localized: "今天还没有记录，可以从这里开始。")
                     : String(localized: "今天还没有记录。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.holoToolInset))
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
    }

    private func findRecord(_ recordId: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        return try? HabitRepository.shared.context.fetch(request).first
    }
}
