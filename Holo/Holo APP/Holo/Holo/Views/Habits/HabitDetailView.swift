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

    // 目标归属
    var goalTitle: String? = nil
    var goalDomain: GoalDomain? = nil
    
    // 统计数据
    var streak: HabitStreak = .zero()
    var completedCount: Int = 0
    var completionRate: Double = 0
    var totalDays: Int = 0
    var periodStats: HabitPeriodStats = HabitPeriodStats(
        total: 0, average: 0, min: 0, max: 0, count: 0,
        latestValue: nil, earliestValue: nil
    )
    
    var habitColor: Color {
        Color(hex: color)
    }

    var isCustomIcon: Bool {
        HabitIconPresets.allItems.first(where: { $0.name == icon })?.isCustom ?? false
    }
}

/// 习惯详情视图
struct HabitDetailView: View {
    
    // MARK: - Properties
    
    let habit: Habit
    
    /// 删除/归档前的回调，传入待执行操作，父视图在 sheet onDismiss 中执行
    var onWillDelete: ((PendingHabitAction) -> Void)? = nil
    
    @Environment(\.dismiss) var dismiss
    
    /// 非 nil 表示快捷周期；nil 表示已应用自定义周期
    @State private var selectedRange: HabitDateRange? = .week
    @State private var customStartDate: Date = Calendar.current.date(
        byAdding: .day,
        value: -29,
        to: Calendar.current.startOfDay(for: Date())
    ) ?? Calendar.current.startOfDay(for: Date())
    @State private var customEndDate: Date = Date()
    @State private var showCustomRangeSheet: Bool = false
    @State private var records: [HabitRecord] = []
    @State private var snapshot = HabitDetailSnapshot()
    @State private var showEditSheet: Bool = false
    @State private var showDeleteAlert: Bool = false
    /// 待删除的记录（用于确认弹窗）
    @State private var recordToDelete: HabitRecord? = nil
    /// 缓存的 habit ID（避免 onReceive 访问已删除的 habit 对象）
    @State private var cachedHabitId: UUID? = nil
    /// 标记是否正在删除或归档当前习惯
    @State private var isDeletingOrArchiving: Bool = false
    /// 最近 7 天可补签的漏卡日（升序；仅每日打卡型好习惯会有值）
    @State private var retroEligibleDays: [Date] = []
    /// 补签弹层目标
    @State private var retroContext: HabitRetroactiveSheetContext? = nil
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    habitHeader
                    recoverBanner
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
                cachedHabitId = habit.id  // 缓存 ID，供 onReceive 使用
                refreshAll()
            }
            .onChange(of: selectedRange) { _, _ in
                refreshAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { notification in
                // 如果正在删除或归档当前习惯，忽略通知（完全不访问 habit 对象）
                if isDeletingOrArchiving { return }

                // 用缓存的 ID 比较，完全避免访问已删除的 habit 对象
                if let changedHabitId = notification.object as? UUID, changedHabitId != cachedHabitId {
                    return
                }
                refreshAll()
            }
            .sheet(isPresented: $showEditSheet) {
                AddHabitSheet(onSave: {
                    refreshAll()
                }, editingHabit: habit)
            }
            .sheet(isPresented: $showCustomRangeSheet) {
                HabitCustomDateRangeSheet(
                    initialStartDate: customStartDate,
                    initialEndDate: customEndDate
                ) { startDate, endDate in
                    customStartDate = startDate
                    customEndDate = endDate

                    if selectedRange == nil {
                        refreshAll()
                    } else {
                        selectedRange = nil
                    }
                }
            }
            .sheet(item: $retroContext) { context in
                HabitRetroactiveSheet(context: context)
            }
            .alert("确认删除", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteHabit()
                }
            } message: {
                Text("删除后将无法恢复，包括所有记录数据。")
            }
            .alert("确认删除记录", isPresented: .init(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            )) {
                Button("取消", role: .cancel) {
                    recordToDelete = nil
                }
                Button("删除", role: .destructive) {
                    if let record = recordToDelete {
                        deleteRecord(record)
                    }
                    recordToDelete = nil
                }
            } message: {
                Text("确定要删除这条记录吗？")
            }
            .swipeBackToDismiss { dismiss() }
        }
    }
    
    // MARK: - 数据刷新（所有 Core Data 查询在此完成，不在 body 中执行）
    
    private func refreshAll() {
        // 如果正在删除/归档，不执行任何数据刷新
        if isDeletingOrArchiving { return }

        Task { @MainActor in
            // 再次检查（Task 执行前对象可能已被删除或正在删除）
            if isDeletingOrArchiving { return }
            
            let repo = HabitRepository.shared
            
            // 加载记录
            let loadedRecords = repo.getRecords(for: habit, in: effectiveDateRange)
            
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

            s.goalTitle = habit.goal?.title
            s.goalDomain = habit.goal?.goalDomain
            
            if habit.isCheckInType {
                s.streak = repo.calculateStreakInfo(for: habit)
                s.completedCount = repo.calculatePeriodCompletionCount(for: habit, dateRange: effectiveDateRange)
                s.totalDays = selectedPeriodDayCount ?? max(loadedRecords.count, 1)
                s.completionRate = s.totalDays > 0
                    ? Double(s.completedCount) / Double(s.totalDays) * 100
                    : 0
            } else {
                s.periodStats = repo.calculatePeriodStats(for: habit, dateRange: effectiveDateRange)
            }
            
            // 更新 @State 变量
            records = loadedRecords
            snapshot = s
            retroEligibleDays = repo.retroactiveEligibleDays(for: habit)
        }
    }
    
    // MARK: - 习惯信息头部
    
    private var habitHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(snapshot.habitColor.opacity(0.1))
                    .frame(width: 80, height: 80)

                snapshot.iconImage(size: 36)
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

                if let goalTitle = snapshot.goalTitle, let domain = snapshot.goalDomain {
                    HStack(spacing: 3) {
                        Image(systemName: domain.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(goalTitle)
                            .font(.holoCaption)
                            .lineLimit(1)
                    }
                    .foregroundColor(domain.badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(domain.badgeColor.opacity(0.12))
                    .cornerRadius(HoloRadius.sm)
                }
            }
        }
        .padding(.vertical, HoloSpacing.md)
    }

    // MARK: - 找回断签横幅（最近 7 天有漏卡时出现）

    @ViewBuilder
    private var recoverBanner: some View {
        // 漏卡日列表已按类型/频率/坏习惯过滤，这里只需判空
        if !retroEligibleDays.isEmpty {
            let missed = retroEligibleDays
            Button {
                retroContext = HabitRetroactiveSheetContext(habit: habit, preselectedDay: nil)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .fill(Color.holoPrimary)
                            .frame(width: 36, height: 36)

                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("最近 \(HabitRetroactivePolicy.lookbackDays) 天有 \(missed.count) 天漏卡")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.holoTextPrimary)

                        Text(missed.count == 1
                             ? "\(missedDayText(missed[0])) · 补上可恢复连续打卡"
                             : "最早 \(missedDayText(missed[0])) · 补上可恢复连续打卡")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    Text("找回 ›")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.holoPrimary)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                        .stroke(Color.holoPrimary.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func missedDayText(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[Calendar.current.component(.weekday, from: day) - 1]
        return "\(formatter.string(from: day))（周\(weekday)）"
    }
    
    // MARK: - 时间范围选择器

    private var effectiveDateRange: ClosedRange<Date>? {
        if let selectedRange {
            return selectedRange.dateRange()
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: customStartDate)
        let endDay = calendar.startOfDay(for: customEndDate)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? customEndDate
        return min(start, end)...max(start, end)
    }

    private var selectedPeriodDayCount: Int? {
        if let selectedRange {
            return selectedRange.days
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: customStartDate)
        let end = calendar.startOfDay(for: customEndDate)
        return (calendar.dateComponents([.day], from: min(start, end), to: max(start, end)).day ?? 0) + 1
    }

    private var selectedRangeLabel: String {
        if let selectedRange {
            return selectedRange.displayName
        }
        return "自定义周期"
    }

    private var customRangeText: String {
        HabitCustomDateRangeSheet.rangeText(from: customStartDate, to: customEndDate)
    }

    private var rangePicker: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(HabitDateRange.allCases, id: \.self) { range in
                    rangeButton(
                        title: range.displayName,
                        isSelected: selectedRange == range
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedRange = range
                        }
                    }
                }

                rangeButton(title: "自定义", isSelected: selectedRange == nil) {
                    showCustomRangeSheet = true
                }
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )

            if selectedRange == nil {
                Button {
                    showCustomRangeSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                        Text(customRangeText)
                    }
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rangeButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.holoPrimary : Color.holoCardBackground)
        }
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
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }
    
    // MARK: - 打卡型统计（使用 snapshot 数据，不做 Core Data 查询）
    
    private var checkInStatsView: some View {
        HStack(spacing: 0) {
            statItem(
                value: "\(snapshot.streak.value)",
                label: "连续\(snapshot.streak.unit.rawValue)",
                icon: "flame.fill",
                color: .holoPrimary
            )
            
            Divider().frame(height: 40)
            
            statItem(
                value: "\(snapshot.completedCount)",
                label: "\(selectedRangeLabel)完成",
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
                        value: stats.count > 0 ? formatValue(stats.min) : "-",
                        label: "最低",
                        icon: "arrow.down",
                        color: .holoInfo
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: stats.count > 0 ? formatValue(stats.max) : "-",
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
            
            if records.isEmpty && visibleMissedDays.isEmpty {
                Text("暂无记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(detailRows) { row in
                        if let record = row.record {
                            recordRow(record)
                        } else if let day = row.missedDay {
                            missedDayRow(day)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    /// 列表行数据：真实记录与漏卡虚拟行按日倒序混排
    private struct DetailListRow: Identifiable {
        let id = UUID()
        let sortKey: Date
        let record: HabitRecord?
        let missedDay: Date?

        static func record(_ record: HabitRecord) -> DetailListRow {
            DetailListRow(sortKey: record.date, record: record, missedDay: nil)
        }

        static func missedDay(_ day: Date) -> DetailListRow {
            DetailListRow(sortKey: day, record: nil, missedDay: day)
        }
    }

    private var detailRows: [DetailListRow] {
        let missed = visibleMissedDays
        guard !missed.isEmpty else { return records.map { DetailListRow.record($0) } }
        var rows = records.map { DetailListRow.record($0) } + missed.map { DetailListRow.missedDay($0) }
        rows.sort { $0.sortKey > $1.sortKey }
        return rows
    }

    /// 当前展示周期覆盖的漏卡日（周期外的不插行）
    private var visibleMissedDays: [Date] {
        guard !retroEligibleDays.isEmpty, let range = effectiveDateRange else { return [] }
        return retroEligibleDays.filter { range.contains($0) }
    }

    /// 漏卡虚拟行：未打卡 + 直接补签入口
    private func missedDayRow(_ day: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 14))
                .foregroundColor(.holoError.opacity(0.7))

            Text("\(missedDayText(day)) · 未打卡")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            Button {
                retroContext = HabitRetroactiveSheetContext(habit: habit, preselectedDay: day)
            } label: {
                Text("补签")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                .fill(Color.holoPrimary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                        .stroke(Color.holoPrimary.opacity(0.18), lineWidth: 1)
                )
        )
    }
    
    // MARK: - 记录行

    private func recordRow(_ record: HabitRecord) -> some View {
        HStack {
            if record.isRetroactive {
                // 补签记录：目标日 + 「补」标记，补签时刻见行尾
                Text(retroDayText(record))
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text("补")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.1))
                    .cornerRadius(HoloRadius.sm)

                Spacer()

                Text("补签于 \(record.retroactiveCreatedAtText)")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
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
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.holoBackground.opacity(0.5))
        .cornerRadius(HoloRadius.sm)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                recordToDelete = record
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
    }

    /// 补签记录的目标日文本（date 归一到当天零点）
    private func retroDayText(_ record: HabitRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: record.date)
    }
    
    // MARK: - 操作方法
    
    private func archiveHabit() {
        let habitId = habit.id
        isDeletingOrArchiving = true  // 立即标记，阻止 onReceive 处理通知
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
        isDeletingOrArchiving = true  // 立即标记，阻止 onReceive 处理通知
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
        // 同步移除，避免 SwiftUI 重新渲染时访问已删除的 Core Data 对象
        records.removeAll { $0.id == record.id }
        try? HabitRepository.shared.deleteRecord(record)
        refreshAll()
    }
}

/// 习惯统计自定义日期面板。只有点击“应用”才会改变详情页当前周期。
private struct HabitCustomDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var startDate: Date
    @State private var endDate: Date

    let onApply: (Date, Date) -> Void

    init(
        initialStartDate: Date,
        initialEndDate: Date,
        onApply: @escaping (Date, Date) -> Void
    ) {
        _startDate = State(initialValue: initialStartDate)
        _endDate = State(initialValue: initialEndDate)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "开始日期",
                        selection: $startDate,
                        in: ...min(endDate, Date()),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "结束日期",
                        selection: $endDate,
                        in: max(startDate, .distantPast)...Date(),
                        displayedComponents: .date
                    )
                } footer: {
                    Text("共 \(dayCount) 天 · \(Self.rangeText(from: startDate, to: endDate))")
                }
            }
            .navigationTitle("自定义周期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(startDate, endDate)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var dayCount: Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return (calendar.dateComponents([.day], from: min(start, end), to: max(start, end)).day ?? 0) + 1
    }

    static func rangeText(from startDate: Date, to endDate: Date) -> String {
        let calendar = Calendar.current
        let start = min(startDate, endDate)
        let end = max(startDate, endDate)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.component(.year, from: start) == calendar.component(.year, from: end)
            ? "M月d日"
            : "yyyy年M月d日"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

// MARK: - Preview

#Preview {
    Text("习惯详情预览")
}
