//
//  HabitManagementView.swift
//  Holo
//
//  管理页（2026-10 重构）：进行中 / 已暂停 / 已归档三分组（同一批有效习惯），
//  恢复按钮直接可见；更多动作用尾部菜单。排序/展示设置/提醒/数据管理入口集中。
//

import SwiftUI

struct HabitManagementView: View {

    @ObservedObject var model: HabitModuleViewModel
    /// 从今天页「暂停管理」进入时选中已暂停分组
    var initialSection: HabitModuleViewModel.Tab? = nil
    let onOpenDetail: (UUID) -> Void
    let onEditHabit: (Habit) -> Void
    let onOpenStatsSettings: () -> Void
    let onOpenStats: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case active, paused, archived
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .active: return String(localized: "进行中")
            case .paused: return String(localized: "已暂停")
            case .archived: return String(localized: "已归档")
            }
        }
    }

    @State private var selectedSection: Section = .active
    @State private var pauseTarget: Habit?
    @State private var showDataManagement = false
    @State private var showReminders = false
    @ObservedObject private var entitlement = HoloEntitlementState.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.md) {
                sectionPicker

                switch selectedSection {
                case .active: habitSection(model.todayRows, section: .active)
                case .paused: habitSection(model.pausedRows, section: .paused)
                case .archived: habitSection(model.archivedRows, section: .archived)
                }

                maintenanceEntries
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 40)
        }
        .onAppear {
            if let initialSection, initialSection == .manage {
                selectedSection = .paused
            }
        }
        .sheet(item: $pauseTarget) { habit in
            HabitPauseSheet(habit: habit)
        }
        .sheet(isPresented: $showDataManagement) {
            // 复用既有模块清空（30 天回收站）与最近删除能力（方案 §6.3）
            NavigationStack { ModuleClearSheet(module: .habit) }
        }
        .sheet(isPresented: $showReminders) {
            HabitReminderDetailView()
        }
    }

    // MARK: 分组切换

    private var sectionPicker: some View {
        HStack(spacing: 8) {
            ForEach(Section.allCases) { section in
                let count = rowCount(for: section)
                Button {
                    withAnimation(HoloAnimation.quick) { selectedSection = section }
                } label: {
                    HStack(spacing: 5) {
                        Text(section.displayName)
                        Text("\(count)")
                            .font(.system(size: 12).monospacedDigit())
                    }
                    .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                    .foregroundColor(selectedSection == section ? .holoPrimary : .holoToolTextSecondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(
                        Capsule().fill(selectedSection == section ? Color.holoPrimary.opacity(0.12) : Color.holoToolInset)
                    )
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("habit.manage.section.\(section.rawValue)")
            }
            Spacer()
        }
    }

    private func rowCount(for section: Section) -> Int {
        switch section {
        case .active: return model.todayRows.count
        case .paused: return model.pausedRows.count
        case .archived: return model.archivedRows.count
        }
    }

    // MARK: 习惯行

    @ViewBuilder
    private func habitSection(_ rows: [HabitRowSnapshot], section: Section) -> some View {
        if rows.isEmpty {
            Text(emptyText(for: section))
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary.opacity(0.8))
                .padding(.vertical, 24)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    managementRow(row, section: section)
                }
            }
        }
    }

    private func emptyText(for section: Section) -> String {
        switch section {
        case .active: return String(localized: "没有进行中的习惯；创建或取消归档一个开始")
        case .paused: return String(localized: "没有暂停中的习惯")
        case .archived: return String(localized: "没有已归档的习惯；归档不会删除任何历史")
        }
    }

    private func managementRow(_ row: HabitRowSnapshot, section: Section) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                onOpenDetail(row.id)
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    row.iconImage(size: 16)
                        .foregroundColor(Color(hex: row.colorHex))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: row.colorHex).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.holoBody.weight(.medium))
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)
                        Text(managementSubtitle(row, section: section))
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if section == .paused {
                Button {
                    try? HabitRepository.shared.resumeHabitById(row.id)
                } label: {
                    Text(String(localized: "恢复"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: row.colorHex))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Capsule().fill(Color(hex: row.colorHex).opacity(0.12)))
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("habit.manage.resume.\(row.id)")
            }

            Menu {
                menuActions(row, section: section)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(Text(String(localized: "\(row.name)的更多操作")))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.6))
                .frame(height: 0.5)
        }
    }

    private func managementSubtitle(_ row: HabitRowSnapshot, section: Section) -> String {
        var parts: [String] = []
        switch row.kind {
        case .checkIn: parts.append(String(localized: "打卡"))
        case .count: parts.append(String(localized: "计数"))
        case .measure: parts.append(String(localized: "测量"))
        }
        parts.append(row.frequency.displayName)
        switch section {
        case .paused:
            parts.append(row.pauseSummaryText ?? String(localized: "暂停中"))
        case .archived:
            parts.append(String(localized: "已归档"))
        case .active:
            break
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func menuActions(_ row: HabitRowSnapshot, section: Section) -> some View {
        Button(String(localized: "编辑")) {
            if let habit = HabitRepository.shared.findHabit(by: row.id) {
                onEditHabit(habit)
            }
        }
        Button(String(localized: "查看详情")) {
            onOpenDetail(row.id)
        }

        Divider()

        switch section {
        case .active:
            Button(String(localized: "暂停")) { requestPause(row) }
            Button(String(localized: "归档"), role: .destructive) {
                try? HabitRepository.shared.archiveHabitById(row.id)
            }
        case .paused:
            Button(String(localized: "恢复")) {
                try? HabitRepository.shared.resumeHabitById(row.id)
            }
            Button(String(localized: "归档"), role: .destructive) {
                try? HabitRepository.shared.archiveHabitById(row.id)
            }
        case .archived:
            Button(String(localized: "取消归档")) {
                try? HabitRepository.shared.unarchiveHabitById(row.id)
            }
        }
    }

    // MARK: 暂停（Plus 契约：真实权益确认后才开弹层）

    private func requestPause(_ row: HabitRowSnapshot) {
        guard let habit = HabitRepository.shared.findHabit(by: row.id) else { return }
        if entitlement.isPlusActive {
            pauseTarget = habit
        } else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .habitPause) {
                await MainActor.run {
                    pauseTarget = HabitRepository.shared.findHabit(by: row.id)
                }
            }
        }
    }

    // MARK: 维护入口（排序/展示设置/详细统计；数据管理与提醒 G3 接）

    private var maintenanceEntries: some View {
        VStack(spacing: 0) {
            entryRow(icon: "arrow.up.arrow.down", text: String(localized: "今天列表排序")) {
                // G3：显式排序编辑模式（拖动）；主列表排序事实源 = Habit.sortOrder
            }
            entryRow(icon: "eye", text: String(localized: "回顾展示设置")) {
                onOpenStatsSettings()
            }
            entryRow(icon: "chart.bar", text: String(localized: "详细统计")) {
                onOpenStats()
            }
            entryRow(icon: "bell", text: String(localized: "提醒设置")) {
                showReminders = true
            }
            entryRow(icon: "trash", text: String(localized: "数据管理")) {
                showDataManagement = true
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolSurface)
        )
        .padding(.top, HoloSpacing.md)
    }

    private func entryRow(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 24)
                Text(text)
                    .font(.holoBody)
                    .foregroundColor(.holoToolText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            }
            .padding(.horizontal, HoloSpacing.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
