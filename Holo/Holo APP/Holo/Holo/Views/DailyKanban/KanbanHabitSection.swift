//
//  KanbanHabitSection.swift
//  Holo
//
//  今日看板 — 每日习惯打卡列表
//  支持打卡型、计数类、测量类三种习惯
//

import SwiftUI
import os.log

struct KanbanHabitSection: View {

    @ObservedObject var habitRepo: HabitRepository
    @State private var completedHabits: Set<UUID> = []
    @State private var todayValues: [UUID: Double] = [:]

    @State private var showValueInput: Bool = false
    @State private var inputValue: String = ""
    @State private var editingHabit: Habit? = nil

    private var activeHabits: [Habit] {
        habitRepo.activeHabits.filter { $0.habitFrequency == .daily }
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            if activeHabits.isEmpty {
                emptyView
            } else {
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
        }
        .onAppear { loadStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            loadStatus()
        }
        .sheet(isPresented: $showValueInput) {
            if let habit = editingHabit {
                valueInputSheet(habit)
            }
        }
    }

    private var emptyView: some View {
        Text("暂无每日习惯")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
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

    // MARK: - Habit Row

    private func habitRow(habit: Habit) -> some View {
        HStack(spacing: 12) {
            habitIcon(habit: habit)

            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(rowTextColor(habit))
                    .strikethrough(habit.isCheckInType && completedHabits.contains(habit.id))

                streakText(habit: habit)
            }

            Spacer()

            actionButton(habit: habit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func rowTextColor(_ habit: Habit) -> Color {
        if habit.isCheckInType {
            return completedHabits.contains(habit.id) ? .holoTextSecondary : .holoTextPrimary
        }
        return .holoTextPrimary
    }

    @ViewBuilder
    private func streakText(habit: Habit) -> some View {
        if habit.isCheckInType {
            Text("🔥 连续 \(habitRepo.calculateStreak(for: habit)) 天")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        } else if habit.isCountType {
            if let target = habit.targetCountValue {
                Text("目标 \(target)\(habit.unitText)")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            } else {
                Text(habit.unitText)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        } else {
            if let target = habit.targetValueDouble {
                Text("目标 \(habit.formatValue(target))\(habit.unitText)")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            } else {
                Text(habit.unitText.isEmpty ? "记录数值" : habit.unitText)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
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

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButton(habit: Habit) -> some View {
        if habit.isCheckInType {
            checkInButton(habit: habit)
        } else if habit.isCountType {
            countButton(habit: habit)
        } else {
            measureButton(habit: habit)
        }
    }

    private func checkInButton(habit: Habit) -> some View {
        let isCompleted = completedHabits.contains(habit.id)

        return Button {
            toggleCheckIn(habit)
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

    private func countButton(habit: Habit) -> some View {
        HStack(spacing: 8) {
            if let value = todayValues[habit.id], value > 0 {
                Text(habit.formatValue(value))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                incrementCount(habit)
            } label: {
                Text("+1")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(habit.habitColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func measureButton(habit: Habit) -> some View {
        Button {
            editingHabit = habit
            inputValue = ""
            showValueInput = true
        } label: {
            HStack(spacing: 4) {
                if let value = todayValues[habit.id] {
                    Text(habit.formatValue(value))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)

                    Text(habit.unitText)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text("记录")
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                }

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(habit.habitColor)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Value Input Sheet

    private func valueInputSheet(_ habit: Habit) -> some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.lg) {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(habit.habitColor.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: habit.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(habit.habitColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(habit.name)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text(habit.unitText.isEmpty ? "输入数值" : "单位：\(habit.unitText)")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
                }

                TextField("输入数值", text: $inputValue)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .padding()
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle("记录数值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        showValueInput = false
                        editingHabit = nil
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveNumericValue(habit)
                    }
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .disabled(inputValue.isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadStatus() {
        var completed: Set<UUID> = []
        var values: [UUID: Double] = [:]

        for habit in activeHabits {
            if habit.isCheckInType {
                if habitRepo.isTodayCompleted(for: habit) {
                    completed.insert(habit.id)
                }
            } else if habit.isNumericType {
                if let value = habitRepo.getTodayValue(for: habit) {
                    values[habit.id] = value
                }
            }
        }
        completedHabits = completed
        todayValues = values
    }

    private func toggleCheckIn(_ habit: Habit) {
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

    private func incrementCount(_ habit: Habit) {
        do {
            _ = try habitRepo.incrementCount(for: habit)
            todayValues[habit.id] = habitRepo.getTodayValue(for: habit)
            HapticManager.light()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("计数失败: \(error.localizedDescription)")
        }
    }

    private func saveNumericValue(_ habit: Habit) {
        guard let value = Double(inputValue) else { return }
        do {
            _ = try habitRepo.addNumericRecord(for: habit, value: value)
            todayValues[habit.id] = habitRepo.getTodayValue(for: habit)
            showValueInput = false
            editingHabit = nil
            HapticManager.light()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("记录数值失败: \(error.localizedDescription)")
        }
    }
}
