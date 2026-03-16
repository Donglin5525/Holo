//
//  HabitDetailView.swift
//  Holo
//
//  习惯详情页
//  展示统计摘要、时间范围切换、记录列表
//

import SwiftUI
import CoreData

/// 习惯详情页的数据快照（值类型，避免直接在 body 中查 Core Data）
struct HabitDetailSnapshot {
    var name: String = ""
    var icon: String = "checkmark.circle"
    var color: String = "#13A4EC"
    var isCheckInType: Bool = true
    var isCountType: Bool = false
    var frequencyTargetText: String = ""
    var habitTypeName: String = ""
    var unit: String? = nil
    
    // 统计数据
    var streak: Int = 0
    var completedCount: Int = 0
    var completionRate: Double = 0
    var totalDays: Int = 0
    var periodStats: HabitPeriodStats = HabitPeriodStats(
        total: 0, average: 0, min: 0, max: 0, count: 0,
        latestValue: nil, earliestValue: nil
    )
    
    var habitColor: Color {
        Color(hex: color) ?? .holoInfo
    }
}

/// 习惯详情视图
struct HabitDetailView: View {
    
    // MARK: - Properties
    
    let habit: Habit
    
    /// 删除/归档前的回调，传入待执行操作，父视图在 sheet onDismiss 中执行
    var onWillDelete: ((PendingHabitAction) -> Void)? = nil
    
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedRange: HabitDateRange = .week
    @State private var records: [HabitRecord] = []
    @State private var snapshot = HabitDetailSnapshot()
    @State private var showEditSheet: Bool = false
    @State private var showDeleteAlert: Bool = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    habitHeader
                    rangePicker
                    statsSection
                    recordsSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        
                        Button {
                            archiveHabit()
                        } label: {
                            Label("归档", systemImage: "archivebox")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
            }
            .onAppear {
                refreshAll()
            }
            .onChange(of: selectedRange) { _, _ in
                refreshAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { notification in
                if let changedHabitId = notification.object as? UUID, changedHabitId != habit.id {
                    return
                }
                refreshAll()
            }
            .sheet(isPresented: $showEditSheet) {
                AddHabitSheet(onSave: {
                    refreshAll()
                }, editingHabit: habit)
            }
            .alert("确认删除", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteHabit()
                }
            } message: {
                Text("删除后将无法恢复，包括所有记录数据。")
            }
        }
    }
    
    // MARK: - 数据刷新（所有 Core Data 查询在此完成，不在 body 中执行）
    
    private func refreshAll() {
        // 检查对象是否已被删除
        guard !habit.isDeleted, habit.managedObjectContext != nil else { return }
        
        Task { @MainActor in
            // 再次检查（Task 执行前对象可能已被删除）
            guard !habit.isDeleted, habit.managedObjectContext != nil else { return }
            
            let repo = HabitRepository.shared
            
            // 加载记录
            let loadedRecords = repo.getRecords(for: habit, in: selectedRange.dateRange())
            
            // 构建快照
            var s = HabitDetailSnapshot()
            s.name = habit.name
            s.icon = habit.icon
            s.color = habit.color
            s.isCheckInType = habit.isCheckInType
            s.isCountType = habit.isCountType
            s.frequencyTargetText = habit.frequencyTargetText
            s.habitTypeName = habit.habitType.displayName
            s.unit = habit.unit
            
            if habit.isCheckInType {
                s.streak = repo.calculateStreak(for: habit)
                s.completedCount = repo.calculatePeriodCompletionCount(for: habit, range: selectedRange)
                s.totalDays = selectedRange.days ?? max(loadedRecords.count, 1)
                s.completionRate = s.totalDays > 0
                    ? Double(s.completedCount) / Double(s.totalDays) * 100
                    : 0
            } else {
                s.periodStats = repo.calculatePeriodStats(for: habit, range: selectedRange)
            }
            
            // 更新 @State 变量
            records = loadedRecords
            snapshot = s
        }
    }
    
    // MARK: - 习惯信息头部
    
    private var habitHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(snapshot.habitColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: snapshot.icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(snapshot.habitColor)
            }
            
            Text(snapshot.name)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            
            HStack(spacing: 8) {
                Text(snapshot.habitTypeName)
                    .font(.holoCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(snapshot.habitColor)
                    .cornerRadius(HoloRadius.sm)
                
                Text(snapshot.frequencyTargetText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.vertical, HoloSpacing.md)
    }
    
    // MARK: - 时间范围选择器
    
    private var rangePicker: some View {
        Picker("时间范围", selection: $selectedRange) {
            ForEach(HabitDateRange.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }
    
    // MARK: - 统计摘要
    
    private var statsSection: some View {
        VStack(spacing: 16) {
            if snapshot.isCheckInType {
                checkInStatsView
            } else {
                numericStatsView
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(HoloRadius.lg)
    }
    
    // MARK: - 打卡型统计（使用 snapshot 数据，不做 Core Data 查询）
    
    private var checkInStatsView: some View {
        HStack(spacing: 0) {
            statItem(
                value: "\(snapshot.streak)",
                label: "连续天数",
                icon: "flame.fill",
                color: .holoPrimary
            )
            
            Divider().frame(height: 40)
            
            statItem(
                value: "\(snapshot.completedCount)",
                label: "\(selectedRange.displayName)完成",
                icon: "checkmark.circle.fill",
                color: .holoSuccess
            )
            
            Divider().frame(height: 40)
            
            statItem(
                value: String(format: "%.0f%%", snapshot.completionRate),
                label: "完成率",
                icon: "chart.pie.fill",
                color: .holoInfo
            )
        }
    }
    
    // MARK: - 数值型统计（使用 snapshot 数据，不做 Core Data 查询）
    
    private var numericStatsView: some View {
        let stats = snapshot.periodStats
        
        return Group {
            if snapshot.isCountType {
                HStack(spacing: 0) {
                    statItem(
                        value: formatValue(stats.total),
                        label: "总计",
                        icon: "sum",
                        color: snapshot.habitColor
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: formatValue(stats.average),
                        label: "日均",
                        icon: "divide",
                        color: .holoInfo
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: formatValue(stats.max),
                        label: "峰值",
                        icon: "arrow.up",
                        color: .holoPrimary
                    )
                }
            } else {
                HStack(spacing: 0) {
                    if let change = stats.change {
                        statItem(
                            value: (change >= 0 ? "+" : "") + formatValue(change),
                            label: "变化",
                            icon: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                            color: change >= 0 ? .holoSuccess : .holoError
                        )
                    } else {
                        statItem(
                            value: "-",
                            label: "变化",
                            icon: "minus",
                            color: .holoTextSecondary
                        )
                    }
                    Divider().frame(height: 40)
                    statItem(
                        value: formatValue(stats.min),
                        label: "最低",
                        icon: "arrow.down",
                        color: .holoInfo
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: formatValue(stats.max),
                        label: "最高",
                        icon: "arrow.up",
                        color: .holoPrimary
                    )
                }
            }
        }
    }
    
    /// 格式化数值
    private func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
    
    // MARK: - 统计项
    
    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                
                Text(value)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }
            
            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 记录列表
    
    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记录")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
                
                Text("\(records.count) 条")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            
            if records.isEmpty {
                Text("暂无记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(records) { record in
                        recordRow(record)
                    }
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(HoloRadius.lg)
    }
    
    // MARK: - 记录行
    
    private func recordRow(_ record: HabitRecord) -> some View {
        HStack {
            Text(record.formattedDate)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            Spacer()
            
            if snapshot.isCheckInType {
                Image(systemName: record.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(record.isCompleted ? .holoSuccess : .holoTextSecondary)
            } else if record.valueDouble != nil {
                Text(record.formattedValue(unit: snapshot.unit))
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }
            
            Button {
                deleteRecord(record)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.holoError.opacity(0.7))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.holoBackground.opacity(0.5))
        .cornerRadius(HoloRadius.sm)
    }
    
    // MARK: - 操作方法
    
    private func archiveHabit() {
        let habitId = habit.id
        if let onWillDelete = onWillDelete {
            // 有回调时，让父视图关闭 sheet（确保 onReceive 被清理）
            onWillDelete(.archive(habitId))
        } else {
            // 没有回调时，自己处理
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                try? HabitRepository.shared.archiveHabitById(habitId)
            }
        }
    }

    private func deleteHabit() {
        let habitId = habit.id
        if let onWillDelete = onWillDelete {
            // 有回调时，让父视图关闭 sheet（确保 onReceive 被清理）
            onWillDelete(.delete(habitId))
        } else {
            // 没有回调时，自己处理
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                try? HabitRepository.shared.deleteHabitById(habitId)
            }
        }
    }
    
    private func deleteRecord(_ record: HabitRecord) {
        try? HabitRepository.shared.deleteRecord(record)
        refreshAll()
    }
}

// MARK: - Preview

#Preview {
    Text("习惯详情预览")
}
