//
//  DailyKanbanView.swift
//  Holo
//
//  「今天」主视图（今日看板 Matter 化方案 §4/§9）
//
//  新版（todayCommandCenterEnabled）：行动优先信息架构——
//  Header「今天」→ Primary Focus → Weekly Brief → 进行中的事 → 今天的安排 → 保持状态 → 今日概况。
//  旧版（flag 关闭）：完整保留原今日看板布局（回滚不删数据）。
//

import SwiftUI
import os.log

struct DailyKanbanView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var todoRepo = TodoRepository.shared
    @ObservedObject private var habitRepo = HabitRepository.shared
    @ObservedObject private var healthRepo = HealthRepository.shared
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
    @State private var showGoalCreate = false
    @State private var completedTaskPendingUndo: UUID? = nil
    @FocusState private var isInputFocused: Bool

    /// 键盘高度：数值输入弹窗是手写 overlay（非系统 sheet），系统键盘避让管不到，
    /// 这里手动监听键盘，把弹窗整体上移到键盘上方，避免输入框/保存按钮被挡。
    @State private var keyboardHeight: CGFloat = 0

    /// 当前窗口宽度（v2 断点：宽屏双栏）
    @Environment(\.holoWindowWidth) private var kanbanWindowWidth
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
                Color.holoBackground.ignoresSafeArea()

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
                    .padding(.horizontal, isExpandedWidth ? 32 : 16)
                    .padding(.top, 8)
                }
            }
            .background(navigationDestinations)
            .sheet(item: $dispatcher.scheduleDetailItem) { item in
                ScheduleDetailSheet(item: item)
            }
            .sheet(item: $dispatcher.taskDetailSelection) { taskID in
                // TaskDetailView 全 App 统一弹窗呈现（TasksView/KanbanTaskSection 同款）；
                // 不传 onBack，内部 dismiss 即关闭，sheet(item:) 自动置空 selection
                if let task = TodoRepository.shared.findTask(by: taskID) {
                    TaskDetailView(task: task, repository: TodoRepository.shared)
                }
            }
        }
        .swipeBackToDismiss { dismiss() }
        .task {
            await todayViewModel?.loadIfNeeded()
        }
        .onChange(of: dispatcher.path) { _, newValue in
            _ = newValue
        }
    }

    /// iPad 双栏（§4.3）：Header/Focus/Brief 跨双栏（外层）；左栏 Matter+概况，右栏安排+保持。
    @ViewBuilder
    private var todaySectionsWide: some View {
        if case .ready(let snapshot) = todayViewModel?.state {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 20) {
                    TodayMatterSection(
                        matters: snapshot.matters,
                        sectionState: snapshot.sectionStates[.matters],
                        onCard: { dispatcher.perform($0.cardAction) },
                        onStartNew: { onOpenAI?() },
                        onViewAll: { dispatcher.path.append(.matterList) },
                        onDiscuss: { openChat(matterID: $0.id) }
                    )
                    TodayOverviewSection(
                        overview: snapshot.overview,
                        sectionState: snapshot.sectionStates[.overview],
                        onOpenFinance: { onOpenFinance?() },
                        onAddRecord: { onQuickRecord?() }
                    )
                }
                VStack(alignment: .leading, spacing: 20) {
                    TodayAgendaSection(
                        items: snapshot.agenda,
                        sectionState: snapshot.sectionStates[.agenda],
                        maxVisible: 12,
                        onItem: { dispatcher.perform($0.action) },
                        onComplete: { completeTask($0) },
                        pendingUndoTaskID: completedTaskPendingUndo
                    )
                    TodayRoutineStrip(
                        routine: snapshot.routine,
                        onCheckIn: { checkInHabit($0) },
                        onConnectHealth: nil
                    )
                }
            }
        } else {
            TodayPrimaryFocusCard(focus: nil, isLoading: true, inFlightAction: nil, errorMessage: nil, onStart: { _ in }, onPostpone: {})
        }
    }

    /// 新版信息架构（固定阅读顺序 §4.2，iPhone 单列）。
    @ViewBuilder
    private var todaySections: some View {
        if case .ready(let snapshot) = todayViewModel?.state {
            // 1. Primary Focus
            TodayPrimaryFocusCard(
                focus: snapshot.primaryFocus,
                isLoading: false,
                inFlightAction: dispatcher.inFlightAction,
                errorMessage: dispatcher.localErrorMessage,
                onStart: { dispatcher.perform($0) },
                onPostpone: { todayViewModel?.postponeFocus() },
                onCalmQuickRecord: { onQuickRecord?() }
            )

            // 2. Weekly Brief（次级横幅，不压主行动）
            // （已在上方紧跟主卡之后渲染）

            // 3. 进行中的事
            TodayMatterSection(
                matters: snapshot.matters,
                sectionState: snapshot.sectionStates[.matters],
                onCard: { item in
                    dispatcher.perform(item.cardAction)
                },
                onStartNew: {
                    onOpenAI?()
                },
                onViewAll: {
                    dispatcher.path.append(.matterList)
                },
                onDiscuss: { item in
                    openChat(matterID: item.id)
                }
            )

            // 4. 今天的安排
            TodayAgendaSection(
                items: snapshot.agenda,
                sectionState: snapshot.sectionStates[.agenda],
                maxVisible: 12,
                onItem: { item in
                    dispatcher.perform(item.action)
                },
                onComplete: { item in
                    completeTask(item)
                },
                pendingUndoTaskID: completedTaskPendingUndo
            )

            // 5. 保持状态
            TodayRoutineStrip(
                routine: snapshot.routine,
                onCheckIn: { row in checkInHabit(row) },
                onConnectHealth: nil
            )

            // 6. 今日概况
            TodayOverviewSection(
                overview: snapshot.overview,
                sectionState: snapshot.sectionStates[.overview],
                onOpenFinance: { onOpenFinance?() },
                onAddRecord: { onQuickRecord?() }
            )
        } else {
            // loading：与最终卡等高的骨架
            TodayPrimaryFocusCard(focus: nil, isLoading: true, inFlightAction: nil, errorMessage: nil, onStart: { _ in }, onPostpone: {})
        }
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

    /// 完成任务（真实回执 + 3 秒撤回）。
    private func completeTask(_ item: HoloTodayAgendaItem) {
        guard case .openTask(let taskID) = item.action,
              let task = TodoRepository.shared.findTask(by: taskID) else { return }
        do {
            _ = try todoRepo.toggleTaskCompletion(task)
            completedTaskPendingUndo = taskID
            HapticManager.light()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak todoRepo] in
                if todoRepo?.pendingCompletionTaskId == nil {
                    completedTaskPendingUndo = nil
                }
            }
        } catch {
            Logger(subsystem: "com.holo.app", category: "Today").error("完成任务失败: \(error.localizedDescription)")
        }
    }

    /// 习惯快速打卡。
    private func checkInHabit(_ row: HoloTodayHabitRow) {
        let habit = habitRepo.activeHabits.first { $0.id == row.id }
        guard let habit else { return }
        if row.isNegative {
            _ = try? habitRepo.addNumericRecord(for: habit, value: 1)
        } else if habit.isMeasureType {
            if let target = habit.targetValue?.doubleValue {
                _ = try? habitRepo.addNumericRecord(for: habit, value: target)
            }
        } else {
            try? habitRepo.toggleCheckIn(for: habit)
        }
        HapticManager.light()
    }

    // MARK: - Header（今天 + 日期 + 关闭）

    private var headerView: some View {
        ZStack {
            Text(String(localized: "今天"))
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
                .accessibilityLabel(Text("关闭"))

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
        f.setLocalizedDateFormatFromTemplate("MMMdE")
        return f.string(from: Date())
    }

    /// NavigationStack 目的地（隐藏挂载）。
    private var navigationDestinations: some View {
        Group {}
            .navigationDestination(for: HoloTodayRoute.self) { route in
                routeDestination(route)
            }
    }

    // MARK: - 旧版看板（flag 关闭时完整保留）

    private var legacyBody: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

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
        .animation(.easeInOut(duration: 0.2), value: editingHabit != nil)
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
                            Text(habit.unitText.isEmpty ? String(localized: "输入数值") : String(localized: "单位：\(habit.unitText)"))
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