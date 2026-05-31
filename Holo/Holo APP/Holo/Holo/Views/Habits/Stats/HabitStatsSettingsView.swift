//
//  HabitStatsSettingsView.swift
//  Holo
//
//  统计页设置视图
//  管理统计页展示习惯的可见性和排序
//

import SwiftUI

struct HabitStatsSettingsView: View {
    let onBack: () -> Void

    @StateObject private var repository = HabitRepository.shared
    @StateObject private var settings = HabitStatsDisplaySettings.shared

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            if repository.activeHabits.isEmpty {
                emptyState
            } else {
                habitList
            }
        }
        .background(Color.holoBackground)
        .navigationBarHidden(true)
        .task {
            guard !repository.isReady else { return }
            Task.detached(priority: .utility) {
                _ = CoreDataStack.shared.persistentContainer
                await MainActor.run {
                    repository.setup()
                }
            }
        }
        .onAppear {
            // 首次进入时初始化排序列表
            if settings.orderedHabitIds.isEmpty {
                settings.setOrderedHabitIds(repository.activeHabits.map(\.id))
            }
        }
    }

    // MARK: - 导航栏

    private var navigationBar: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Text("设置")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 习惯列表

    private var habitList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择要展示的习惯，点击切换展示位置，拖动调整顺序")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text("统计 = 习惯模块统计页 · 看板 = 首页今日看板")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.md)

                LazyVStack(spacing: 0) {
                    ForEach(orderedHabits) { habit in
                        habitRow(habit)
                    }
                    .onMove(perform: moveHabit)
                }
                .padding(.horizontal, HoloSpacing.md)
            }
            .padding(.bottom, HoloSpacing.xl)
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - 习惯行

    private func habitRow(_ habit: Habit) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Group {
                habit.iconImage(size: 16)
                    .foregroundColor(Color(hex: habit.color))
            }
            .frame(width: 28, height: 28)
            .background((Color(hex: habit.color)).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(habit.name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            visibilityPillButton(
                title: "统计",
                isOn: statsBinding(for: habit.id)
            )
            visibilityPillButton(
                title: "看板",
                isOn: dashboardBinding(for: habit.id)
            )
        }
        .padding(.vertical, HoloSpacing.sm)
        .padding(.horizontal, HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func visibilityPillButton(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isOn.wrappedValue ? .white : .holoTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isOn.wrappedValue ? Color.holoPrimary : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        isOn.wrappedValue ? Color.clear : Color.holoBorder,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isOn.wrappedValue)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 80)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("还没有习惯")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("先去习惯页创建你的第一个习惯")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var orderedHabits: [Habit] {
        let unordered = repository.activeHabits.filter { !settings.orderedHabitIds.contains($0.id) }
        let ordered = settings.orderedHabitIds.compactMap { id in
            repository.activeHabits.first { $0.id == id }
        }
        return ordered + unordered
    }

    private func statsBinding(for habitId: UUID) -> Binding<Bool> {
        Binding(
            get: {
                settings.visibleHabitIds.isEmpty || settings.visibleHabitIds.contains(habitId)
            },
            set: { isVisible in
                var ids = settings.visibleHabitIds.isEmpty
                    ? repository.activeHabits.map(\.id)
                    : settings.visibleHabitIds
                if isVisible {
                    if !ids.contains(habitId) { ids.append(habitId) }
                } else {
                    ids.removeAll { $0 == habitId }
                }
                settings.setVisibleHabitIds(ids)
            }
        )
    }

    private func dashboardBinding(for habitId: UUID) -> Binding<Bool> {
        Binding(
            get: {
                settings.dashboardVisibleHabitIds.isEmpty || settings.dashboardVisibleHabitIds.contains(habitId)
            },
            set: { isVisible in
                var ids = settings.dashboardVisibleHabitIds.isEmpty
                    ? repository.activeHabits.map(\.id)
                    : settings.dashboardVisibleHabitIds
                if isVisible {
                    if !ids.contains(habitId) { ids.append(habitId) }
                } else {
                    ids.removeAll { $0 == habitId }
                }
                settings.setDashboardVisibleHabitIds(ids)
            }
        )
    }

    private func moveHabit(from source: IndexSet, to destination: Int) {
        settings.moveHabit(fromOffsets: source, toOffset: destination)
    }
}

#Preview {
    HabitStatsSettingsView(onBack: {})
}
