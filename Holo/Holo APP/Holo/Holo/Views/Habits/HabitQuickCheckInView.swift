//
//  HabitQuickCheckInView.swift
//  Holo
//
//  快捷习惯打卡视图
//  从 Holo One 快捷入口打开，展示所有活跃习惯供用户快速打卡
//  支持三种习惯类型：打卡型、计数类数值型、测量类数值型
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
    @State private var completedHabits: Set<UUID> = []
    @State private var todayValues: [UUID: Double] = [:]

    // 测量类数值输入
    @State private var showValueInput: Bool = false
    @State private var inputValue: String = ""
    @State private var editingHabit: Habit? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    // 进度概览
                    progressCard

                    // 习惯列表
                    if habits.isEmpty {
                        emptyStateView
                    } else {
                        habitListSection
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
            .sheet(isPresented: $showValueInput) {
                if let habit = editingHabit {
                    valueInputSheet(habit)
                }
            }
        }
    }

    // MARK: - 进度概览

    private var progressCard: some View {
        HStack(spacing: HoloSpacing.md) {
            // 进度环
            ZStack {
                Circle()
                    .stroke(Color.holoBorder, lineWidth: 4)
                    .frame(width: 44, height: 44)

                Circle()
                    .trim(from: 0, to: todayProgress.total > 0
                          ? CGFloat(todayProgress.completed) / CGFloat(todayProgress.total)
                          : 0)
                    .stroke(Color.holoPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))

                Text("\(todayProgress.completed)/\(todayProgress.total)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("今日进度")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(todayProgress.completed >= todayProgress.total && todayProgress.total > 0
                     ? "全部完成!"
                     : "还有 \(todayProgress.total - todayProgress.completed) 项待完成")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "checkmark.circle")
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

    // MARK: - 习惯列表

    private var habitListSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)

                Text("习惯列表")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            LazyVStack(spacing: HoloSpacing.sm) {
                ForEach(habits, id: \.id) { habit in
                    habitRow(habit)
                }
            }
        }
    }

    /// 单个习惯行
    private func habitRow(_ habit: Habit) -> some View {
        HStack(spacing: HoloSpacing.md) {
            // 图标
            ZStack {
                Circle()
                    .fill(habit.habitColor.opacity(0.1))
                    .frame(width: 40, height: 40)

                if habit.isCustomIcon {
                    Image(habit.icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundColor(habit.habitColor)
                } else {
                    Image(systemName: habit.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(habit.habitColor)
                }
            }

            // 名称 + 副标题
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(habitSubtitle(habit))
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            // 操作按钮（根据类型）
            actionButton(habit)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 操作按钮

    /// 根据习惯类型渲染不同操作按钮
    @ViewBuilder
    private func actionButton(_ habit: Habit) -> some View {
        if habit.isCheckInType {
            checkInButton(habit)
        } else if habit.isCountType {
            countButton(habit)
        } else {
            measureButton(habit)
        }
    }

    /// 打卡型 - 勾选按钮
    private func checkInButton(_ habit: Habit) -> some View {
        Button {
            performCheckIn(habit)
        } label: {
            let isCompleted = completedHabits.contains(habit.id)
            ZStack {
                Circle()
                    .fill(isCompleted ? habit.habitColor : Color.clear)
                    .frame(width: 36, height: 36)

                Circle()
                    .stroke(isCompleted ? habit.habitColor : Color.holoBorder, lineWidth: 2)
                    .frame(width: 36, height: 36)

                Image(systemName: isCompleted ? "checkmark" : "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isCompleted ? .white : .holoTextSecondary)
            }
        }
    }

    /// 计数类 - +1 按钮 + 今日总数
    private func countButton(_ habit: Habit) -> some View {
        HStack(spacing: 8) {
            // 今日总数
            if let value = todayValues[habit.id] {
                Text(habit.formatValue(value))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            // +1 按钮
            Button {
                performIncrement(habit)
            } label: {
                Text("+1")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(habit.habitColor)
                    .clipShape(Capsule())
            }
        }
    }

    /// 测量类 - 数值显示 + 记录按钮
    private func measureButton(_ habit: Habit) -> some View {
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
    }

    // MARK: - 测量类数值输入弹窗

    private func valueInputSheet(_ habit: Habit) -> some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.lg) {
                // 习惯信息
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

                // 数值输入
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

    // MARK: - 辅助

    /// 习惯行副标题
    private func habitSubtitle(_ habit: Habit) -> String {
        if habit.isCheckInType {
            return habit.frequencyTargetText
        } else if habit.isCountType {
            if let target = habit.targetCountValue {
                return "\(habit.unitText) · 目标 \(target)\(habit.unitText)"
            }
            return habit.unitText
        } else {
            if let target = habit.targetValueDouble {
                return "\(habit.unitText) · 目标 \(habit.formatValue(target))\(habit.unitText)"
            }
            return habit.unitText
        }
    }

    // MARK: - 数据加载

    private func loadHabits() {
        guard repository.isReady else {
            habits = []
            todayProgress = (0, 0)
            return
        }
        habits = repository.activeHabits
        todayProgress = repository.getTodayCheckInProgress()

        // 加载各类型习惯状态
        var completed: Set<UUID> = []
        var values: [UUID: Double] = [:]

        for habit in habits {
            if habit.isCheckInType {
                if repository.isTodayCompleted(for: habit) {
                    completed.insert(habit.id)
                }
            } else if habit.isNumericType {
                if let value = repository.getTodayValue(for: habit) {
                    values[habit.id] = value
                }
            }
        }
        completedHabits = completed
        todayValues = values
    }

    // MARK: - 操作

    /// 打卡型 - 切换完成状态
    private func performCheckIn(_ habit: Habit) {
        do {
            let isNowCompleted = try repository.toggleCheckIn(for: habit)
            if isNowCompleted {
                completedHabits.insert(habit.id)
            } else {
                completedHabits.remove(habit.id)
            }
            todayProgress = repository.getTodayCheckInProgress()
            HapticManager.light()
        } catch {
            // 静默失败
        }
    }

    /// 计数类 - +1
    private func performIncrement(_ habit: Habit) {
        do {
            _ = try repository.incrementCount(for: habit)
            todayValues[habit.id] = repository.getTodayValue(for: habit)
            HapticManager.light()
        } catch {
            // 静默失败
        }
    }

    /// 测量类 - 保存数值
    private func saveNumericValue(_ habit: Habit) {
        guard let value = Double(inputValue) else { return }
        do {
            _ = try repository.addNumericRecord(for: habit, value: value)
            todayValues[habit.id] = repository.getTodayValue(for: habit)
            showValueInput = false
            editingHabit = nil
            HapticManager.light()
        } catch {
            // 静默失败
        }
    }
}

// MARK: - Preview

#Preview {
    HabitQuickCheckInView()
}
