//
//  HabitModuleOptionsSheet.swift
//  Holo
//
//  更多选项（V2 §4/§8）：低频能力的确定位置，不占主导航页签。
//  已暂停与已归档 / 今天列表排序 / 回顾展示与顺序 / 今日看板展示 /
//  提醒设置 / 数据管理。二级页面在弹层内导航；关闭返回打开它的位置。
//

import SwiftUI

/// 更多弹层打开后直接进入的二级页（今天页「已暂停 N 项」→ 名单）
enum HabitModuleOptionsSheetInitial: Hashable {
    case lifecycle
}

struct HabitModuleOptionsSheet: View {

    @ObservedObject var model: HabitModuleViewModel
    var initialPage: HabitModuleOptionsSheetInitial? = nil
    /// 点暂停/归档名单里的习惯名 → 查看其回顾（不要求恢复，§8）
    var onOpenSingleReview: (UUID) -> Void
    /// 打开习惯设置（编辑表单）
    var onOpenSettings: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path: [Page] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    Text(String(localized: "记录和回顾各有位置，低频调整放在这里。"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)

                    optionRow(icon: "archivebox",
                              title: String(localized: "已暂停与已归档"),
                              subtitle: String(localized: "历史保留，可以随时找回"),
                              identifier: "habit.options.lifecycle") {
                        navigate(.lifecycle)
                    }
                    optionRow(icon: "arrow.up.arrow.down",
                              title: String(localized: "今天列表排序"),
                              subtitle: String(localized: "只调整进行中的习惯"),
                              identifier: "habit.options.sort") {
                        navigate(.sort)
                    }
                    optionRow(icon: "eye",
                              title: String(localized: "回顾展示与顺序"),
                              subtitle: String(localized: "汇总和列表使用同一个范围"),
                              identifier: "habit.options.reviewVisibility") {
                        navigate(.reviewVisibility)
                    }
                    optionRow(icon: "checkmark.circle",
                              title: String(localized: "今日看板展示"),
                              subtitle: String(localized: "单独控制首页看板的展示"),
                              identifier: "habit.options.dashboardVisibility") {
                        navigate(.dashboardVisibility)
                    }
                    optionRow(icon: "bell",
                              title: String(localized: "提醒设置"),
                              subtitle: String(localized: "仅打卡型习惯支持提醒"),
                              identifier: "habit.options.reminders") {
                        navigate(.reminders)
                    }
                    optionRow(icon: "trash",
                              title: String(localized: "数据管理"),
                              subtitle: String(localized: "清空进最近删除，30 天内可恢复"),
                              identifier: "habit.options.data") {
                        navigate(.data)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, 30)
            }
            .background(Color.holoToolBackground)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .lifecycle: LifecycleListPage(model: model,
                                                   onOpenSingleReview: onOpenSingleReview,
                                                   onOpenSettings: onOpenSettings)
                case .sort: SortPage(model: model)
                case .reviewVisibility: VisibilityPage(model: model, kind: .review)
                case .dashboardVisibility: VisibilityPage(model: model, kind: .dashboard)
                case .reminders: HabitReminderDetailView()
                case .data: DataManagementPage()
                }
            }
            .navigationTitle(String(localized: "更多选项"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
            }
            .onAppear {
                if let initialPage, path.isEmpty {
                    switch initialPage {
                    case .lifecycle: path.append(.lifecycle)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    enum Page: Hashable {
        case lifecycle, sort, reviewVisibility, dashboardVisibility, reminders, data
    }

    private func navigate(_ page: Page) {
        path.append(page)
    }

    private func optionRow(icon: String, title: String, subtitle: String,
                           identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.holoToolBorder.opacity(0.6)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 已暂停与已归档

private struct LifecycleListPage: View {

    @ObservedObject var model: HabitModuleViewModel
    var onOpenSingleReview: (UUID) -> Void
    var onOpenSettings: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "它们暂时离开今天，过去的记录仍然可看。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .padding(.bottom, 10)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.holoError)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.holoError.opacity(0.08)))
                        .padding(.bottom, 10)
                }

                sectionHeader(String(localized: "已暂停 \(model.pausedRows.count) 项"))
                if model.pausedRows.isEmpty {
                    Text(String(localized: "没有暂停中的习惯"))
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(model.pausedRows) { row in
                        lifecycleRow(row, isPausedList: true)
                    }
                }

                sectionHeader(String(localized: "已归档 \(model.archivedRows.count) 项"))
                if model.archivedRows.isEmpty {
                    Text(String(localized: "没有归档的习惯"))
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(model.archivedRows) { row in
                        lifecycleRow(row, isPausedList: false)
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, 30)
        }
        .background(Color.holoToolBackground)
        .navigationTitle(String(localized: "已暂停与已归档"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.holoToolTextSecondary)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func lifecycleRow(_ row: HabitRowSnapshot, isPausedList: Bool) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                // 点名称查看历史（不要求恢复，§8）；先关弹层再进单习惯回顾
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onOpenSingleReview(row.id)
                }
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    row.iconImage(size: 16)
                        .foregroundColor(Color(hex: row.colorHex))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: row.colorHex).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)
                        Text(isPausedList
                             ? (row.pauseSummaryText ?? String(localized: "暂停中")) + " · " + String(localized: "查看回顾")
                             : String(localized: "历史记录保留") + " · " + String(localized: "查看回顾"))
                            .font(.system(size: 11))
                            .foregroundColor(.holoToolTextSecondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // 恢复/取消归档直接可见；失败给明确错误（A16），原状态保留
            Button {
                performLifecycleAction(row, isPausedList: isPausedList)
            } label: {
                Text(isPausedList ? String(localized: "恢复") : String(localized: "取消归档"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: row.colorHex))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(
                        Capsule().fill(Color(hex: row.colorHex).opacity(0.12))
                    )
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("habit.lifecycle.\(row.id)")

            Button {
                onOpenSettings(row.id)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "\(row.name)设置")))
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder.opacity(0.6)).frame(height: 0.5)
        }
    }

    /// 恢复/取消归档：成功刷新名单；失败说明原因且原状态保留（A16）
    private func performLifecycleAction(_ row: HabitRowSnapshot, isPausedList: Bool) {
        do {
            if isPausedList {
                try HabitRepository.shared.resumeHabitById(row.id)
            } else {
                try HabitRepository.shared.unarchiveHabitById(row.id)
            }
            errorMessage = nil
            model.refresh()
        } catch {
            errorMessage = String(localized: "操作没有成功，状态保持原样。请重试。")
        }
    }
}

// MARK: - 今天列表排序

/// 排序弹层（管理页「今天列表排序」入口）：长按拖拽 + 上下箭头双通道，
/// 共用一套会话顺序与让位动画（HabitListReorderModel），保存统一走
/// repository.persistTodayOrder（穿插合并，不覆盖暂停/归档相对顺序）。
struct SortPage: View {

    @ObservedObject var model: HabitModuleViewModel
    @Environment(\.dismiss) private var dismiss

    /// 弹层打开时的底序快照（弹层期间外部刷新不侵入草稿）
    @State private var baselineIds: [UUID] = []
    @State private var errorMessage: String?
    @StateObject private var reorder = HabitListReorderModel()

    private var draftIds: [UUID] {
        reorder.effectiveIds(.sortSheet, baseline: baselineIds)
    }

    private var rowsById: [UUID: HabitRowSnapshot] {
        Dictionary(uniqueKeysWithValues: model.todayRows.map { ($0.id, $0) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "长按拖动习惯，或使用上下箭头。保存后改变今天的顺序，回顾顺序独立保留。"))
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.holoError)
                    }

                    if baselineIds.isEmpty {
                        Text(String(localized: "目前没有进行中的习惯可排序。"))
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(draftIds.enumerated()), id: \.element) { index, id in
                            if let row = rowsById[id] {
                                sortRow(row, index: index)
                                    .id(id)
                            }
                        }
                    }

                    Button {
                        save()
                    } label: {
                        Text(String(localized: "保存顺序"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Capsule().fill(Color.holoToolAction))
                    }
                    .buttonStyle(HoloPressStyle())
                    .disabled(baselineIds.isEmpty)
                    .padding(.top, 12)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, 30)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(String(localized: "今天列表排序"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                reorder.scrollProxy = proxy
                if baselineIds.isEmpty {
                    baselineIds = model.todayRows.map(\.id)
                }
            }
        }
    }

    private func sortRow(_ row: HabitRowSnapshot, index: Int) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary.opacity(0.6))

            row.iconImage(size: 15)
                .foregroundColor(Color(hex: row.colorHex))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hex: row.colorHex).opacity(0.12)))
            Text(row.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoToolText)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 0) {
                Button {
                    guard !reorder.isInteracting else { return }
                    reorder.moveByOne(id: row.id, offset: -1, section: .sortSheet)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel(Text(String(localized: "上移\(row.name)")))

                Button {
                    guard !reorder.isInteracting else { return }
                    reorder.moveByOne(id: row.id, offset: 1, section: .sortSheet)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(index == draftIds.count - 1)
                .accessibilityLabel(Text(String(localized: "下移\(row.name)")))
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder.opacity(0.6)).frame(height: 0.5)
        }
        .habitReorderable(id: row.id, section: .sortSheet, spacing: 12, model: reorder)
    }

    /// 保存走仓库统一穿插合并（只重排进行中集合，不覆盖暂停/归档相对顺序，§8）
    private func save() {
        let ids = reorder.currentIds(.sortSheet) ?? baselineIds
        do {
            try HabitRepository.shared.persistTodayOrder(ids)
            errorMessage = nil
            model.refresh()
            dismiss()
        } catch {
            errorMessage = String(localized: "保存没有成功，顺序保持原样。请重试。")
        }
    }
}

// MARK: - 展示设置（回顾 / 今日看板）

private struct VisibilityPage: View {

    @ObservedObject var model: HabitModuleViewModel

    enum Kind {
        case review
        case dashboard
    }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss

    /// 草稿：选中集合 + 顺序（review 才有顺序）
    @State private var draftSelected: Set<UUID> = []
    @State private var draftOrder: [UUID] = []
    @State private var errorMessage: String?

    private var settings: HabitStatsDisplaySettings { .shared }

    /// 全部习惯（含暂停/归档，带状态标签；HTML visibility 同款）
    private var allRows: [HabitRowSnapshot] {
        model.todayRows + model.pausedRows + model.archivedRows
    }

    private var rowsById: [UUID: HabitRowSnapshot] {
        Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind == .review
                     ? String(localized: "所选习惯同时参与回顾摘要和列表。暂停与归档也保留历史。")
                     : String(localized: "只影响首页今日看板，不会从习惯模块今天列表删除。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)

                HStack(spacing: HoloSpacing.md) {
                    Button(String(localized: "全部选择")) {
                        draftSelected = Set(draftOrder)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    Spacer()
                    Button(String(localized: "全部关闭")) {
                        draftSelected = []
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoPrimary)
                }
                .frame(minHeight: 40)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.holoError)
                }

                ForEach(Array(draftOrder.enumerated()), id: \.element) { index, id in
                    if let row = rowsById[id] {
                        visibilityRow(row, index: index)
                    }
                }

                Button {
                    save()
                } label: {
                    Text(String(localized: "保存展示设置"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
                .padding(.top, 12)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, 30)
        }
        .background(Color.holoToolBackground)
        .navigationTitle(kind == .review
                         ? String(localized: "回顾展示与顺序")
                         : String(localized: "今日看板展示"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { initializeDraft() }
    }

    private func initializeDraft() {
        guard draftOrder.isEmpty else { return }
        switch kind {
        case .review:
            let order = settings.orderedHabitIds
            let known = allRows.map(\.id)
            let orderedKnown = order.filter { known.contains($0) }
            let rest = known.filter { !orderedKnown.contains($0) }
            draftOrder = orderedKnown + rest
            let saved = settings.visibleHabitIds
            if saved.isEmpty, !UserDefaults.standard.bool(forKey: "habit.stats.visibility.configured.v1") {
                draftSelected = Set(known) // 未配置过：默认全选
            } else {
                draftSelected = Set(saved)
            }
        case .dashboard:
            let known = allRows.map(\.id)
            draftOrder = known
            let saved = settings.dashboardVisibleHabitIds
            if saved.isEmpty, !UserDefaults.standard.bool(forKey: "habit.dashboard.visibility.configured.v1") {
                draftSelected = Set(known)
            } else {
                draftSelected = Set(saved)
            }
        }
    }

    private func visibilityRow(_ row: HabitRowSnapshot, index: Int) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Toggle("", isOn: Binding(
                get: { draftSelected.contains(row.id) },
                set: { on in
                    if on { draftSelected.insert(row.id) } else { draftSelected.remove(row.id) }
                }
            ))
            .labelsHidden()
            .tint(Color(hex: row.colorHex))
            .frame(width: 40)

            row.iconImage(size: 15)
                .foregroundColor(Color(hex: row.colorHex))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hex: row.colorHex).opacity(0.12)))
            HStack(spacing: 5) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                if row.lifecycle != .active {
                    Text(row.lifecycle == .paused ? String(localized: "暂停") : String(localized: "归档"))
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.holoToolBorder.opacity(0.7)))
                }
            }

            Spacer()

            // 回顾顺序：上下移（看板无顺序）
            if kind == .review {
                HStack(spacing: 0) {
                    Button {
                        move(id: row.id, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(width: 30, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .accessibilityLabel(Text(String(localized: "上移\(row.name)")))

                    Button {
                        move(id: row.id, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(width: 30, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == draftOrder.count - 1)
                    .accessibilityLabel(Text(String(localized: "下移\(row.name)")))
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder.opacity(0.6)).frame(height: 0.5)
        }
    }

    private func move(id: UUID, offset: Int) {
        guard let index = draftOrder.firstIndex(of: id) else { return }
        let target = index + offset
        guard target >= 0, target < draftOrder.count else { return }
        draftOrder.swapAt(index, target)
    }

    private func save() {
        switch kind {
        case .review:
            // 顺序持久化已见集合；选中集合按顺序过滤
            settings.setOrderedHabitIds(draftOrder)
            settings.setVisibleHabitIds(draftOrder.filter { draftSelected.contains($0) })
        case .dashboard:
            settings.setDashboardVisibleHabitIds(Array(draftSelected))
        }
        errorMessage = nil
        model.refresh() // 摘要/列表立即按新可见范围重算（R13）
        dismiss()
    }
}

// MARK: - 数据管理

private struct DataManagementPage: View {

    @State private var showClearSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "清空数据与单习惯删除的恢复方式不同。"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "最近删除"))
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    Text(String(localized: "清空后的习惯数据保留 30 天，可在 设置 → 数据管理 → 最近删除 恢复。"))
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.holoToolInset))

                Button {
                    showClearSheet = true
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.holoError)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "清空习惯数据"))
                                .font(.holoBody)
                                .foregroundColor(.holoError)
                            Text(String(localized: "进入最近删除，30 天内可恢复"))
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        Spacer()
                    }
                    .padding(HoloSpacing.md)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                        .fill(Color.holoToolSurface))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, 30)
        }
        .background(Color.holoToolBackground)
        .navigationTitle(String(localized: "数据管理"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showClearSheet) {
            ModuleClearSheet(module: .habit)
        }
    }
}
