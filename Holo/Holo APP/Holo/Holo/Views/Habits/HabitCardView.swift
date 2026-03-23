//
//  HabitCardView.swift
//  Holo
//
//  习惯卡片组件
//  支持打卡型（勾选完成）和数值型（+1 或数值显示）两种交互
//

import SwiftUI
import CoreData

/// 习惯卡片视图
/// 设计参考 Body.svg：
/// - 白色背景，圆角 28pt
/// - 左侧：56x56 圆形图标背景
/// - 中间：习惯名称 + 频率/目标信息
/// - 右侧：交互按钮（打卡/数值）
struct HabitCardView: View {
    
    // MARK: - Properties
    
    let habit: Habit
    
    @State private var isCompleted: Bool = false
    @State private var todayValue: Double? = nil
    /// 历史最新值（用于测量类习惯，即使今日没有记录也显示）
    @State private var latestHistoricalValue: Double? = nil
    @State private var streak: Int = 0
    @State private var showValueInput: Bool = false
    @State private var inputValue: String = ""
    /// 缓存的 habit ID，避免 onReceive 访问已删除对象
    @State private var cachedHabitId: UUID? = nil
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: 16) {
            // 左侧图标
            iconView
            
            // 中间信息
            infoView
            
            Spacer()
            
            // 右侧交互按钮
            actionView
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.holoCardBackground)
                .shadow(color: HoloShadow.card, radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .onAppear {
            cachedHabitId = habit.id  // 缓存 ID，供 onReceive 使用
            loadStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { notification in
            // 用缓存的 ID 过滤，完全不访问 habit 对象
            if let changedHabitId = notification.object as? UUID, changedHabitId != cachedHabitId {
                return
            }
            loadStatus()
        }
        .sheet(isPresented: $showValueInput) {
            valueInputSheet
        }
    }
    
    // MARK: - 加载状态
    
    private func loadStatus() {
        // 离开 body 时检查一次
        guard habit.managedObjectContext != nil else { return }

        Task { @MainActor in
            // 再检查一次，防止 Task 执行时对象已被删除
            guard habit.managedObjectContext != nil else { return }

            let repo = HabitRepository.shared
            if habit.isCheckInType {
                isCompleted = repo.isTodayCompleted(for: habit)
                streak = repo.calculateStreak(for: habit)
            } else {
                todayValue = repo.getTodayValue(for: habit)
                // 对于测量类习惯，加载历史最新值（即使今日没有记录）
                if !habit.isCountType {
                    latestHistoricalValue = repo.getLatestValue(for: habit)
                }
            }
        }
    }
    
    // MARK: - 左侧图标
    
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(habit.habitColor.opacity(0.1))
                .frame(width: 56, height: 56)
            
            // 判断是否为自定义图标
            if habit.isCustomIcon {
                Image(habit.icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(habit.habitColor)
            } else {
                Image(systemName: habit.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(habit.habitColor)
            }
        }
    }
    
    // MARK: - 中间信息
    
    private var infoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 习惯名称
            Text(habit.name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
            
            // 频率/目标信息
            HStack(spacing: 8) {
                Text(habit.frequencyTargetText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                
                // 打卡型显示连续天数（使用预加载的 @State 值）
                if habit.isCheckInType && streak > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                        Text("\(streak)天")
                            .font(.holoLabel)
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
        }
    }
    
    // MARK: - 右侧交互
    
    @ViewBuilder
    private var actionView: some View {
        if habit.isCheckInType {
            // 打卡型：勾选按钮
            checkInButton
        } else if habit.isCountType {
            // 计数类数值型：+1 按钮 + 今日总数
            countActionView
        } else {
            // 测量类数值型：今日值 + 输入按钮
            measureActionView
        }
    }
    
    // MARK: - 打卡按钮
    
    private var checkInButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                do {
                    let newStatus = try HabitRepository.shared.toggleCheckIn(for: habit)
                    isCompleted = newStatus

                    HapticManager.medium()
                } catch {
                    print("[HabitCard] 打卡失败: \(error)")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isCompleted ? habit.habitColor.opacity(0.1) : Color.clear)
                    .frame(width: 40, height: 40)
                
                Circle()
                    .stroke(isCompleted ? habit.habitColor : Color.holoTextSecondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 40, height: 40)
                
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(habit.habitColor)
                }
            }
        }
    }
    
    // MARK: - 计数类交互（+1 按钮）
    
    private var countActionView: some View {
        HStack(spacing: 12) {
            // 今日总数
            if let value = todayValue {
                Text(habit.formatValue(value))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }
            
            // +1 按钮
            Button {
                do {
                    _ = try HabitRepository.shared.incrementCount(for: habit)
                    todayValue = HabitRepository.shared.getTodayValue(for: habit)

                    HapticManager.light()
                } catch {
                    print("[HabitCard] +1 失败: \(error)")
                }
            } label: {
                Text("+1")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(habit.habitColor)
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - 测量类交互（数值显示 + 输入）

    private var measureActionView: some View {
        Button {
            inputValue = ""
            showValueInput = true
        } label: {
            HStack(spacing: 4) {
                // 优先显示今日值，如果没有则显示历史最新值
                if let value = todayValue ?? latestHistoricalValue {
                    Text(habit.formatValue(value))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)

                    Text(habit.unitText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text("记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(habit.habitColor)
            }
        }
    }
    
    // MARK: - 数值输入弹窗
    
    private var valueInputSheet: some View {
        NavigationView {
            VStack(spacing: 24) {
                // 图标
                ZStack {
                    Circle()
                        .fill(habit.habitColor.opacity(0.1))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: habit.icon)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundColor(habit.habitColor)
                }
                .padding(.top, 20)
                
                // 习惯名称
                Text(habit.name)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                
                // 输入框
                VStack(spacing: 8) {
                    HStack {
                        TextField("输入数值", text: $inputValue)
                            .font(.system(size: 32, weight: .bold))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.holoTextPrimary)
                        
                        Text(habit.unitText)
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .padding(.horizontal, 40)
                    
                    Rectangle()
                        .fill(habit.habitColor)
                        .frame(height: 2)
                        .padding(.horizontal, 60)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.holoBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        showValueInput = false
                    }
                    .foregroundColor(.holoTextSecondary)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveValue()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // MARK: - 保存数值
    
    private func saveValue() {
        guard let value = Double(inputValue), value > 0 else {
            showValueInput = false
            return
        }
        
        do {
            _ = try HabitRepository.shared.addNumericRecord(for: habit, value: value)
            todayValue = HabitRepository.shared.getTodayValue(for: habit)
            showValueInput = false

            HapticManager.success()
        } catch {
            print("[HabitCard] 保存数值失败: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        // 需要在 Preview 中模拟 Habit 数据
        Text("习惯卡片预览")
            .font(.holoHeading)
    }
    .padding()
    .background(Color.holoBackground)
}
