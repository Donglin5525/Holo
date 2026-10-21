//
//  DailyKanbanView.swift
//  Holo
//
//  「今天」主视图（今日看板 Matter 化方案 §4/§9）
//
//  新版（todayCommandCenterEnabled）：当天概况 → 重点目标 → 今天的安排 → 当天近况。
//  今天只做来源事实摘要与原模块跳转，记录和管理沿用原模块。
//  旧版（flag 关闭）：完整保留原今日看板布局（回滚不删数据）。
//

import SwiftUI
import CoreData
import os.log

struct DailyKanbanView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared
    @ObservedObject private var healthRepo = HealthRepository.shared
    @ObservedObject private var goalRepo = GoalRepository.shared
    /// 完成协调层（G1 完成契约：议程区完成改走统一撤回窗口，撤回 banner 与其他入口共享）
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey) private var userName: String = UserDisplayNameSettings.fallbackDisplayName

    /// 周一晨报入口信号：为 true 时顶部展示上周小结卡（默认 false，手动进看板不显示）
    var showWeeklyBrief: Bool = false
    /// 新版统一 ViewModel（HomeView 持有唯一实例；flag 关闭时为 nil 走旧版逻辑）
    var todayViewModel: HoloTodayViewModel? = nil
    /// scoped Chat 出口（HomeView 提供：存上下文 → 关 Today → 切 .ai）
    var onOpenChatWithMatter: ((UUID) -> Void)? = nil
    var onOpenAI: (() -> Void)? = nil
    var onOpenFinance: (() -> Void)? = nil
    var onAddTask: (() -> Void)? = nil
    /// 「对 Holo 说」快速记录出口（原「记录今天」误指想法编辑器，已按激活方案改指向 AI + 预填）
    var onQuickRecord: (() -> Void)? = nil

    @StateObject private var dispatcher: TodayActionDispatcher

    init(
        showWeeklyBrief: Bool = false,
        todayViewModel: HoloTodayViewModel? = nil,
        onOpenChatWithMatter: ((UUID) -> Void)? = nil,
        onOpenAI: (() -> Void)? = nil,
        onOpenFinance: (() -> Void)? = nil,
        onAddTask: (() -> Void)? = nil,
        onQuickRecord: (() -> Void)? = nil
    ) {
        self.showWeeklyBrief = showWeeklyBrief
        self.todayViewModel = todayViewModel
        self.onOpenChatWithMatter = onOpenChatWithMatter
        self.onOpenAI = onOpenAI
        self.onOpenFinance = onOpenFinance
        self.onAddTask = onAddTask
        self.onQuickRecord = onQuickRecord
        _dispatcher = StateObject(wrappedValue: TodayActionDispatcher(
            viewModel: todayViewModel ?? HoloTodayViewModel()
        ))
    }

    @State private var editingHabit: Habit? = nil
    @State private var inputValue: String = ""
    @State private var habitSource: HabitSourceRoute?
    @State private var habitOperationError: String?
    @State private var showGoalCreate = false
    @State private var showReliefSheet = false
    @FocusState private var isInputFocused: Bool

    /// 键盘高度：数值输入弹窗是手写 overlay（非系统 sheet），系统键盘避让管不到，
    /// 这里手动监听键盘，把弹窗整体上移到键盘上方，避免输入框/保存按钮被挡。
    @State private var keyboardHeight: CGFloat = 0

    /// 当前窗口宽度（v2 断点：宽屏双栏）
    @Environment(\.holoContentWidth) private var kanbanWindowWidth
    private var isExpandedWidth: Bool {
        HoloAdaptiveLayout.isExpandedWidth(kanbanWindowWidth)
    }

    private var useNewToday: Bool {
        HoloTodayRolloutPolicy.isEnabled && todayViewModel != nil
    }

    var body: some View {
        if useNewToday {
            newTodayBody
        } else {
            legacyBody
        }
    }

    // MARK: - 新版「今天」

    private var newTodayBody: some View {
        NavigationStack(path: $dispatcher.path) {
            ZStack {
                Color.holoToolBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        headerView
                        if showWeeklyBrief {
                            KanbanWeeklyBriefCard()
                        }
                        if isExpandedWidth {
                            todaySectionsWide
                        } else {
                            todaySections
                        }
                        Spacer().frame(height: 60)
                    }
                    .padding(.horizontal, isExpandedWidth ? 32 : GoalJourneyStyle.pageInset)
                    .padding(.top, 8)
                }
            }
            .navigationDestination(for: HoloTodayRoute.self) { route in
                // 目的地直挂栈内容（不经 .background 隐藏挂载）；真正的闪退根因是
                // MatterDetailView 自带内嵌 NavigationStack（栈中栈，iOS 26 卡死转场 +
                // 连续压栈触发 comparisonTypeMismatch 断言崩溃），已在 MatterDetailView 侧根治。
                routeDestination(route)
            }
            .sheet(item: $dispatcher.scheduleDetailItem) { item in
                ScheduleDetailSheet(item: item)
            }
            .sheet(item: $dispatcher.taskDetailSelection, onDismiss: refreshToday) { taskID in
                // TaskDetailView 全 App 统一弹窗呈现（TasksView/KanbanTaskSection 同款）；
                // 不传 onBack，内部 dismiss 即关闭，sheet(item:) 自动置空 selection
                if let task = TodoRepository.shared.findTask(by: taskID) {
                    TaskDetailView(task: task, repository: TodoRepository.shared)
                }
            }
            .alert("没有保存成功", isPresented: Binding(get: { habitOperationError != nil }, set: { if !$0 { habitOperationError = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(habitOperationError ?? "") }
            .sheet(item: $habitSource) { route in
                HabitSourceDetailView(route: route)
            }
            .sheet(isPresented: $showReliefSheet) {
                TodayReliefSheet()
            }
        }
        .swipeBackToDismiss { dismiss() }
        .task {
            await todayViewModel?.loadIfNeeded()
            goalRepo.loadGoals()
        }
        .onChange(of: dispatcher.path) { _, newValue in
            _ = newValue
        }
    }

    /// iPad 同样保持先目标、后少量安排，不把模块摘要并排堆满。
    private var todaySectionsWide: some View { todaySections }

    /// 今天只汇总事实并定位原模块，不承接记录、打卡或任务完成。
    @ViewBuilder
    private var todaySections: some View {
        if case .ready(let snapshot) = todayViewModel?.state {
            TodayReadOnlySection(snapshot: snapshot, onItem: { dispatcher.perform($0.action) }, onRefresh: refreshToday)
            if let error = dispatcher.localErrorMessage {
                Text(error).goalJourneyText(.supporting).foregroundStyle(Color.holoToolError)
            }
        } else {
            ProgressView("正在读取今天").frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func refreshToday() {
        Task { await todayViewModel?.refreshNow() }
    }

    /// Today 内部路由目的地（§10.1）。
    @ViewBuilder
    private func routeDestination(_ route: HoloTodayRoute) -> some View {
        switch route {
        case .matterList:
            MatterListContent { matterID in
                openChat(matterID: matterID)
            }
            .navigationTitle(String(localized: "进行中的事"))
            .navigationBarTitleDisplayMode(.inline)
        case .matterDetail(let matterID, _):
            MatterDetailView(matterID: matterID) { discussID in
                openChat(matterID: discussID)
            }
        case .scheduleDetail:
            EmptyView()
        }
    }

    /// 讨论出口：存上下文 → 关 Today → 进 resident Chat（由 HomeView 接管）。
    private func openChat(matterID: UUID) {
        MatterChatContextStore.shared.enter(matterID: matterID, source: .matterDetail)
        dismiss()
        onOpenChatWithMatter?(matterID)
    }

    // MARK: - 「帮我理一理」入口（§4.1）

    /// 主行动卡后的轻量整理入口；空态也可进入；iPad 复用同一入口。
    private var reliefEntryButton: some View {
        Button {
            showReliefSheet = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                Text(String(localized: "帮我理一理"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(localized: "说说现在的情况"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.holoPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .fill(Color.holoPrimary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(Color.holoPrimary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("todayReliefEntryButton")
    }

    /// 分叉解决：选择一份完整安排（两台设备今日安排不同；§8.4）。
    private func resolveTodayPlanConflict(_ candidate: HoloTodayPlanConflictCandidate) {
        Task { @MainActor in
            let scope = HoloTodayDayScope.current()
            let read = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext).currentPlan(scope: scope)
            guard case .conflict(let candidates) = read.state else { return }
            do {
                _ = try await HoloTodayPlanService.shared.resolveConflict(
                    chosenPayload: candidate.payload,
                    scope: scope,
                    expectedHeads: candidates.map(\.revisionID),
                    operationID: UUID().uuidString
                )
                HapticManager.light()
            } catch {
                Logger(subsystem: "com.holo.app", category: "UI").error("解决安排分叉失败: \(error.localizedDescription)")
            }
        }
    }

    /// 完成任务（真实回执 + 3 秒撤回，统一走完成协调层；落库延迟到 confirm）。
    private func completeTask(_ item: HoloTodayAgendaItem) {
        guard case .openTask(let taskID) = item.action else { return }
        completionCoordinator.requestCompletion(taskID: taskID, source: .todayAgenda, in: todoRepo)
        HapticManager.light()
    }

    /// 数值由用户真实输入；打卡复用习惯协调层，目标值绝不当作实测值。
    private func checkInHabit(_ row: HoloTodayHabitRow) {
        guard let habit = habitRepo.findHabit(by: row.id) else { return }
        if habit.isNumericType || habit.isBadHabit {
            habitSource = .recent(row.id)
        } else {
            Task {
                let result = await HabitActionCoordinator.shared.perform(.toggleCheckIn, habitId: row.id)
                switch result {
                case .confirmed, .unchanged: break
                case .failed(let message): habitOperationError = message
                default: habitOperationError = "当前无法打卡，请打开习惯核对状态后重试"
                }
            }
        }
    }

    // MARK: - Header（今天 + 日期 + 关闭）

    @ViewBuilder private var headerView: some View {
        if useNewToday {
            HStack(spacing: 8) {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 18)).frame(width: 44, height: 44) }.accessibilityLabel("关闭")
                Text("今天").goalJourneyText(.heading)
                Spacer()
                Text(todayString).goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            }.foregroundStyle(Color.holoToolText).padding(.horizontal, -6).frame(minHeight: 44)
        } else { legacyHeaderView }
    }

    private var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("MMMdE")
        return f.string(from: Date())
    }

    // MARK: - 旧版看板（flag 关闭时完整保留）

    private var legacyBody: some View {
        ZStack {
            Color.holoToolBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    legacyHeaderView
                    if showWeeklyBrief {
                        KanbanWeeklyBriefCard()
                    }
                    KanbanProgressHero(
                        todoRepo: todoRepo,
                        habitRepo: habitRepo,
                        healthRepo: healthRepo,
                        userName: userName,
                        onCreateGoal: { showGoalCreate = true }
                    )

                    if isExpandedWidth {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                KanbanBudgetSection()
                                KanbanHabitSection(
                                    habitRepo: habitRepo,
                                    inputValue: $inputValue,
                                    editingHabit: $editingHabit
                                )
                                KanbanMoodSection()
                            }
                            VStack(spacing: 16) {
                                ScheduleSectionWithDetail()
                                KanbanTaskSection(todoRepo: todoRepo)
                                KanbanHealthSection(healthRepo: healthRepo)
                            }
                        }
                    } else {
                        KanbanBudgetSection()
                        KanbanHabitSection(
                            habitRepo: habitRepo,
                            inputValue: $inputValue,
                            editingHabit: $editingHabit
                        )
                        ScheduleSectionWithDetail()
                        KanbanTaskSection(todoRepo: todoRepo)
                        KanbanMoodSection()
                        KanbanHealthSection(healthRepo: healthRepo)
                    }
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, isExpandedWidth ? 32 : 16)
            }

            // 数值输入弹窗
            if let habit = editingHabit {
                numericInputPopup(habit)
                    .transition(.opacity)
                    .offset(y: -keyboardHeight / 2)
            }
        }
        .animation(HoloAnimation.standard, value: editingHabit != nil)
        .sheet(isPresented: $showGoalCreate) {
            GoalManualCreateSheet(
                onSaved: { _ in showGoalCreate = false },
                onCancel: { showGoalCreate = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            let height = endFrame.origin.y >= UIScreen.main.bounds.height ? 0 : endFrame.height
            withAnimation(.easeInOut(duration: duration)) {
                keyboardHeight = height
            }
        }
        .swipeBackToDismiss { dismiss() }
        .task {
            // 等 Core Data 就绪，避免未就绪时 fetch 静默返回空、内容分批出现
            await CoreDataStack.shared.waitUntilReady()
            habitRepo.loadActiveHabits()
            await healthRepo.fetchTodayData()
            todoRepo.seedDailyRitualsForToday()
        }
    }

    private var legacyHeaderView: some View {
        ZStack {
            Text(String(localized: "今日看板"))
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolText)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoToolText)
                        .frame(width: 36, height: 36)
                        .background(Color.holoToolSurface)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.holoToolBorder, lineWidth: 1))
                }

                Spacer()

                Text(todayString)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolWarning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.holoToolInset)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
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
                                .holoText(.body)
                                .foregroundColor(.holoToolText)
                            Text(habit.unitText.isEmpty ? String(localized: "输入数值") : String(localized: "单位：\(habit.unitText)"))
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoToolTextSecondary)
                        }
                    }
                    Spacer()
                    Button {
                        isInputFocused = false
                        editingHabit = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }

                // 输入框
                TextField("0", text: $inputValue)
                    .focused($isInputFocused)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .padding(.vertical, 16)
                    .background(Color.holoToolBackground)
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
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            .padding(.horizontal, 32)
        }
    }

    private func saveNumericRecord(_ habit: Habit) {
        guard let value = Double(inputValue) else { return }
        do {
            let firstOfToday = habitRepo.getTodayValue(for: habit) == nil
            _ = try habitRepo.addNumericRecord(for: habit, value: value)
            isInputFocused = false
            editingHabit = nil
            if firstOfToday && !habit.isBadHabit {
                HoloMotionFeedbackCenter.shared.completedHabit(habit.id)
            }
            HapticManager.light()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("记录数值失败: \(error.localizedDescription)")
        }
    }
}

#Preview {
    DailyKanbanView()
}
