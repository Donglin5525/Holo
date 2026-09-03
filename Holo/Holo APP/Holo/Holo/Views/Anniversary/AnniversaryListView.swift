//
//  AnniversaryListView.swift
//  Holo
//
//  纪念日列表页 —— 系统 List + swipeActions + 空状态
//

import SwiftUI

/// 列表页 sheet 目标（新增 / 编辑某个纪念日）
enum AnniversarySheetTarget: Identifiable {
    case add
    case edit(Anniversary)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let item): return "edit-\(item.id)"
        }
    }
}

struct AnniversaryListView: View {

    let onBack: () -> Void

    @State private var anniversaries: [Anniversary] = []
    @State private var isInitialContentReady = false
    @State private var detailAnniversary: Anniversary?
    @State private var anniversaryToDelete: Anniversary?

    /// 统一的 sheet 状态：新增 / 编辑
    @State private var sheetTarget: AnniversarySheetTarget?

    private var repository: AnniversaryRepository { AnniversaryRepository.shared }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                headerView

                if anniversaries.isEmpty {
                    if isInitialContentReady {
                        emptyState
                    } else {
                        Spacer()
                    }
                } else {
                    anniversaryList
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            await CoreDataStack.shared.waitUntilReady()
            repository.setup()
            _ = await AnniversaryTaskGenerator.shared.generateDueTasks()
            refreshList()
            withAnimation(.easeIn(duration: 0.25)) {
                isInitialContentReady = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .anniversaryDataDidChange)) { _ in
            refreshList()
        }
        // TasksView 底部 Tab「+」转发的新增请求
        .onReceive(NotificationCenter.default.publisher(for: .anniversaryRequestAdd)) { _ in
            sheetTarget = .add
        }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .add:
                AddAnniversarySheet()
            case .edit(let item):
                AddAnniversarySheet(editingAnniversary: item)
            }
        }
        .fullScreenCover(item: $detailAnniversary) { item in
            AnniversaryDetailView(anniversary: item) {
                detailAnniversary = nil
            }
            .holoContentColumn()
        }
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(
                get: { anniversaryToDelete != nil },
                set: { if !$0 { anniversaryToDelete = nil } }
            ),
            presenting: anniversaryToDelete
        ) { item in
            Button("删除纪念日及关联任务", role: .destructive) {
                deleteAnniversary(item, deleteTasks: true)
            }
            Button("仅删除纪念日", role: .destructive) {
                deleteAnniversary(item, deleteTasks: false)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这个纪念日可能已生成关联任务，你想如何处理？")
        }
    }

    // MARK: - 顶部导航

    private var headerView: some View {
        HStack {
            // 44×44 触控区域，与 TaskListView/TaskStatsView 一致
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Text("纪念日")
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Button(action: { sheetTarget = .add }) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, 8)
        .padding(.bottom, HoloSpacing.sm)
    }

    // MARK: - 列表（Hero 主卡 + 三组分组，保留系统 List 的滑动操作）

    /// Hero：到期当天的条目优先，否则最近的未来倒数
    private var heroItem: Anniversary? {
        let upcoming = anniversaries.filter { $0.daysFromToday() >= 0 }
        return upcoming.first(where: { $0.isToday }) ?? upcoming.first
    }

    private var restItems: [Anniversary] {
        anniversaries.filter { $0.id != heroItem?.id }
    }

    /// 即将到来（不重复的未来日）
    private var upcomingOnceItems: [Anniversary] {
        restItems.filter { $0.daysFromToday() >= 0 && !$0.repeatYearly }
    }

    /// 每年循环（重复的未来日，含「就是今天」但未被 Hero 选中的）
    private var yearlyItems: [Anniversary] {
        restItems.filter { $0.daysFromToday() >= 0 && $0.repeatYearly }
    }

    /// 时光已过（累计）
    private var elapsedItems: [Anniversary] {
        restItems.filter { $0.daysFromToday() < 0 }
    }

    private var anniversaryList: some View {
        List {
            // 情感焦点：Hero 主卡
            if let hero = heroItem {
                Section {
                    AnniversaryHeroCard(anniversary: hero) {
                        detailAnniversary = hero
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: HoloSpacing.md, bottom: 10, trailing: HoloSpacing.md))
                    .contextMenu { rowContextMenu(hero) }
                }
            }

            if !upcomingOnceItems.isEmpty {
                section(title: String(localized: "即将到来")) {
                    ForEach(upcomingOnceItems, id: \.id) { row($0) }
                }
            }

            if !yearlyItems.isEmpty {
                section(title: String(localized: "每年循环")) {
                    ForEach(yearlyItems, id: \.id) { row($0) }
                }
            }

            if !elapsedItems.isEmpty {
                section(title: String(localized: "时光已过")) {
                    ForEach(elapsedItems, id: \.id) { row($0) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding(.bottom, 100) // 给底部 Tab 栏留空间
    }

    /// 分组 Section（小写间距标签 + 分隔线）
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11.5, weight: .heavy))
                    .kerning(1)
                    .foregroundColor(Color.holoTextSecondary)
                Rectangle()
                    .fill(Color.holoBorder)
                    .frame(height: 0.7)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .textCase(nil)
            .listRowInsets(EdgeInsets())
        }
    }

    /// 普通行卡片（右滑编辑/删除 · 左滑置顶 · 长按菜单）
    private func row(_ item: Anniversary) -> some View {
        AnniversaryCardView(anniversary: item) {
            detailAnniversary = item
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: HoloSpacing.md, bottom: 6, trailing: HoloSpacing.md))
        // 右滑：编辑 + 删除
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                sheetTarget = .edit(item)
            } label: {
                Label(String(localized: "编辑"), systemImage: "pencil")
            }
            .tint(.holoPrimary)

            Button(role: .destructive) {
                anniversaryToDelete = item
            } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        }
        // 左滑：置顶
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                togglePin(item)
            } label: {
                Label(item.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"),
                      systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .tint(.holoInfo)
        }
        .contextMenu { rowContextMenu(item) }
    }

    @ViewBuilder
    private func rowContextMenu(_ item: Anniversary) -> some View {
        Button {
            sheetTarget = .edit(item)
        } label: {
            Label(String(localized: "编辑"), systemImage: "pencil")
        }
        Button {
            togglePin(item)
        } label: {
            Label(item.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"),
                  systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Button(role: .destructive) {
            anniversaryToDelete = item
        } label: {
            Label(String(localized: "删除"), systemImage: "trash")
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "calendar.badge.heart")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            VStack(spacing: HoloSpacing.sm) {
                Text("点亮第一个重要的日子")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text("生日、纪念日、倒数日……\n每点亮一个日子，等待本身就开始发光")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button(action: { sheetTarget = .add }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("点亮一个日子")
                }
                .font(.holoLabel)
                .foregroundColor(.white)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.sm + 4)
                .background(Color.holoPrimary)
                .clipShape(Capsule())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作

    private func refreshList() {
        anniversaries = repository.sortedForDisplay
    }

    private func togglePin(_ item: Anniversary) {
        Task { try? await repository.togglePin(item) }
    }

    private func deleteAnniversary(_ item: Anniversary, deleteTasks: Bool) {
        HapticManager.warning()
        Task {
            if deleteTasks {
                await AnniversaryTaskGenerator.shared.deleteTasks(for: item.id)
            }
            try? await repository.softDeleteAnniversary(item)
        }
    }
}
