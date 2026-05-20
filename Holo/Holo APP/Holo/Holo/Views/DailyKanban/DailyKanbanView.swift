//
//  DailyKanbanView.swift
//  Holo
//
//  今日看板主视图 — 融合财务/健康/打卡/待办/心情五大模块
//

import SwiftUI
import os.log

struct DailyKanbanView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared
    @ObservedObject private var healthRepo = HealthRepository.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey) private var userName: String = UserDisplayNameSettings.fallbackDisplayName

    @State private var editingHabit: Habit? = nil
    @State private var inputValue: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    headerView
                    KanbanProgressHero(
                        todoRepo: todoRepo,
                        habitRepo: habitRepo,
                        healthRepo: healthRepo,
                        userName: userName
                    )
                    KanbanBudgetSection()
                    KanbanHabitSection(
                        habitRepo: habitRepo,
                        inputValue: $inputValue,
                        editingHabit: $editingHabit
                    )
                    KanbanTaskSection(todoRepo: todoRepo)
                    KanbanMoodSection()
                    KanbanHealthSection(healthRepo: healthRepo)
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 16)
            }

            // 数值输入弹窗
            if let habit = editingHabit {
                numericInputPopup(habit)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editingHabit != nil)
        .swipeBackToDismiss { dismiss() }
        .task {
            habitRepo.loadActiveHabits()
            await healthRepo.fetchTodayData()
            todoRepo.seedDailyRitualsForToday()
        }
    }

    private var headerView: some View {
        ZStack {
            Text("今日看板")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.holoBorder, lineWidth: 1))
                }

                Spacer()

                Text(todayString)
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimaryLight)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
    }

    private var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 E"
        return f.string(from: Date())
    }

    // MARK: - 数值输入弹窗

    @ViewBuilder
    private func numericInputPopup(_ habit: Habit) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    isInputFocused = false
                    editingHabit = nil
                }

            VStack(spacing: 20) {
                // 头部
                HStack {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(habit.habitColor.opacity(0.1))
                                .frame(width: 40, height: 40)
                            habit.iconImage(size: 18)
                                .foregroundColor(habit.habitColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.name)
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Text(habit.unitText.isEmpty ? "输入数值" : "单位：\(habit.unitText)")
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    Spacer()
                    Button {
                        isInputFocused = false
                        editingHabit = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                // 输入框
                TextField("0", text: $inputValue)
                    .focused($isInputFocused)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .padding(.vertical, 16)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("完成") { isInputFocused = false }
                        }
                    }

                // 保存按钮
                Button {
                    saveNumericRecord(habit)
                } label: {
                    Text("保存")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(inputValue.isEmpty ? Color.gray.opacity(0.4) : habit.habitColor)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .disabled(inputValue.isEmpty)
            }
            .padding(24)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            .padding(.horizontal, 32)
        }
    }

    private func saveNumericRecord(_ habit: Habit) {
        guard let value = Double(inputValue) else { return }
        do {
            _ = try habitRepo.addNumericRecord(for: habit, value: value)
            isInputFocused = false
            editingHabit = nil
            HapticManager.light()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("记录数值失败: \(error.localizedDescription)")
        }
    }
}

#Preview {
    DailyKanbanView()
}
