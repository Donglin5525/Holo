//
//  HabitQuickCheckInView.swift
//  Holo
//
//  快捷习惯打卡视图
//  从 Holo One 快捷入口打开，磁贴墙 + 今日进度条（与习惯 Tab 磁贴墙同一套组件）
//

import SwiftUI

/// 快捷习惯打卡视图
struct HabitQuickCheckInView: View {

    // MARK: - Environment

    @Environment(\.dismiss) var dismiss

    // MARK: - Properties

    @StateObject private var repository = HabitRepository.shared
    @State private var habits: [Habit] = []
    @State private var todayProgress: (completed: Int, total: Int) = (0, 0)
    /// 本周点阵预缓存（habitId -> 逐日完成情况）
    @State private var weekPatterns: [UUID: [Bool]] = [:]
    /// 庆祝波浪令牌：今日进度首次达到全部完成时 +1
    @State private var waveToken: Int = 0
    /// 长按菜单「查看详情」的目标
    private struct HabitSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedHabit: HabitSelection? = nil

    /// 磁贴墙两列
    private let tileColumns = [
        GridItem(.flexible(), spacing: HoloSpacing.md),
        GridItem(.flexible(), spacing: HoloSpacing.md)
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    // 进度概览（与习惯 Tab 同款橙色进度条）；无习惯时不显示
                    if todayProgress.total > 0 {
                        HabitProgressHeader(
                            completed: todayProgress.completed,
                            total: todayProgress.total
                        )
                    }

                    // 习惯磁贴墙
                    if habits.isEmpty {
                        emptyStateView
                    } else {
                        tileWall
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("快捷打卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                }
            }
            .task {
                Task.detached(priority: .utility) {
                    _ = CoreDataStack.shared.persistentContainer
                    await MainActor.run {
                        repository.setup()
                        loadHabits()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
                loadHabits()
            }
            .sheet(item: $selectedHabit) { selection in
                if let habit = habits.first(where: { $0.id == selection.id }) {
                    HabitDetailView(habit: habit)
                } else {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - 磁贴墙

    private var tileWall: some View {
        LazyVGrid(columns: tileColumns, spacing: HoloSpacing.md) {
            ForEach(Array(habits.enumerated()), id: \.element.id) { index, habit in
                HabitTileView(
                    habit: habit,
                    index: index,
                    weekPattern: weekPatterns[habit.id] ?? [],
                    waveToken: waveToken,
                    onOpenDetail: { selectedHabit = HabitSelection(id: habit.id) }
                )
            }
        }
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.holoTextSecondary)

            Text("暂无习惯")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("请先在习惯模块中创建习惯")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.vertical, 60)
    }

    // MARK: - 数据加载

    private func loadHabits() {
        guard repository.isReady else {
            habits = []
            todayProgress = (0, 0)
            weekPatterns = [:]
            return
        }
        habits = repository.activeHabits
        let newProgress = repository.getTodayCheckInProgress()
        // 「从未全部完成 → 全部完成」的跳变触发庆祝波浪（仅一次）
        if newProgress.total > 0,
           todayProgress.total == newProgress.total,
           todayProgress.completed < newProgress.total,
           newProgress.completed == newProgress.total {
            waveToken += 1
        }
        todayProgress = newProgress
        weekPatterns = repository.getWeekCompletionPatterns()
    }
}

// MARK: - Preview

#Preview {
    HabitQuickCheckInView()
}
