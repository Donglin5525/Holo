//
//  TaskDetailView.swift
//  Holo
//
//  任务页 —— 查看/编辑/新建合一
//  点按即编辑，返回自动保存（原型：task-module-redesign-prototype.html）
//  列表卡片、搜索、看板、DeepLink 共用本页；新建任务亦进入本页（空白态聚焦标题）
//

import SwiftUI
import CoreData
import PhotosUI
import AVFoundation
import OSLog

// MARK: - TaskDetailView

struct TaskDetailView: View {
    @ObservedObject var repository: TodoRepository
    let existingTask: TodoTask?
    /// 新建入口传入的默认截止日期；仅用于区分自动填充和用户主动编辑。
    let defaultDueDate: Date?
    var onBack: (() -> Void)? = nil

    @Environment(\.dismiss) var dismiss

    /// 完成协调层（G1 完成契约：完成改走统一撤回窗口，confirm 落库成功后再弹时长面板）
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared
    /// 详情页出现时刻：只对在场期间发生的 confirm 回执反应，不吃页面打开前的旧回执
    @State private var appearedAt: Date? = nil
    /// 已弹过时长面板的那次 confirm（防重复弹）
    @State private var durationPromptedAt: Date? = nil

    // ===== 内容 =====
    @State private var title = ""
    @State private var description = ""
    @State private var dueDate = Date()
    @State private var hasDueDate = false
    @State private var hasTime = false
    // 计划时间段（时间块）：与截止日期独立的编辑态，两 Date 始终合法成对
    @State private var hasPlannedRange = false
    @State private var plannedStart = Date()
    @State private var plannedEnd = Date()
    @State private var selectedReminders: Set<TaskReminder> = []
    @State private var selectedListId: UUID? = nil

    // ===== 弹层 =====
    @State private var showListPicker = false
    @State private var showGoalPicker = false
    @State private var showTimeSheet = false
    @State private var showPlannedRangeSheet = false
    /// 完成带时间段任务时的实际用时确认
    @State private var showActualDurationSheet = false
    @State private var showPostponeSheet = false
    @State private var showTaskVoiceInput = false
    @State private var pendingTaskVoiceTranscriptToInsert: String? = nil
    @State private var isSaving = false
    @State private var showSaveErrorAlert = false
    @State private var saveErrorMessage = ""

    // ===== 重复规则 =====
    @State private var hasRepeat = false
    @State private var repeatType: RepeatType = .daily
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthDay: Int = 1
    @State private var monthWeekOrdinal: Int = 1
    @State private var monthWeekday: Weekday? = nil
    @State private var monthlyRepeatMode: MonthlyRepeatMode = .dayOfMonth
    @State private var endConditionType: EndConditionType = .never
    @State private var repeatEndDate: Date? = nil
    @State private var repeatEndCount: Int = 10

    // ===== 未保存确认 / 任务删除 =====
    @State private var showDismissAlert: Bool = false
    @State private var showDeleteTaskAlert: Bool = false

    // ===== 子任务 =====
    @State private var checkItems: [CheckItem] = []
    @State private var pendingCheckItems: [PendingCheckItem] = []
    @State private var newCheckItemTitle = ""
    @State private var displayedChecklistProgress: Double = 0
    @State private var showChecklistCompletionCelebration = false
    @State private var checklistCompletionCelebrationID = UUID()

    // ===== 拆成几步 / 先等等（2026-10-11 拆开瘦身）=====
    @State private var showTaskSplitSheet = false
    @State private var waitingCheckItem: CheckItem?
    @State private var splitToastText: String?

    // ===== 语音拆解子任务 =====
    @State private var isSplittingTaskVoice = false
    @FocusState private var isTitleFocused: Bool

    // ===== 状态（编辑模式） =====
    @State private var taskStatus: TaskStatus = .todo

    // ===== 轻重缓急（2026-10-06 任务重构方案 §6.2）=====
    /// 详情草稿：打开分类子弹层选择先写这里，确定回详情；沿用详情现有保存时点
    @State private var classificationImportance: TaskImportance = .unknown
    @State private var classificationUrgencyMode: TaskUrgencyMode = .auto
    @State private var showClassificationSheet = false
    /// 移动到象限弹层（多视图方案 §6.3-10）
    @State private var showMoveToQuadrantSheet = false
    /// 新建模式从轻量弹层预填的两轴（保存时随 createTask 一次写入）
    var prefilledImportance: TaskImportance? = nil
    var prefilledUrgencyMode: TaskUrgencyMode? = nil

    // ===== 记忆 =====
    @AppStorage("lastSelectedListId") private var lastSelectedListId: String?
    @AppStorage("com.holo.thought.voice.smartSummary.enabled") private var smartSummaryEnabled: Bool = true

    // ===== 附件 =====
    @State private var pendingImages: [UIImage] = []
    @State private var showAttachmentGallery = false
    @State private var galleryStartIndex = 0
    @State private var showAttachmentCamera = false
    @State private var showAttachmentPhotoPicker = false
    @State private var selectedAttachmentPhotos: [PhotosPickerItem] = []
    @State private var attachmentsRevision = 0
    @State private var pendingCameraImageData: Data?

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    // MARK: - Init

    /// 编辑/查看模式：列表卡片、搜索、看板、DeepLink 进入
    init(task: TodoTask, repository: TodoRepository, onBack: (() -> Void)? = nil) {
        self.repository = repository
        self.existingTask = task
        self.defaultDueDate = nil
        self.onBack = onBack

        _title = State(initialValue: task.title)
        _description = State(initialValue: task.desc ?? "")
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _hasTime = State(initialValue: !task.isAllDay)
        _hasPlannedRange = State(initialValue: task.hasPlannedTimeRange)
        if let plannedStart = task.plannedStart {
            _plannedStart = State(initialValue: plannedStart)
            _plannedEnd = State(initialValue: task.plannedEnd ?? plannedStart.addingTimeInterval(3600))
        }
        _selectedReminders = State(initialValue: task.remindersSet)
        _selectedListId = State(initialValue: task.list?.id)

        if let rule = task.repeatRule {
            _hasRepeat = State(initialValue: true)
            _repeatType = State(initialValue: rule.repeatType)
            _selectedWeekdays = State(initialValue: Set(rule.weekdaysArray))
            _monthDay = State(initialValue: Int(rule.monthDay))
            _monthWeekOrdinal = State(initialValue: Int(rule.monthWeekOrdinal))
            _monthWeekday = State(initialValue: rule.monthWeekdayValue)
            _monthlyRepeatMode = State(initialValue: rule.monthWeekOrdinal > 0 ? .nthWeekday : .dayOfMonth)
            _endConditionType = State(initialValue: rule.endConditionType)
            _repeatEndDate = State(initialValue: rule.untilDate)
            _repeatEndCount = State(initialValue: Int(rule.untilCount))
        } else {
            _hasRepeat = State(initialValue: false)
        }

        _taskStatus = State(initialValue: task.taskStatus)
        _classificationImportance = State(initialValue: task.importance)
        _classificationUrgencyMode = State(initialValue: task.urgencyMode)
    }

    /// 新建模式：底部「＋」、首页深链、看板、日程转任务进入
    init(
        repository: TodoRepository,
        list: TodoList? = nil,
        defaultDueDate: Date? = nil,
        prefilledTitle: String? = nil,
        prefilledDescription: String? = nil,
        prefilledPlannedRange: (start: Date, end: Date)? = nil,
        prefilledImportance: TaskImportance? = nil,
        prefilledUrgencyMode: TaskUrgencyMode? = nil,
        prefilledDueIsAllDay: Bool? = nil
    ) {
        self.repository = repository
        self.existingTask = nil
        self.defaultDueDate = defaultDueDate
        self.onBack = nil
        self.prefilledImportance = prefilledImportance
        self.prefilledUrgencyMode = prefilledUrgencyMode

        let rememberedId = list?.id ?? (UserDefaults.standard.string(forKey: "lastSelectedListId").flatMap { UUID(uuidString: $0) })
        _selectedListId = State(initialValue: rememberedId)
        _dueDate = State(initialValue: defaultDueDate ?? Date())
        _hasDueDate = State(initialValue: defaultDueDate != nil)
        _hasTime = State(initialValue: prefilledDueIsAllDay.map { !$0 } ?? false)
        // 轻重缓急草稿：预填即初始（来自象限的上下文可见、可调整）
        _classificationImportance = State(initialValue: prefilledImportance ?? .unknown)
        _classificationUrgencyMode = State(initialValue: prefilledUrgencyMode ?? .auto)
        // 日程转任务等场景的预填
        if let prefilledTitle, !prefilledTitle.isEmpty {
            _title = State(initialValue: prefilledTitle)
        }
        if let prefilledDescription {
            _description = State(initialValue: prefilledDescription)
        }
        if let range = prefilledPlannedRange {
            _hasPlannedRange = State(initialValue: true)
            _plannedStart = State(initialValue: range.start)
            _plannedEnd = State(initialValue: range.end)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    headerSection

                    ScrollView {
                        VStack(spacing: HoloSpacing.lg) {
                            TaskDetailTitleSection(
                                existingTask: existingTask,
                                title: $title,
                                description: $description,
                                showTaskVoiceInput: $showTaskVoiceInput,
                                smartSummaryEnabled: $smartSummaryEnabled,
                                isSplittingTaskVoice: isSplittingTaskVoice,
                                isCompletionPending: isCompletionPending,
                                repeatType: repeatType,
                                isTitleFocused: $isTitleFocused,
                                toggleCompletion: { toggleCompletion() }
                            )

                            // 来源想法紧跟标题：想法转来的任务标题常被改写，
                            // 原话是高频查看项，不能压在属性设置之后
                            if let thought = existingTask?.sourceThought {
                                sourceThoughtSection(thought)
                            }

                            TaskDetailChecklistSection(
                                repository: repository,
                                existingTask: existingTask,
                                checkItems: $checkItems,
                                pendingCheckItems: $pendingCheckItems,
                                displayedChecklistProgress: $displayedChecklistProgress,
                                showSaveErrorAlert: $showSaveErrorAlert,
                                showTaskSplitSheet: $showTaskSplitSheet,
                                waitingCheckItem: $waitingCheckItem,
                                newCheckItemTitle: $newCheckItemTitle,
                                showChecklistCompletionCelebration: $showChecklistCompletionCelebration,
                                checklistCompletionCelebrationID: $checklistCompletionCelebrationID,
                                addCheckItem: addCheckItem,
                                resumeWaiting: resumeWaiting,
                                toggleCompletion: toggleCompletion,
                                checklistProgress: { checklistProgress },
                                applyChecklistProgressChange: applyChecklistProgressChange
                            )

                            TaskDetailAttachmentSection(
                                repository: repository,
                                existingTask: existingTask,
                                pendingImages: $pendingImages,
                                showAttachmentGallery: $showAttachmentGallery,
                                galleryStartIndex: $galleryStartIndex,
                                showAttachmentCamera: $showAttachmentCamera,
                                showAttachmentPhotoPicker: $showAttachmentPhotoPicker,
                                attachmentsRevision: $attachmentsRevision
                            )

                            TaskDetailPropertiesSection(
                                existingTask: existingTask,
                                selectedListName: selectedListName,
                                taskStatus: $taskStatus,
                                showTimeSheet: $showTimeSheet,
                                showPostponeSheet: $showPostponeSheet,
                                showPlannedRangeSheet: $showPlannedRangeSheet,
                                showListPicker: $showListPicker,
                                showClassificationSheet: $showClassificationSheet,
                                showMoveToQuadrantSheet: $showMoveToQuadrantSheet,
                                showGoalPicker: $showGoalPicker,
                                dueDate: $dueDate,
                                hasDueDate: $hasDueDate,
                                hasTime: $hasTime,
                                hasRepeat: $hasRepeat,
                                repeatType: $repeatType,
                                selectedReminders: $selectedReminders,
                                hasPlannedRange: $hasPlannedRange,
                                plannedStart: $plannedStart,
                                plannedEnd: $plannedEnd,
                                classificationImportance: $classificationImportance,
                                classificationUrgencyMode: $classificationUrgencyMode
                            )

                            autosaveHint
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)
                        .padding(.bottom, 60)
                    }
                    .overlay(alignment: .bottom) {
                        // 拆解落库轻回执：拆好了，加了 N 步
                        if let splitToastText {
                            Text(splitToastText)
                                .font(.holoCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.black.opacity(0.75)))
                                .padding(.bottom, 12)
                                .transition(.opacity)
                                .accessibilityIdentifier("taskSplitToast")
                        }
                    }
                    .onChange(of: splitToastText) { _, newValue in
                        guard newValue != nil else { return }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if splitToastText == newValue { splitToastText = nil }
                        }
                    }
                }
            }
            .navigationTitle("")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navLeading) {
                    Button {
                        handleBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                            .frame(width: 20, height: 44)
                    }
                    .disabled(isSaving)
                }

                // 破坏性操作收进「⋯」菜单，不常驻编辑视图
                ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                    if existingTask != nil {
                        Menu {
                            Button(role: .destructive) {
                                showDeleteTaskAlert = true
                            } label: {
                                Label("删除任务", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.holoTextPrimary)
                                .frame(width: 32, height: 44)
                        }
                    }
                }
            }
        }
        // 撤回窗口 banner（与任务列表同一样式；confirm 落库前可撤回）。
        // 只展示本页发起的完成：pending 是跨页共享的单一状态，
        // 不按 source 过滤会同一次完成在详情/列表各弹一条。
        .overlay(alignment: .bottom) {
            completionUndoBanner
                .animation(HoloAnimation.snappy, value: showsUndoBanner)
        }
        .onAppear {
            appearedAt = Date()
        }
        // confirm 落库成功回执：命中当前详情任务且带计划时间段、未记录过时长 → 弹「实际用了多久」
        .onReceive(completionCoordinator.$lastConfirmed) { confirmed in
            guard let confirmed, let task = existingTask else { return }
            // 只对详情页在场期间发生的确认反应（@Published 订阅会先发当前值，不吃页面打开前的旧回执）
            guard let appearedAt, confirmed.confirmedAt >= appearedAt else { return }
            guard confirmed.taskID == task.id else { return }
            guard durationPromptedAt != confirmed.confirmedAt else { return }
            durationPromptedAt = confirmed.confirmedAt
            if task.hasPlannedTimeRange, task.actualDurationMinutes == nil {
                showActualDurationSheet = true
            }
        }
        .sheet(isPresented: $showListPicker) {
            TaskDetailListPickerSheet(
                repository: repository,
                selectedListId: $selectedListId,
                showListPicker: $showListPicker,
                onDeleteTarget: deleteTarget
            )
        }
        .sheet(isPresented: $showGoalPicker) {
            GoalPickerSheet(currentGoalId: existingTask?.goal?.id) { goal in
                applyGoalSelection(goal)
            }
        }
        .sheet(isPresented: $showTimeSheet) {
            dateTimeSheet
        }
        .sheet(isPresented: $showPlannedRangeSheet) {
            PlannedTimeRangeSheet(
                hasPlannedRange: $hasPlannedRange,
                plannedStart: $plannedStart,
                plannedEnd: $plannedEnd,
                defaultDay: hasDueDate ? dueDate : nil
            )
        }
        .sheet(isPresented: $showMoveToQuadrantSheet) {
            // 移动到象限（多视图 §6.3-10）：提交走统一动作协调器；
            // 关闭时重读两轴同步本页草稿显示
            if let task = existingTask {
                TaskQuadrantMoveSheet(
                    snapshot: TaskRecordSnapshot.make(from: task),
                    repository: repository,
                    now: Date(),
                    calendar: TaskAnalyticsPeriod.makeCalendar(),
                    onDone: { syncClassificationDraftFromTask() }
                )
            }
        }
        .sheet(isPresented: $showActualDurationSheet) {
            if let task = existingTask {
                ActualDurationSheet(task: task, repository: repository)
            }
        }
        .sheet(isPresented: $showPostponeSheet) {
            // 面板入参用编辑态而非库值：时间弹窗里改过日期（未保存）也要立即反映
            if let task = existingTask {
                TaskPostponeSheet(
                    title: title.isEmpty ? task.title : title,
                    dueDate: hasDueDate ? dueDate : nil,
                    isAllDay: !hasTime,
                    isOverdue: TodoTaskDatePolicy.isOverdue(
                        dueDate: hasDueDate ? dueDate : nil,
                        isAllDay: !hasTime,
                        completed: task.completed
                    ),
                    onPostpone: applyDetailPostpone
                )
            }
        }
        .sheet(isPresented: $showClassificationSheet) {
            // 分类子弹层：选择先写详情草稿，确定回详情；沿用详情现有保存时点（§6.2）
            TaskClassificationSheet(
                initialImportance: classificationImportance,
                initialUrgencyMode: classificationUrgencyMode,
                contextEffectiveDue: TodoTaskDatePolicy.effectiveDueDate(
                    dueDate: hasDueDate ? dueDate : nil,
                    isAllDay: !hasTime
                )
            ) { importance, urgencyMode in
                classificationImportance = importance
                classificationUrgencyMode = urgencyMode
            }
        }
        .sheet(isPresented: $showTaskSplitSheet) {
            // 拆成几步（唯一一次 AI 调用）：确认页落库为子任务
            if let task = existingTask {
                TaskSplitSheet(task: task) { drafts in
                    applySplitDrafts(drafts)
                }
            }
        }
        .sheet(item: $waitingCheckItem) { item in
            // 先等等：自由输入 + 本地 AI 候选 + 明天 9:00 提醒
            CheckItemWaitSheet(item: item) { note, remindAt in
                applyWaiting(note: note, remindAt: remindAt)
            }
        }
        .sheet(isPresented: $showTaskVoiceInput, onDismiss: insertPendingTaskVoiceTranscript) {
            if smartSummaryEnabled {
                VoiceInputSheet(
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .task),
                    readySubtitle: String(localized: "确认后插入到任务描述"),
                    submitButtonTitle: String(localized: "插入"),
                    resultConfig: VoiceResultConfig(
                        title: String(localized: "智能总结完成"),
                        subtitle: String(localized: "已整理成更适合任务描述的表达"),
                        showsOriginalToggle: true
                    ),
                    postProcessor: ThoughtVoiceSummaryProcessor(),
                    transcriptFormatter: formatTaskVoiceTranscript
                ) { transcript in
                    pendingTaskVoiceTranscriptToInsert = transcript
                    showTaskVoiceInput = false
                }
            } else {
                VoiceInputSheet(
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .task),
                    readySubtitle: String(localized: "确认后插入到任务描述"),
                    submitButtonTitle: String(localized: "插入"),
                    transcriptFormatter: formatTaskVoiceTranscript
                ) { transcript in
                    pendingTaskVoiceTranscriptToInsert = transcript
                    showTaskVoiceInput = false
                }
            }
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showAttachmentGallery) {
            if let task = existingTask {
                AttachmentGalleryView(
                    attachments: task.sortedAttachments,
                    startIndex: galleryStartIndex,
                    taskId: task.id
                )
            }
        }
        #else
                .sheet(isPresented: $showAttachmentGallery) {
            if let task = existingTask {
                AttachmentGalleryView(
                    attachments: task.sortedAttachments,
                    startIndex: galleryStartIndex,
                    taskId: task.id
                )
            }
        }
        #endif
        .photosPicker(
            isPresented: $showAttachmentPhotoPicker,
            selection: $selectedAttachmentPhotos,
            maxSelectionCount: existingTask != nil ? max(0, 9 - (existingTask?.sortedAttachments.count ?? 0)) : max(0, 9 - pendingImages.count),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selectedAttachmentPhotos) { _, newItems in
            loadAttachmentPhotos(newItems)
        }
        #if canImport(UIKit)
        .fullScreenCover(
            isPresented: $showAttachmentCamera,
            onDismiss: {
                guard let data = pendingCameraImageData else { return }
                pendingCameraImageData = nil
                handleCapturedImageData(data)
            }
        ) {
            CameraView(onCapture: { imageData in
                pendingCameraImageData = imageData
                showAttachmentCamera = false
            }, onDismiss: {
                showAttachmentCamera = false
            })
        }
        #else
                .sheet(
            isPresented: $showAttachmentCamera,
            onDismiss: {
                guard let data = pendingCameraImageData else { return }
                pendingCameraImageData = nil
                handleCapturedImageData(data)
            }
        ) {
            CameraView(onCapture: { imageData in
                pendingCameraImageData = imageData
                showAttachmentCamera = false
            }, onDismiss: {
                showAttachmentCamera = false
            })
        }
        #endif
        // ignoreNavigationStack: true —— 本页是 NavigationStack 根视图，
        // 系统 pop 无内容可 pop；不传则 SwipeBackModifier 会因窗口内任意 push
        // 的 NavigationStack 而让位，导致右滑失效（与 HealthDetailView 一致）。
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            handleBack()
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert, message: String(localized: "还没填任务名称，退出后这次填写的内容不会被保存。")) {
            dismiss()
        }
        // 拦截系统 Sheet 下滑关闭，统一走 handleBack 的保存/确认分流；
        // 下拉被拦的瞬间由 sheetDismissGuard 回调 handleBack，
        // 三条关闭路径（返回按钮 / 右滑 / 下拉）行为完全一致
        .interactiveDismissDisabled()
        .sheetDismissGuard { handleBack() }
        .alert("删除任务", isPresented: $showDeleteTaskAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteTask()
            }
        } message: {
            // 单条删除已建批次进回收站（2026-09-06 拍板），30 天内可在最近删除自助恢复
            Text(String(localized: "删除后将进入回收站并保留 30 天，可在「设置 → 数据管理 → 最近删除」中恢复。"))
        }
        .alert("保存失败", isPresented: $showSaveErrorAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
        .onAppear {
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }
                displayedChecklistProgress = checklistProgress
            } else {
                // 新建：自动聚焦标题
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isTitleFocused = true
                }
            }
        }
    }

    // MARK: - 顶部标题

    private var headerSection: some View {
        HStack {
            Spacer()
            Text("任务")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
    }

    // MARK: - 未保存修改 / 可保存

    private var hasUnsavedChanges: Bool {
        if let task = existingTask {
            return title != task.title
                || description != (task.desc ?? "")
                || selectedListId != task.list?.id
                || checkItems.count != (task.checkItems?.count ?? 0)
                // 轻重缓急草稿纳入变更判断（§6.2）
                || classificationImportance != task.importance
                || classificationUrgencyMode != task.urgencyMode
        } else {
            return !title.trimmingCharacters(in: .whitespaces).isEmpty
                || !description.isEmpty
                || hasCustomizedDefaultDueDate
                || hasRepeat
                || hasPlannedRange
                || !pendingCheckItems.isEmpty
                // 分类草稿离开预填初始值才算用户编辑（预填不算，§5.4）
                || classificationImportance != (prefilledImportance ?? .unknown)
                || classificationUrgencyMode != (prefilledUrgencyMode ?? .auto)
        }
    }

    /// 自动填充的今天日期本身不应让空白新建页弹出“未保存”确认。
    private var hasCustomizedDefaultDueDate: Bool {
        guard hasDueDate else { return false }
        guard let defaultDueDate else { return true }
        return !Calendar.current.isDate(dueDate, inSameDayAs: defaultDueDate)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var checklistProgress: Double {
        guard !checkItems.isEmpty else { return 0 }
        let completedCount = checkItems.filter(\.isChecked).count
        return Double(completedCount) / Double(checkItems.count)
    }

    // MARK: - 标题区语音转录

    private func formatTaskVoiceTranscript(_ transcript: String) -> String {
        ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: transcript,
            currentContent: description,
            selectedRange: NSRange(location: description.count, length: 0)
        )
    }

    private func insertPendingTaskVoiceTranscript() {
        guard let transcript = pendingTaskVoiceTranscriptToInsert else { return }
        pendingTaskVoiceTranscriptToInsert = nil

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        splitTaskVoiceTranscript(trimmed)
    }

    /// 语音拆解：成功且拆出子任务时填入标题与子任务列表；
    /// 拆不出、或调用失败时退回「塞进描述」。
    private func splitTaskVoiceTranscript(_ text: String) {
        isSplittingTaskVoice = true
        Task { @MainActor in
            let splitter = TaskTextSplitter()
            do {
                let result = try await splitter.split(text)

                if !result.subtasks.isEmpty {
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = result.title
                    }
                    for subtask in result.subtasks {
                        addSubtaskTitle(subtask)
                    }
                    HoloToastCenter.shared.show(String(localized: "已为你拆成 \(result.subtasks.count) 个子任务，可调整"), type: .success)
                } else {
                    appendTextToDescription(text)
                }
            } catch {
                Self.logger.warning("语音拆解子任务失败，退回塞入描述：\(error.localizedDescription)")
                appendTextToDescription(text)
            }
            isSplittingTaskVoice = false
        }
    }

    private func appendTextToDescription(_ text: String) {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            description = text
        } else if description.hasSuffix("\n\n") {
            description += text
        } else if description.hasSuffix("\n") {
            description += "\n" + text
        } else {
            description += "\n\n" + text
        }
    }

    /// 直接按标题添加一条子任务（语音拆解批量写入用）。
    private func addSubtaskTitle(_ rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let task = existingTask {
            do {
                let progressBeforeChange = checklistProgress
                let order = Int16(checkItems.count)
                let item = try repository.addCheckItem(title: trimmed, to: task, order: order)
                displayedChecklistProgress = progressBeforeChange
                checkItems.append(item)
                applyChecklistProgressChange(from: progressBeforeChange, to: checklistProgress)
            } catch {
                Self.logger.error("语音拆解写入子任务失败：\(error.localizedDescription)")
            }
        } else {
            pendingCheckItems.append(PendingCheckItem(title: trimmed))
        }
    }

    // MARK: - 完成切换（编辑模式）

    /// 当前详情任务是否处于完成撤回窗口内
    private var isCompletionPending: Bool {
        guard let task = existingTask else { return false }
        return completionCoordinator.pending?.taskID == task.id
    }

    /// 撤回横条只在完成由本页发起时展示；跨页来源的完成由发起页自己出横条
    private var showsUndoBanner: Bool {
        isCompletionPending && completionCoordinator.pending?.source == .taskDetail
    }

    /// - Parameter trigger: 由「子任务全勾」联动触发时带出触发子任务快照，撤回时恢复其原勾选状态
    private func toggleCompletion(trigger: (checkItemID: UUID, wasChecked: Bool)? = nil) {
        guard let task = existingTask else { return }
        if task.completed {
            // 已完成 → 取消完成（立即落库，无撤回语义）
            do {
                let isCompleted = try repository.toggleTaskCompletion(task)
                if !isCompleted {
                    taskStatus = .todo
                }
                HapticManager.taskCompletion()
            } catch {
                Self.logger.error("切换完成状态失败: \(error.localizedDescription)")
            }
        } else if isCompletionPending {
            // 撤回窗口内再点完成圈 → 撤回（与列表/看板一致）
            completionCoordinator.undo(in: repository)
            HapticManager.light()
        } else {
            // 未完成 → 走统一撤回窗口；confirm 落库成功后由 lastConfirmed 订阅弹时长面板
            completionCoordinator.requestCompletion(
                taskID: task.id,
                source: .taskDetail,
                trigger: trigger,
                in: repository
            )
            HapticManager.taskCompletion()
        }
    }

    /// 撤回窗口 banner：使用 Holo 统一操作回执。
    @ViewBuilder
    private var completionUndoBanner: some View {
        if showsUndoBanner {
            if HoloTaskMotionRolloutPolicy.isEnabled {
                HoloUndoToast(
                    message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                    onUndo: {
                        completionCoordinator.undo(in: repository)
                        HapticManager.light()
                    }
                )
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoSuccess)
                        Text("任务已完成")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                    }

                    Spacer()

                    Button {
                        completionCoordinator.undo(in: repository)
                        HapticManager.light()
                    } label: {
                        Text("撤回")
                            .font(.holoBody)
                            .foregroundColor(.holoPrimary)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func addCheckItem() {
        let trimmed = newCheckItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let task = existingTask {
            do {
                let progressBeforeChange = checklistProgress
                let order = Int16(checkItems.count)
                let item = try repository.addCheckItem(title: trimmed, to: task, order: order)
                displayedChecklistProgress = progressBeforeChange
                checkItems.append(item)
                applyChecklistProgressChange(from: progressBeforeChange, to: checklistProgress)
            } catch {
                Self.logger.error("添加子任务失败：\(error.localizedDescription)")
                saveErrorMessage = String(localized: "这一步未保存，内容已保留，请重试。")
                showSaveErrorAlert = true
                return
            }
        } else {
            pendingCheckItems.append(PendingCheckItem(title: trimmed))
        }
        newCheckItemTitle = ""
    }

    // MARK: 拆成几步 / 先等等（2026-10-11 拆开瘦身）

    /// 确认页「行，按这个来」：批量落库并出轻回执
    private func applySplitDrafts(_ drafts: [TaskSplitStepDraft]) {
        guard let task = existingTask else { return }
        do {
            let progressBeforeChange = checklistProgress
            let items = try repository.addSplitSteps(drafts, to: task)
            checkItems = ((task.checkItems?.allObjects as? [CheckItem]) ?? []).sorted { $0.order < $1.order }
            applyChecklistProgressChange(from: progressBeforeChange, to: checklistProgress)
            if !items.isEmpty {
                splitToastText = String(localized: "拆好了，加了 \(items.count) 步")
                HapticManager.light()
            }
        } catch {
            Self.logger.error("拆解落库失败：\(error.localizedDescription)")
        }
    }

    /// 「先放着，等我回来」：写等待态与明天提醒
    private func applyWaiting(note: String, remindAt: Date?) {
        guard let item = waitingCheckItem else { return }
        do {
            try repository.setCheckItemWaiting(item, note: note, remindAt: remindAt)
            refreshCheckItems()
        } catch {
            Self.logger.error("标记等待失败：\(error.localizedDescription)")
        }
    }

    /// 「等到了，接着做」：清等待标记与提醒
    private func resumeWaiting(_ item: CheckItem) {
        do {
            try repository.resumeCheckItem(item)
            refreshCheckItems()
        } catch {
            Self.logger.error("恢复推进失败：\(error.localizedDescription)")
        }
    }

    private func refreshCheckItems() {
        guard let task = existingTask else { return }
        checkItems = ((task.checkItems?.allObjects as? [CheckItem]) ?? []).sorted { $0.order < $1.order }
    }

    private func applyChecklistProgressChange(from previousProgress: Double? = nil, to nextProgress: Double) {
        let startProgress = min(max(previousProgress ?? displayedChecklistProgress, 0), 1)
        let targetProgress = min(max(nextProgress, 0), 1)
        let wasComplete = startProgress >= 1.0

        displayedChecklistProgress = startProgress

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.easeInOut(duration: 0.62)) {
                displayedChecklistProgress = targetProgress
            }
        }

        if !wasComplete && targetProgress >= 1.0 {
            triggerChecklistCompletionCelebration(after: 0.6)
        } else if targetProgress < 1.0 {
            showChecklistCompletionCelebration = false
        }
    }

    private func triggerChecklistCompletionCelebration(after delay: Double) {
        showChecklistCompletionCelebration = false
        checklistCompletionCelebrationID = UUID()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            showChecklistCompletionCelebration = true
        }
    }

    private func handleCapturedImageData(_ data: Data) {
        if let task = existingTask {
            Task {
                do {
                    try await repository.addAttachment(imageData: data, to: task, sourceType: "camera")
                    attachmentsRevision += 1
                } catch {
                    Self.logger.error("添加附件失败：\(error.localizedDescription)")
                }
            }
        } else {
            guard let image = UIImage(data: data) else { return }
            Task {
                if let previewImage = await AttachmentFileManager.previewImageInBackground(image) {
                    pendingImages.append(previewImage)
                }
            }
        }
    }

    private func loadAttachmentPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            selectedAttachmentPhotos = []
            var failedCount = 0
            var permissionRequired = false
            var limitedAccess = false
            var cloudFailed = false

            if let task = existingTask {
                for item in items {
                    let outcome = await PhotoLibraryImageLoader.loadImageData(from: item)
                    guard case .data(let data) = outcome else {
                        failedCount += 1
                        if case .permissionRequired = outcome { permissionRequired = true }
                        if case .limitedAccess = outcome { limitedAccess = true }
                        if case .cloudDownloadFailed = outcome { cloudFailed = true }
                        continue
                    }
                    do {
                        try await repository.addAttachment(imageData: data, to: task)
                    } catch {
                        Self.logger.error("添加附件失败：\(error.localizedDescription)")
                        failedCount += 1
                    }
                }
                attachmentsRevision += 1
            } else {
                var images: [UIImage] = []
                for item in items {
                    let outcome = await PhotoLibraryImageLoader.loadImageData(from: item)
                    if case .data(let data) = outcome, let image = UIImage(data: data) {
                        images.append(image)
                    } else {
                        failedCount += 1
                        if case .permissionRequired = outcome { permissionRequired = true }
                        if case .limitedAccess = outcome { limitedAccess = true }
                        if case .cloudDownloadFailed = outcome { cloudFailed = true }
                    }
                }
                guard !images.isEmpty || failedCount > 0 else { return }
                pendingImages.append(contentsOf: images)
            }
            await PhotoLibraryImageLoader.announceLoadFailure(failedCount: failedCount, totalCount: items.count, permissionRequired: permissionRequired, limitedAccess: limitedAccess, cloudFailed: cloudFailed)
        }
    }

    /// 象限移动提交后重读两轴，同步本页草稿与摘要显示
    private func syncClassificationDraftFromTask() {
        guard let task = existingTask else { return }
        classificationImportance = task.importance
        classificationUrgencyMode = task.urgencyMode
    }

    /// 详情页延期：立即落库 + 同步编辑态（防止随后的「保存」用旧日期把延期覆盖回去）
    private func applyDetailPostpone(_ option: TaskPostponeOption) {
        guard let task = existingTask else { return }
        do {
            try repository.postpone(task: task, to: option)
            if let target = option.targetDate {
                dueDate = target
                hasDueDate = true
                hasTime = !option.isAllDay
            }
            HapticManager.medium()
        } catch {
            Logger(subsystem: "com.holo.app", category: "TaskDetailView").error("延期失败: \(error.localizedDescription)")
        }
    }

    private func applyGoalSelection(_ goal: Goal?) {
        guard let task = existingTask else { return }
        do {
            if let goal {
                try GoalRepository.shared.linkTask(task, to: goal)
            } else if let current = task.goal {
                try GoalRepository.shared.unlinkTask(task, from: current)
            }
            GoalNotificationService.broadcastGoalDataChange()
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveErrorAlert = true
        }
    }

    // MARK: - 来源想法（只读追溯）

    @ViewBuilder
    private func sourceThoughtSection(_ thought: Thought) -> some View {
        VStack(spacing: 8) {
            Button {
                let thoughtId = thought.id
                HapticManager.selection()
                dismiss()
                // 先关闭任务详情，再交给 HomeView 切到想法模块并打开这条想法。
                DispatchQueue.main.async {
                    DeepLinkState.shared.navigate(to: .thoughtDetail(thoughtId: thoughtId))
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("来自想法")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                        Text(thought.firstLine ?? String(thought.content.prefix(30)))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .buttonStyle(.plain)

            // 选中文字转任务时保留的原文选区（任务标题后来改过时仍可追溯来源句）
            if let snippet = existingTask?.sourceTextSnippet, !snippet.isEmpty {
                Text("原文：\(snippet)")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var autosaveHint: some View {
        Text("返回时自动保存 · 无需点「保存」按钮")
            .font(.holoTinyLabel)
            .foregroundColor(.holoTextSecondary.opacity(0.7))
            .frame(maxWidth: .infinity)
    }

    // MARK: - 清单查找

    private func findList(byId listId: UUID) -> TodoList? {
        if let list = repository.unfiledLists.first(where: { $0.id == listId }) {
            return list
        }
        for folder in repository.folders {
            if let list = folder.listsArray.first(where: { $0.id == listId }) {
                return list
            }
        }
        return nil
    }

    private var selectedListName: String {
        guard let listId = selectedListId else {
            return String(localized: "收件箱（未归类）")
        }
        return findList(byId: listId)?.name ?? String(localized: "收件箱（未归类）")
    }

    private var selectedList: TodoList? {
        guard let listId = selectedListId else { return nil }
        return findList(byId: listId)
    }

    // MARK: - 删除清单

    private func deleteTarget(_ target: DeleteTarget) {
        do {
            switch target {
            case .list(let list):
                if selectedListId == list.id {
                    selectedListId = nil
                }
                // 清单删除会级联删除其下任务：正在编辑的任务若属于该清单，
                // 删除后须立即关闭表单，避免 body 继续读取已失效的任务对象
                let editingTaskBelongsToList = existingTask?.list?.id == list.id
                try repository.deleteList(list)
                if editingTaskBelongsToList {
                    dismiss()
                }
            }
        } catch {
            Self.logger.error("删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 删除任务

    private func deleteTask() {
        guard let task = existingTask else { return }
        do {
            try repository.deleteTask(task)
            HapticManager.medium()
            if let onBack = onBack {
                onBack()
            } else {
                dismiss()
            }
        } catch {
            Self.logger.error("删除任务失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 返回分流（保存 / 确认 / 直接关闭）

    /// 唯一的返回入口：编辑模式自动保存；新建模式有标题创建、
    /// 填过内容无标题弹确认、完全空白直接关闭
    private func handleBack() {
        guard !isSaving else { return }

        if existingTask != nil {
            saveAndDismiss()
        } else if canSave {
            saveAndDismiss()
        } else if hasUnsavedChanges {
            showDismissAlert = true
        } else {
            dismiss()
        }
    }

    // MARK: - 保存（返回时执行）

    private func saveAndDismiss() {
        isSaving = true

        // 保存前把子任务输入框里未提交的内容收进来：点返回不一定先经过
        // 失焦回调（onChange(focused) 与保存存在竞态），只靠失焦兜底会丢字；
        // addCheckItem 对空输入幂等，与失焦路径双跑也只入列一次
        addCheckItem()

        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        // 无截止日时只保留绝对提醒（相对提醒依赖截止日，无意义）。
        // 空集也要照常写入：reminders 传 nil 是「不修改」，清空必须靠写空集。
        let remindersToSave: Set<TaskReminder> = hasDueDate
            ? selectedReminders
            : selectedReminders.filter { $0.isAbsolute }
        let shouldCreateRepeat = hasRepeat && hasDueDate

        Task { @MainActor in
            do {
                if let task = existingTask {
                    // 标题被清空时不写空标题：回退原标题，其余改动照常保存
                    let finalTitle = trimmedTitle.isEmpty ? task.title : trimmedTitle

                    try repository.updateTask(
                        task,
                        title: finalTitle,
                        description: description,
                        status: taskStatus,
                        importance: classificationImportance,
                        urgencyMode: classificationUrgencyMode,
                        dueDate: hasDueDate ? .set(dueDate) : .clear,
                        isAllDay: !hasTime,
                        // 收件箱是显式保存意图：nil 会被「不修改」语义吞掉，任务永远留在原清单
                        list: selectedList.map { TodoRepository.TaskListUpdate.set($0) } ?? .clear,
                        reminders: remindersToSave,
                        plannedTime: hasPlannedRange ? .set(start: plannedStart, end: plannedEnd) : .clear
                    )

                    try applyRepeatRule(to: task, shouldCreate: shouldCreateRepeat)
                } else {
                    let newTask = try repository.createTask(
                        title: trimmedTitle,
                        description: description.isEmpty ? nil : description,
                        list: selectedList,
                        importance: classificationImportance,
                        urgencyMode: classificationUrgencyMode,
                        dueDate: hasDueDate ? dueDate : nil,
                        isAllDay: !hasTime,
                        reminders: remindersToSave,
                        plannedStart: hasPlannedRange ? plannedStart : nil,
                        plannedEnd: hasPlannedRange ? plannedEnd : nil
                    )

                    // 记忆本次选择的清单，下次创建任务时默认使用
                    lastSelectedListId = selectedListId?.uuidString

                    for (index, item) in pendingCheckItems.enumerated() {
                        _ = try repository.addCheckItem(title: item.title, to: newTask, order: Int16(index))
                    }

                    for image in pendingImages {
                        try await repository.addAttachment(image: image, to: newTask)
                    }

                    try applyRepeatRule(to: newTask, shouldCreate: shouldCreateRepeat)
                }

                HapticManager.success()
                await MainActor.run {
                    dismiss()
                }
            } catch {
                Self.logger.error("保存任务失败: \(error.localizedDescription)")
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = String(localized: "保存失败：\(error.localizedDescription)")
                    showSaveErrorAlert = true
                }
            }
        }
    }

    /// 重复规则的创建/更新/删除（新建与编辑共用）
    private func applyRepeatRule(to task: TodoTask, shouldCreate: Bool) throws {
        if shouldCreate {
            if let existingRule = task.repeatRule {
                try repository.deleteRepeatRule(existingRule)
            }
            _ = try repository.createRepeatRule(
                type: repeatType,
                for: task,
                weekdays: repeatType == .custom ? Array(selectedWeekdays) : nil,
                untilDate: endConditionType == .onDate ? repeatEndDate : nil
            )

            if repeatType == .monthly {
                if let rule = task.repeatRule {
                    try repository.updateRepeatRuleMonthlyParams(
                        rule,
                        monthDay: monthlyRepeatMode == .dayOfMonth ? monthDay : nil,
                        monthWeekOrdinal: monthlyRepeatMode == .nthWeekday ? monthWeekOrdinal : nil,
                        monthWeekday: monthlyRepeatMode == .nthWeekday ? monthWeekday : nil,
                        untilCount: endConditionType == .afterCount ? repeatEndCount : nil
                    )
                }
            }
        } else if let existingRule = task.repeatRule {
            try repository.deleteRepeatRule(existingRule)
        }
    }

    // MARK: - 日期与时间弹窗

    /// 日期与时间弹窗（草稿制：弹窗内改草稿，「确定」才写回这些 binding；
    /// 关「全天」的垫时刻规则已收进弹窗，新建与详情共用同一套）
    private var dateTimeSheet: some View {
        TaskDatePickerSheet(
            dueDate: $dueDate,
            isAllDay: Binding(
                get: { !hasTime },
                set: { hasTime = !$0 }
            ),
            hasDueDate: $hasDueDate,
            selectedReminders: $selectedReminders,
            hasRepeat: $hasRepeat,
            repeatType: $repeatType,
            selectedWeekdays: $selectedWeekdays,
            monthDay: $monthDay,
            monthWeekOrdinal: $monthWeekOrdinal,
            monthWeekday: $monthWeekday,
            monthlyRepeatMode: $monthlyRepeatMode,
            endConditionType: $endConditionType,
            repeatEndDate: $repeatEndDate,
            repeatEndCount: $repeatEndCount
        )
    }
}

// MARK: - 优先级短标签（行内胶囊空间有限，urgent 用两字短名）

private extension TaskPriority {
    var shortTitle: String {
        self == .urgent ? String(localized: "紧急") : displayTitle
    }
}

// MARK: - Preview

#Preview("编辑") {
    TaskDetailView(task: TodoTask(context: CoreDataStack.shared.viewContext), repository: TodoRepository.shared)
}

#Preview("新建") {
    TaskDetailView(repository: TodoRepository.shared, list: nil)
}
