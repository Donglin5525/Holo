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

    // MARK: - 列表（系统 List + swipeActions）

    private var anniversaryList: some View {
        List {
            ForEach(anniversaries, id: \.id) { item in
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
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.holoPrimary)

                    Button(role: .destructive) {
                        anniversaryToDelete = item
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                // 左滑：置顶
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        togglePin(item)
                    } label: {
                        Label(item.isPinned ? "取消置顶" : "置顶",
                              systemImage: item.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(.holoInfo)
                }
                .contextMenu {
                    Button {
                        sheetTarget = .edit(item)
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button {
                        togglePin(item)
                    } label: {
                        Label(item.isPinned ? "取消置顶" : "置顶",
                              systemImage: item.isPinned ? "pin.slash" : "pin")
                    }
                    Button(role: .destructive) {
                        anniversaryToDelete = item
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding(.bottom, 100) // 给底部 Tab 栏留空间
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
                Text("记录第一个重要的日子")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text("生日、纪念日、倒计时……\n让每个值得记住的日子都被看见")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button(action: { sheetTarget = .add }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("添加纪念日")
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
