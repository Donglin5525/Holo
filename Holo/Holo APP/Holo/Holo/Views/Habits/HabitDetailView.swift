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
    var isPaused: Bool = false
    var pausedUntil: Date? = nil
    var isArchived: Bool = false

    // 目标归属
    var goalTitle: String? = nil
    var goalDomain: GoalDomain? = nil
    
    // 统计数据
    var streak: HabitStreak = .zero()
    var completedCount: Int = 0
    var completionRate: Double = 0
    var totalDays: Int = 0
    /// 全历史累计（打卡型好习惯=完成次数；计数类=数值总和；坏习惯/测量类=nil 不展示）
    var lifetimeTotal: Double? = nil
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
    /// 正在编辑的记录（record ID 精确定位，方案 §7：不用「当天最后一条」模糊定位）
    @State private var recordToEdit: HabitRecord? = nil
    /// 缓存的 habit ID（避免 onReceive 访问已删除的 habit 对象）
    @State private var cachedHabitId: UUID? = nil
    /// 标记是否正在删除或归档当前习惯
    @State private var isDeletingOrArchiving: Bool = false
    /// 最近 7 天可补签的漏卡日（升序；仅每日打卡型好习惯会有值）
    @State private var retroEligibleDays: [Date] = []
    /// 补签弹层目标
    @State private var retroContext: HabitRetroactiveSheetContext? = nil
    /// 归属目标单选弹层
    @State private var showGoalPicker: Bool = false
    @State private var showSaveErrorAlert: Bool = false
    @State private var saveErrorMessage: String? = nil
    /// 打卡提醒（仅打卡型；改动即保存）
    @State private var reminderMode: HabitReminderMode = .follow
    @State private var reminderTime: Date = Date()
    /// 暂停弹层（Plus 功能，非 Plus 走统一付费墙）
    @State private var showPauseSheet: Bool = false
    /// 测量记录输入（详情内直接记录）
    @State private var showMeasureInput: Bool = false
    @ObservedObject private var entitlement = HoloEntitlementState.shared
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    habitHeader
                    if snapshot.isArchived {
                        archivedBanner
                    }
                    if snapshot.isPaused {
                        pausedBanner
                    }
                    recordActionBar
                    recoverBanner
                    rangePicker
                    statsSection
                    milestoneSection
                    if snapshot.isCheckInType && !snapshot.isPaused {
                        reminderSection
                    }
                    recordsSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoToolBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }

                        if snapshot.isPaused {
                            Button {
                                resumeNow()
                            } label: {
                                Label("恢复习惯", systemImage: "play.circle")
                            }
                        } else {
                            Button {
                                requestPause()
                            } label: {
                                Label("暂停", systemImage: "pause.circle")
                            }
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
                            .foregroundColor(.holoToolText)
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
            .sheet(isPresented: $showPauseSheet) {
                HabitPauseSheet(habit: habit)
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
            .sheet(isPresented: $showGoalPicker) {
                GoalPickerSheet(currentGoalId: habit.goal?.id) { goal in
                    applyGoalSelection(goal)
                }
            }
            .alert("保存失败", isPresented: $showSaveErrorAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
            .sheet(item: $retroContext) { context in
                HabitRetroactiveSheet(context: context)
            }
            .sheet(isPresented: $showMeasureInput) {
                HabitMeasureInputSheet(
                    snapshot: measureRowSnapshot
                ) { value, note in
                    Task {
                        _ = await HabitActionCoordinator.shared.perform(
                            .addNumeric(value: value), habitId: habit.id, note: note
                        )
                    }
                }
            }
            .sheet(item: $recordToEdit) { record in
                HabitRecordEditSheet(
                    record: record,
                    isCountType: snapshot.isCountType,
                    unit: snapshot.unit
                ) { value, note in
                    updateRecordById(record.id, value: value, note: note)
                }
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
            s.isPaused = habit.isPaused
            s.pausedUntil = habit.pausedUntil
            s.isArchived = habit.isArchived

            if habit.isCheckInType {
                s.streak = repo.calculateStreakInfo(for: habit)
                s.completedCount = repo.calculatePeriodCompletionCount(for: habit, dateRange: effectiveDateRange)
                // 分母挖掉冻结日：暂停期不拉低完成率
                let rawDays = selectedPeriodDayCount ?? max(loadedRecords.count, 1)
                let pausedDays = effectiveDateRange.map { repo.pausedDayCount(for: habit, in: $0) } ?? 0
                s.totalDays = max(rawDays - pausedDays, 1)
                s.completionRate = s.totalDays > 0
                    ? Double(s.completedCount) / Double(s.totalDays) * 100
                    : 0
            } else {
                s.periodStats = repo.calculatePeriodStats(for: habit, dateRange: effectiveDateRange)
            }
            s.lifetimeTotal = repo.calculateLifetimeTotal(for: habit)
            
            // 更新 @State 变量
            records = loadedRecords
            snapshot = s
            retroEligibleDays = repo.retroactiveEligibleDays(for: habit)

            // 打卡提醒状态同步（与已存值一致时 onChange 不触发，不会回写）
            if habit.isCheckInType {
                reminderMode = habit.habitReminderMode
                var timeComps = DateComponents()
                timeComps.hour = Int(habit.reminderHour)
                timeComps.minute = Int(habit.reminderMinute)
                reminderTime = Calendar.current.date(from: timeComps) ?? reminderTime
            }
        }
    }

    // MARK: - 暂停 / 恢复（Plus 功能）

    /// 暂停入口：非 Plus 走统一付费墙，购买成功后自动弹暂停弹层
    private func requestPause() {
        if entitlement.isPlusActive {
            showPauseSheet = true
        } else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .habitPause) {
                await MainActor.run {
                    showPauseSheet = true
                }
            }
        }
    }

    private func resumeNow() {
        do {
            try HabitRepository.shared.resumeHabit(habit)
            HoloToastCenter.shared.show(
                String(localized: "已恢复「\(habit.name)」，从冻结的进度接着算"),
                type: .success
            )
        } catch {
            HoloToastCenter.shared.show(error.localizedDescription, type: .error)
        }
    }

    /// 已归档横幅：状态说明 + 取消归档（补录前需先取消归档，方案 §10.3）
    private var archivedBanner: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 20))
                .foregroundColor(.holoToolTextSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("已归档")
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.holoToolText)
                Text("历史记录完整保留；要继续记录或补录，先取消归档")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer()

            Button {
                unarchiveNow()
            } label: {
                Text("取消归档")
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.holoToolAction))
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolInset)
        )
    }

    private func unarchiveNow() {
        do {
            try HabitRepository.shared.unarchiveHabitById(habit.id)
            HoloToastCenter.shared.show(String(localized: "已取消归档，习惯回到进行中"), type: .success)
        } catch {
            HoloToastCenter.shared.show(error.localizedDescription, type: .error)
        }
    }

    /// 测量输入弹层的最小行快照（仅名称/单位/类型供弹层文案）
    private var measureRowSnapshot: HabitRowSnapshot {
        HabitRowSnapshot(
            id: habit.id, name: habit.name, icon: habit.icon,
            isCustomIcon: snapshot.isCustomIcon, colorHex: snapshot.color,
            kind: .measure, frequency: habit.habitFrequency,
            isBadHabit: habit.isBadHabit, lifecycle: .active,
            pauseSummaryText: nil, target: nil,
            today: HabitTodayProgress(isCheckInDone: false, isRecorded: false, isTargetMet: false,
                                      todayValue: nil, periodValueText: nil, periodRangeText: nil,
                                      isOverLimit: false),
            streak: nil, trail: [], allowsTodayRecord: true
        )
    }

    /// 按 record ID 更新记录（数值可改值/备注；打卡记录改备注）
    private func updateRecordById(_ recordId: UUID, value: Double?, note: String?) {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", recordId as CVarArg)
        request.fetchLimit = 1
        guard let record = try? HabitRepository.shared.context.fetch(request).first else {
            saveErrorMessage = String(localized: "这条记录已变化，请到详情确认")
            showSaveErrorAlert = true
            return
        }
        do {
            try HabitRepository.shared.updateRecord(record, value: value, note: note)
        } catch {
            saveErrorMessage = String(localized: "这次没有保存成功，内容还在，可以重试")
            showSaveErrorAlert = true
        }
    }

    // MARK: - 操作条（立即可见的常用动作，方案 §7）

    private var recordActionBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            // 本次记录：详情内直接记录（与今天页同一动作语义）
            if !snapshot.isArchived {
                if snapshot.isCheckInType {
                    if !snapshot.isPaused {
                        Button {
                            checkInHere()
                        } label: {
                            actionBarLabel(icon: "checkmark.circle",
                                           text: habit.isBadHabit ? String(localized: "记录发生") : String(localized: "打卡"))
                        }
                        .buttonStyle(HoloPressStyle())
                    }
                } else if snapshot.isCountType {
                    Button {
                        Task {
                            _ = await HabitActionCoordinator.shared.perform(.increment(amount: 1), habitId: habit.id)
                        }
                    } label: {
                        actionBarLabel(icon: "plus.circle", text: String(localized: "记一次"))
                    }
                    .buttonStyle(HoloPressStyle())
                } else {
                    Button {
                        showMeasureInput = true
                    } label: {
                        actionBarLabel(icon: "square.and.pencil", text: String(localized: "记录数值"))
                    }
                    .buttonStyle(HoloPressStyle())
                }
            }

            Spacer(minLength: 0)

            Button {
                showEditSheet = true
            } label: {
                actionBarLabel(icon: "pencil", text: String(localized: "编辑"))
            }
            .buttonStyle(HoloPressStyle())

            if !snapshot.isArchived {
                if canBackfill {
                    Button {
                        retroContext = HabitRetroactiveSheetContext(habit: habit, preselectedDay: nil, mode: .sign)
                    } label: {
                        actionBarLabel(icon: "clock.arrow.circlepath", text: String(localized: "补签 / 补记"))
                    }
                    .buttonStyle(HoloPressStyle())
                }

                if snapshot.isPaused {
                    Button {
                        resumeNow()
                    } label: {
                        actionBarLabel(icon: "play.circle", text: String(localized: "恢复"))
                    }
                    .buttonStyle(HoloPressStyle())
                } else {
                    Button {
                        requestPause()
                    } label: {
                        actionBarLabel(icon: "pause.circle", text: String(localized: "暂停"))
                    }
                    .buttonStyle(HoloPressStyle())
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func actionBarLabel(icon: String, text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(snapshot.habitColor)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.holoToolText)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolSurface)
        )
    }

    /// 详情内打卡（不自动打卡；与今天页同一闸：暂停期不可）
    private func checkInHere() {
        Task {
            _ = await HabitActionCoordinator.shared.perform(.toggleCheckIn, habitId: habit.id)
        }
    }

    // MARK: - 里程碑（静态可回看，方案 §7/§9.4）

    @State private var milestoneItems: [HabitMilestone] = []

    private var milestoneSection: some View {
        let store = HabitMilestoneStore()
        let achieved: [HabitMilestone] = milestoneLabel.map { label in
            store.achievedMilestones(habitId: habit.id, streak: label, frequency: habit.habitFrequency)
        } ?? []
        return Group {
            if !achieved.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("里程碑")
                        .holoText(.body)
                        .foregroundColor(.holoToolText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(achieved) { milestone in
                                HStack(spacing: 6) {
                                    Image(systemName: store.isDisplayed(milestone) ? "rosette" : "rosette")
                                        .font(.system(size: 13))
                                        .foregroundColor(snapshot.habitColor)
                                    Text(milestone.displayText)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.holoToolText)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(Color.holoToolSurface)
                                )
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoToolSurface)
                .cornerRadius(HoloRadius.lg)
            }
        }
    }

    /// 里程碑用的连续标签（好习惯；数值坏习惯不出）
    private var milestoneLabel: HabitStreakLabel? {
        guard !habit.isBadHabit else { return nil }
        let data = HabitPresentationProjector.buildData(
            records: HabitRepository.shared.allRecordFacts(),
            pauseWindowsByHabit: HabitRepository.shared.pauseWindowsByIds([habit.id]),
            now: Date()
        )
        return HabitPresentationProjector.streakLabel(for: habit, data: data)
    }

    /// 暂停态横幅：说明进度已保留 + 一键恢复
    private var pausedBanner: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(snapshot.habitColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("已暂停")
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.holoToolText)
                Text(pausedSubtitleText)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer()

            Button {
                resumeNow()
            } label: {
                Text("恢复")
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(snapshot.habitColor))
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(snapshot.habitColor.opacity(0.08))
        )
    }

    private var pausedSubtitleText: String {
        if let until = snapshot.pausedUntil {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("M月d日")
            return String(localized: "连续进度已保留 · 将于 \(formatter.string(from: until)) 自动恢复")
        }
        return String(localized: "连续进度已保留 · 随时可恢复")
    }

    /// 打卡提醒改动即保存（与已存值相同时跳过，避免刷新回环）
    private func saveReminderSettings() {
        let calendar = Calendar.current
        let newTime = (
            hour: calendar.component(.hour, from: reminderTime),
            minute: calendar.component(.minute, from: reminderTime)
        )
        guard reminderMode != habit.habitReminderMode
            || newTime.hour != Int(habit.reminderHour)
            || newTime.minute != Int(habit.reminderMinute) else { return }

        try? HabitRepository.shared.updateHabit(habit, updates: HabitUpdates(
            reminderMode: reminderMode,
            reminderTime: newTime
        ))
    }

    /// 应用归属目标选择：nil 表示移除关联；落库后刷新头部快照
    private func applyGoalSelection(_ goal: Goal?) {
        do {
            if let goal {
                try GoalRepository.shared.linkHabit(habit, to: goal)
            } else if let current = habit.goal {
                try GoalRepository.shared.unlinkHabit(habit, from: current)
            }
            refreshAll()
            GoalNotificationService.broadcastGoalDataChange()
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveErrorAlert = true
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
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolText)
            
            HStack(spacing: 8) {
                Text(snapshot.habitTypeName)
                    .holoText(.supporting)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(snapshot.habitColor)
                    .cornerRadius(HoloRadius.sm)
                
                Text(snapshot.frequencyTargetText)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)

                if let goalTitle = snapshot.goalTitle, let domain = snapshot.goalDomain {
                    Button {
                        showGoalPicker = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: domain.icon)
                                .font(.system(size: 10, weight: .medium))
                            Text(goalTitle)
                                .holoText(.supporting)
                                .lineLimit(1)
                        }
                        .foregroundColor(domain.badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(domain.badgeColor.opacity(0.12))
                        .cornerRadius(HoloRadius.sm)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showGoalPicker = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "target")
                                .font(.system(size: 10, weight: .medium))
                            Text("关联目标")
                                .holoText(.supporting)
                        }
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoToolTextSecondary.opacity(0.1))
                        .cornerRadius(HoloRadius.sm)
                    }
                    .buttonStyle(.plain)
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
                            .foregroundColor(.holoToolText)

                        Text(missed.count == 1
                             ? String(localized: "\(missedDayText(missed[0])) · 补上可恢复连续打卡")
                             : String(localized: "最早 \(missedDayText(missed[0])) · 补上可恢复连续打卡"))
                            .font(.system(size: 11))
                            .foregroundColor(.holoToolTextSecondary)
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
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return formatter.string(from: day)
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
                        withAnimation(HoloAnimation.quick) {
                            selectedRange = range
                        }
                    }
                }

                rangeButton(title: String(localized: "自定义"), isSelected: selectedRange == nil) {
                    showCustomRangeSheet = true
                }
            }
            .background(Color.holoToolSurface)
            .cornerRadius(HoloRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .stroke(Color.holoToolBorder, lineWidth: 1)
            )

            if selectedRange == nil {
                Button {
                    showCustomRangeSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                        Text(customRangeText)
                    }
                    .holoText(.supporting)
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
                .holoText(.supporting)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(isSelected ? .white : .holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.holoPrimary : Color.holoToolSurface)
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
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.lg)
    }
    
    // MARK: - 打卡型统计（使用 snapshot 数据，不做 Core Data 查询）
    
    private var checkInStatsView: some View {
        HStack(spacing: 0) {
            statItem(
                value: "\(snapshot.streak.value)",
                label: String(localized: "连续\(snapshot.streak.unit.displayName)"),
                icon: "flame.fill",
                color: .holoPrimary
            )

            Divider().frame(height: 40)

            statItem(
                value: "\(snapshot.completedCount)",
                label: String(localized: "本期完成"),
                icon: "checkmark.circle.fill",
                color: .holoSuccess
            )

            Divider().frame(height: 40)

            statItem(
                value: String(format: "%.0f%%", snapshot.completionRate),
                label: String(localized: "完成率"),
                icon: "chart.pie.fill",
                color: .holoInfo
            )

            // 累计不跟随时间范围；坏习惯无累计（lifetimeTotal 为 nil）回落三项
            if let lifetimeTotal = snapshot.lifetimeTotal {
                Divider().frame(height: 40)

                statItem(
                    value: formatValue(lifetimeTotal),
                    label: String(localized: "累计"),
                    icon: "infinity",
                    color: .holoSuccess
                )
            }
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
                        label: String(localized: "总计"),
                        icon: "sum",
                        color: snapshot.habitColor
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: formatValue(stats.average),
                        label: String(localized: "日均"),
                        icon: "divide",
                        color: .holoInfo
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: formatValue(stats.max),
                        label: String(localized: "峰值"),
                        icon: "arrow.up",
                        color: .holoPrimary
                    )
                    // 累计恒为全部历史数值总和，不随时间范围变化
                    if let lifetimeTotal = snapshot.lifetimeTotal {
                        Divider().frame(height: 40)
                        statItem(
                            value: formatValue(lifetimeTotal),
                            label: String(localized: "累计"),
                            icon: "infinity",
                            color: .holoSuccess
                        )
                    }
                }
            } else {
                HStack(spacing: 0) {
                    if let change = stats.change {
                        statItem(
                            value: (change >= 0 ? "+" : "") + formatValue(change),
                            label: String(localized: "变化"),
                            icon: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                            color: change >= 0 ? .holoSuccess : .holoError
                        )
                    } else {
                        statItem(
                            value: "-",
                            label: String(localized: "变化"),
                            icon: "minus",
                            color: .holoToolTextSecondary
                        )
                    }
                    Divider().frame(height: 40)
                    statItem(
                        value: stats.count > 0 ? formatValue(stats.min) : "-",
                        label: String(localized: "最低"),
                        icon: "arrow.down",
                        color: .holoInfo
                    )
                    Divider().frame(height: 40)
                    statItem(
                        value: stats.count > 0 ? formatValue(stats.max) : "-",
                        label: String(localized: "最高"),
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
                    .foregroundColor(.holoToolText)
            }
            
            Text(label)
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
                // 四列均分后列宽有限：标签超长（英文/Dynamic Type 大字号）不折行，轻微缩字保住四列数值水平对齐
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 打卡提醒（打卡型，改动即保存）

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("打卡提醒")
                .holoText(.body)
                .foregroundColor(.holoToolText)

            HabitReminderModePicker(mode: $reminderMode, time: $reminderTime)
                .onChange(of: reminderMode) { _, _ in
                    saveReminderSettings()
                }
                .onChange(of: reminderTime) { _, _ in
                    saveReminderSettings()
                }
        }
    }

    // MARK: - 记录列表

    /// 补记入口可见条件：好习惯且创建日早于今天（今天刚创建的习惯没有可补日期）
    private var canBackfill: Bool {
        guard !habit.isBadHabit else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: habit.createdAt) < calendar.startOfDay(for: Date())
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记录")
                    .holoText(.body)
                    .foregroundColor(.holoToolText)

                Spacer()

                if canBackfill {
                    Button {
                        retroContext = HabitRetroactiveSheetContext(habit: habit, preselectedDay: nil, mode: .backfill)
                    } label: {
                        Label("补记", systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(snapshot.habitColor)
                    }
                }

                Text("\(records.count) 条")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
            
            if records.isEmpty && visibleMissedDays.isEmpty {
                Text("暂无记录")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
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
        .background(Color.holoToolSurface)
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
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)

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
                    .holoText(.body)
                    .foregroundColor(.holoToolText)

                Text("补")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.1))
                    .cornerRadius(HoloRadius.sm)

                Spacer()

                Text("补签于 \(record.retroactiveCreatedAtText)")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            } else {
                Text(record.formattedDate)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)

                Spacer()

                if snapshot.isCheckInType {
                    Image(systemName: record.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(record.isCompleted ? .holoSuccess : .holoToolTextSecondary)
                } else if record.valueDouble != nil {
                    Text(record.formattedValue(unit: snapshot.unit))
                        .holoText(.body)
                        .foregroundColor(.holoToolText)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.holoToolBackground.opacity(0.5))
        .cornerRadius(HoloRadius.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            // 点击记录行：编辑该条（record ID 定位；数值可改值/备注，打卡可补备注）
            if !record.isRetroactive || habit.isNumericType {
                recordToEdit = record
            }
        }
        .contextMenu {
            Button {
                recordToEdit = record
            } label: {
                Label("编辑记录", systemImage: "pencil")
            }
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
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
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
/// 记录编辑弹层：数值记录改值/备注（测量允许 0）；打卡记录补备注（方案 §5.4）
struct HabitRecordEditSheet: View {
    let record: HabitRecord
    let isCountType: Bool
    let unit: String?
    var onSave: (Double?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var valueText: String = ""
    @State private var note: String = ""
    @State private var errorMessage: String?
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            Text(String(localized: "编辑记录"))
                .font(.holoHeading)
                .foregroundColor(.holoToolText)

            if !isCountType || record.valueDouble != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(String(localized: "数值"), text: $valueText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundColor(.holoToolText)
                            .focused($valueFocused)
                        if let unit, !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 14))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.holoError)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))
            }

            TextField(String(localized: "备注"), text: $note)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .padding()
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))

            HStack(spacing: HoloSpacing.md) {
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "取消"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoToolText)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolInset))
                }
                .buttonStyle(HoloPressStyle())

                Button {
                    save()
                } label: {
                    Text(String(localized: "保存"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoToolOnAction)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.lg)
        .presentationDetents([.height(300)])
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { valueFocused = false }
            }
        }
        .onAppear {
            if let v = record.valueDouble {
                valueText = HabitPresentationProjector.formatValue(v)
            }
            note = record.note ?? ""
        }
    }

    private func save() {
        var newValue: Double? = nil
        if record.valueDouble != nil {
            let formatter = NumberFormatter()
            formatter.locale = Locale.current
            formatter.numberStyle = .decimal
            guard let number = formatter.number(from: valueText.trimmingCharacters(in: .whitespaces)),
                  let parsed = number as? Double, parsed.isFinite,
                  isCountType ? parsed > 0 : parsed >= 0 else {
                errorMessage = String(localized: isCountType ? "计数值需要大于 0" : "请输入有效的数值（0 及以上）")
                valueFocused = true
                return
            }
            newValue = parsed
        }
        onSave(newValue, note.isEmpty ? nil : note)
        dismiss()
    }
}

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
            .holoSheetShell()
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
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: start) == calendar.component(.year, from: end)
            ? "MMMd"
            : "yMMMd"
        )
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

// MARK: - Preview

#Preview {
    Text("习惯详情预览")
}
