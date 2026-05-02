//
//  KanbanHabitSection.swift
//  Holo
//
//  今日看板 — 每日习惯打卡列表
//

import SwiftUI
import os.log

struct KanbanHabitSection: View {

    @ObservedObject var habitRepo: HabitRepository
    @State private var completedHabits: Set<UUID> = []

    private var activeHabits: [Habit] {
        habitRepo.activeHabits.filter { $0.habitFrequency == .daily }
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            VStack(spacing: 0) {
                ForEach(activeHabits, id: \.id) { habit in
                    habitRow(habit: habit)
                    if habit.id != activeHabits.last?.id {
                        Divider().background(Color.holoDivider)
                    }
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
            .shadow(color: HoloShadow.card, radius: 4, y: 1)
        }
        .onAppear { loadStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            loadStatus()
        }
    }

    private var sectionHeader: some View {
        HStack {
            Label {
                HStack(spacing: 4) {
                    Text("每日打卡")
                    Text("\(completedHabits.count)/\(activeHabits.count)")
                        .font(.holoTinyLabel)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.holoSuccess)
                        .clipShape(Capsule())
                }
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.holoTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func habitRow(habit: Habit) -> some View {
        HStack(spacing: 12) {
            habitIcon(habit: habit)

            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(completedHabits.contains(habit.id) ? .holoTextSecondary : .holoTextPrimary)
                    .strikethrough(completedHabits.contains(habit.id))

                Text("🔥 连续 \(habitRepo.calculateStreak(for: habit)) 天")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            checkButton(habit: habit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func habitIcon(habit: Habit) -> some View {
        ZStack {
            Circle()
                .fill(habit.habitColor.opacity(0.1))
                .frame(width: 36, height: 36)

            Image(systemName: habit.icon)
                .font(.system(size: 16))
                .foregroundColor(habit.habitColor)
        }
    }

    private func checkButton(habit: Habit) -> some View {
        let isCompleted = completedHabits.contains(habit.id)

        return Button {
            toggleHabit(habit)
        } label: {
            ZStack {
                Circle()
                    .fill(isCompleted ? habit.habitColor : Color.clear)
                    .frame(width: 28, height: 28)

                Circle()
                    .stroke(isCompleted ? habit.habitColor : habit.habitColor.opacity(0.3), lineWidth: 2.5)
                    .frame(width: 28, height: 28)

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(isCompleted ? 1 : 0)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCompleted)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadStatus() {
        var completed: Set<UUID> = []
        for habit in activeHabits {
            if habitRepo.isTodayCompleted(for: habit) {
                completed.insert(habit.id)
            }
        }
        completedHabits = completed
    }

    private func toggleHabit(_ habit: Habit) {
        do {
            let wasCompleted = completedHabits.contains(habit.id)
            _ = try habitRepo.toggleCheckIn(for: habit)

            if wasCompleted {
                completedHabits.remove(habit.id)
            } else {
                completedHabits.insert(habit.id)
                HapticManager.taskCompletion()
            }
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("打卡失败: \(error.localizedDescription)")
        }
    }
}
