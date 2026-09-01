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

// MARK: - 新建模式暂存子任务

private struct PendingCheckItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
}

// MARK: - 描述输入框高度自适应

private enum TaskDescriptionEditorLayout {
    static let minHeight: CGFloat = 46
    static let maxHeight: CGFloat = 132
    static let horizontalInset: CGFloat = 5
    static let verticalInset: CGFloat = 8

    static func height(for measuredTextHeight: CGFloat) -> CGFloat {
        min(max(measuredTextHeight, minHeight), maxHeight)
    }
}

private struct TaskDescriptionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = TaskDescriptionEditorLayout.minHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - TaskDetailView

struct TaskDetailView: View {
    @ObservedObject var repository: TodoRepository
    let existingTask: TodoTask?
    /// 新建入口传入的默认截止日期；仅用于区分自动填充和用户主动编辑。
    let defaultDueDate: Date?
    var onBack: (() -> Void)? = nil

    @Environment(\.dismiss) var dismiss

    // ===== 内容 =====
    @State private var title = ""
    @State private var description = ""
    @State private var descriptionEditorHeight = TaskDescriptionEditorLayout.minHeight
    @State private var priority: TaskPriority = .medium
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
    @State private var showAddListSheet = false
    @State private var showEditListSheet = false
    @State private var editingList: TodoList? = nil
    @State private var showDeleteConfirm = false
    @State private var itemToDelete: DeleteTarget? = nil
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

    // 删除目标类型（清单）
    private enum DeleteTarget: Identifiable {
        case list(TodoList)
        var id: String {
            switch self {
            case .list(let l): return "list-\(l.id)"
            }
        }
    }

    // ===== 未保存确认 / 任务删除 =====
    @State private var showDismissAlert: Bool = false
    @State private var showDeleteTaskAlert: Bool = false

    // ===== 子任务 =====
    @State private var checkItems: [CheckItem] = []
    @State private var pendingCheckItems: [PendingCheckItem] = []
    @State private var newCheckItemTitle = ""
    @State private var editingCheckItemId: UUID?
    @State private var editingCheckItemTitle = ""
    @State private var displayedChecklistProgress: Double = 0
    @State private var showChecklistCompletionCelebration = false
    @State private var checklistCompletionCelebrationID = UUID()
    @FocusState private var isCheckItemEditing: Bool

    // ===== 语音拆解子任务 =====
    @State private var isSplittingTaskVoice = false
    @FocusState private var isAddingCheckItemFocused: Bool
    @FocusState private var isTitleFocused: Bool

    // ===== 状态（编辑模式） =====
    @State private var taskStatus: TaskStatus = .todo

    // ===== 记忆 =====
    @AppStorage("lastSelectedListId") private var lastSelectedListId: String?
    @AppStorage("com.holo.thought.voice.smartSummary.enabled") private var smartSummaryEnabled: Bool = true

    // ===== 附件 =====
    @State private var pendingImages: [UIImage] = []
    @State private var showAttachmentGallery = false
    @State private var galleryStartIndex = 0
    @State private var showAttachmentSourceChoice = false
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
        _priority = State(initialValue: task.taskPriority)
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
    }

    /// 新建模式：底部「＋」、首页深链、看板、日程转任务进入
    init(
        repository: TodoRepository,
        list: TodoList? = nil,
        defaultDueDate: Date? = nil,
        prefilledTitle: String? = nil,
        prefilledDescription: String? = nil,
        prefilledPlannedRange: (start: Date, end: Date)? = nil
    ) {
        self.repository = repository
        self.existingTask = nil
        self.defaultDueDate = defaultDueDate
        self.onBack = nil

        let rememberedId = list?.id ?? (UserDefaults.standard.string(forKey: "lastSelectedListId").flatMap { UUID(uuidString: $0) })
        _selectedListId = State(initialValue: rememberedId)
        _dueDate = State(initialValue: defaultDueDate ?? Date())
        _hasDueDate = State(initialValue: defaultDueDate != nil)
        _hasTime = State(initialValue: false)
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
                            titleSection

                            // 来源想法紧跟标题：想法转来的任务标题常被改写，
                            // 原话是高频查看项，不能压在属性设置之后
                            if let thought = existingTask?.sourceThought {
                                sourceThoughtSection(thought)
                            }

                            checklistSection
                            attachmentSection
                            propertiesSection

                            autosaveHint
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)
                        .padding(.bottom, 60)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
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
                ToolbarItem(placement: .navigationBarTrailing) {
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
        .sheet(isPresented: $showListPicker) {
            listPickerSheet
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
        .sheet(isPresented: $showTaskVoiceInput, onDismiss: insertPendingTaskVoiceTranscript) {
            if smartSummaryEnabled {
                VoiceInputSheet(
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .task),
                    readySubtitle: "确认后插入到任务描述",
                    submitButtonTitle: "插入",
                    resultConfig: VoiceResultConfig(
                        title: "智能总结完成",
                        subtitle: "已整理成更适合任务描述的表达",
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
                    readySubtitle: "确认后插入到任务描述",
                    submitButtonTitle: "插入",
                    transcriptFormatter: formatTaskVoiceTranscript
                ) { transcript in
                    pendingTaskVoiceTranscriptToInsert = transcript
                    showTaskVoiceInput = false
                }
            }
        }
        .fullScreenCover(isPresented: $showAttachmentGallery) {
            if let task = existingTask {
                AttachmentGalleryView(
                    attachments: task.sortedAttachments,
                    startIndex: galleryStartIndex,
                    taskId: task.id
                )
            }
        }
        .photosPicker(
            isPresented: $showAttachmentPhotoPicker,
            selection: $selectedAttachmentPhotos,
            maxSelectionCount: existingTask != nil ? max(0, 9 - (existingTask?.sortedAttachments.count ?? 0)) : max(0, 9 - pendingImages.count),
            matching: .images
        )
        .onChange(of: selectedAttachmentPhotos) { _, newItems in
            loadAttachmentPhotos(newItems)
        }
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
        // ignoreNavigationStack: true —— 本页是 NavigationStack 根视图，
        // 系统 pop 无内容可 pop；不传则 SwipeBackModifier 会因窗口内任意 push
        // 的 NavigationStack 而让位，导致右滑失效（与 HealthDetailView 一致）。
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            handleBack()
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert, message: "还没填任务名称，退出后这次填写的内容不会被保存。") {
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
            Text("删除后将进入回收站并保留 30 天，可在「设置 → 数据管理 → 最近删除」中恢复。")
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
                || priority != task.taskPriority
                || selectedListId != task.list?.id
                || checkItems.count != (task.checkItems?.count ?? 0)
        } else {
            return !title.trimmingCharacters(in: .whitespaces).isEmpty
                || !description.isEmpty
                || hasCustomizedDefaultDueDate
                || hasRepeat
                || hasPlannedRange
                || !pendingCheckItems.isEmpty
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

    // MARK: - 标题区（完成圈 + 标题 + 重复徽章 + 描述 + 语音）

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 12) {
                // 编辑模式：完成切换
                if let task = existingTask {
                    Button {
                        toggleCompletion()
                    } label: {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(task.completed ? .holoSuccess : .holoTextSecondary)
                    }
                    .buttonStyle(.plain)
                }

                TextField("输入任务名称", text: $title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .strikethrough(existingTask?.completed == true, color: .holoTextSecondary)
                    .focused($isTitleFocused)
            }

            // 重复任务徽章
            if let task = existingTask, task.repeatRule != nil, !task.completed {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(repeatType.displayTitle)重复")
                        .font(.holoTinyLabel)
                }
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
                .padding(.leading, 36)
            }

            ZStack(alignment: .topLeading) {
                descriptionHeightMeasurer

                TextEditor(text: $description)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .frame(height: descriptionEditorHeight)
                    // 始终允许内部滚动：内容少时高度跟随内容变矮，触摸自然交给外层
                    // ScrollView；若按高度翻转 scrollDisabled（底层 UITextView
                    // .isScrollEnabled）会触发排版引擎反复重建，输入时光标卡顿。
                    .scrollContentBackground(.hidden)

                if description.isEmpty {
                    Text("添加描述、完成标准或需要注意的点")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPlaceholder)
                        .padding(.top, TaskDescriptionEditorLayout.verticalInset)
                        .padding(.leading, TaskDescriptionEditorLayout.horizontalInset)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(TaskDescriptionHeightPreferenceKey.self) { measuredHeight in
                descriptionEditorHeight = TaskDescriptionEditorLayout.height(for: measuredHeight)
            }

            taskDescriptionVoiceControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var taskDescriptionVoiceControls: some View {
        HStack(spacing: 8) {
            Button {
                HapticManager.selection()
                showTaskVoiceInput = true
            } label: {
                if isSplittingTaskVoice {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.holoPrimary)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.holoPrimary)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
                }
            }
            .buttonStyle(.plain)
            .disabled(isSplittingTaskVoice)
            .accessibilityLabel("语音输入")
            .accessibilityHint("录音并将识别结果插入到任务描述")

            Button {
                smartSummaryEnabled.toggle()
            } label: {
                Image(systemName: smartSummaryEnabled ? "sparkles" : "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(smartSummaryEnabled ? .holoPrimary : .holoTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(smartSummaryEnabled ? Color.holoPrimary.opacity(0.12) : Color.holoCardBackground)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(smartSummaryEnabled ? "关闭智能总结" : "开启智能总结")
        }
    }

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
                    HoloToastCenter.shared.show("已为你拆成 \(result.subtasks.count) 个子任务，可调整", type: .success)
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

    private var descriptionHeightMeasurer: some View {
        Text(description.isEmpty ? " " : description + "\n")
            .font(.holoBody)
            .foregroundColor(.clear)
            .padding(.horizontal, TaskDescriptionEditorLayout.horizontalInset)
            .padding(.vertical, TaskDescriptionEditorLayout.verticalInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TaskDescriptionHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .allowsHitTesting(false)
    }

    // MARK: - 完成切换（编辑模式）

    private func toggleCompletion() {
        guard let task = existingTask else { return }
        let wasCompleted = task.completed
        let shouldPromptActual = !wasCompleted && task.hasPlannedTimeRange && task.actualDurationMinutes == nil
        do {
            if task.repeatRule != nil && !task.completed {
                let generated = try repository.completeRepeatingTask(task)
                if generated {
                    repository.context.refresh(task, mergeChanges: true)
                }
            } else {
                let isCompleted = try repository.toggleTaskCompletion(task)
                if !isCompleted {
                    taskStatus = .todo
                }
            }
            HapticManager.taskCompletion()
            // 完成带时间段任务且未记录过实际用时 → 弹确认（跳过也行）
            if shouldPromptActual, task.completed {
                showActualDurationSheet = true
            }
        } catch {
            Self.logger.error("切换完成状态失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 子任务区

    /// 当前子任务总数（编辑=库内，新建=暂存）
    private var totalCheckItemCount: Int {
        existingTask != nil ? checkItems.count : pendingCheckItems.count
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行：子任务 + 说明 + 计数
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("子任务")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Text("把大任务拆成小步骤")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))

                Spacer()

                if totalCheckItemCount > 0 {
                    if existingTask != nil {
                        let completed = checkItems.filter(\.isChecked).count
                        Text("\(completed)/\(checkItems.count)")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    } else {
                        Text("\(pendingCheckItems.count)")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 进度条（编辑模式，基于本地数组实时计算）
            if existingTask != nil, !checkItems.isEmpty {
                let completedCount = checkItems.filter(\.isChecked).count
                let percent = min(max(displayedChecklistProgress, 0), 1)
                let isComplete = checklistProgress >= 1.0

                HStack {
                    Spacer()
                    Text("已完成 \(completedCount)/\(checkItems.count) 项")
                        .font(.holoCaption)
                        .foregroundColor(isComplete ? .holoSuccess : .holoTextSecondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12)

                TaskChecklistProgressBar(progress: percent, isComplete: isComplete)
                    .frame(height: 4)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .overlay {
                        if showChecklistCompletionCelebration {
                            TaskChecklistCelebrationView {
                                showChecklistCompletionCelebration = false
                            }
                            .id(checklistCompletionCelebrationID)
                            .frame(height: 90)
                            .offset(y: -28)
                            .allowsHitTesting(false)
                        }
                    }
            }

            // 子任务列表
            if existingTask != nil {
                ForEach(checkItems, id: \.id) { item in
                    checkItemRow(item)
                    if item.id != checkItems.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            } else {
                ForEach(pendingCheckItems) { item in
                    HStack(spacing: HoloSpacing.sm) {
                        Image(systemName: "circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.holoTextSecondary.opacity(0.5))

                        Text(item.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                pendingCheckItems.removeAll { $0.id == item.id }
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.holoTextSecondary.opacity(0.55))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    if item.id != pendingCheckItems.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }

            addCheckItemRow
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    /// 编辑模式的子任务行：圈勾选 + 文字改名 + ✕ 删除
    private func checkItemRow(_ item: CheckItem) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Button {
                toggleCheckItem(item)
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
                    .symbolEffect(.bounce, value: item.isChecked)
            }
            .buttonStyle(.plain)

            if editingCheckItemId == item.id {
                TextField("子任务内容", text: $editingCheckItemTitle)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .focused($isCheckItemEditing)
                    .submitLabel(.done)
                    .onSubmit {
                        commitCheckItemEdit(item)
                    }
                    .onChange(of: isCheckItemEditing) { _, focused in
                        if !focused {
                            commitCheckItemEdit(item)
                        }
                    }
            } else {
                Text(item.title)
                    .font(.holoBody)
                    .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                    .strikethrough(item.isChecked, color: .holoTextSecondary)
                    .onTapGesture {
                        startCheckItemEdit(item)
                    }
            }

            Spacer()

            Button {
                deleteCheckItem(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 底部常驻添加行：唯一提交动作 = 回车或行尾「＋」；提交后保持聚焦连续录入
    private var addCheckItemRow: some View {
        let hasText = !newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty

        return HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoPrimary)

            TextField("添加子任务，输入后按回车", text: $newCheckItemTitle)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .focused($isAddingCheckItemFocused)
                .submitLabel(.done)
                .onSubmit {
                    // 有内容：入列并保持聚焦，连续录下一条；
                    // 空内容：收起键盘，停止录入（原型的「想停就停」）
                    let hadText = !newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty
                    addCheckItem()
                    isAddingCheckItemFocused = hadText
                }
                .onChange(of: isAddingCheckItemFocused) { _, focused in
                    // 失焦时若框内仍有未提交内容，自动入列，避免切走丢字
                    if !focused {
                        addCheckItem()
                    }
                }

            Button {
                addCheckItem()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(hasText ? .white : .holoPrimary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(hasText ? Color.holoPrimary : Color.holoPrimary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .animation(.easeInOut(duration: 0.16), value: hasText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addCheckItem() {
        let trimmed = newCheckItemTitle.trimmingCharacters(in: .whitespaces)
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
            }
        } else {
            pendingCheckItems.append(PendingCheckItem(title: trimmed))
        }
        newCheckItemTitle = ""
    }

    private func toggleCheckItem(_ item: CheckItem) {
        let progressBeforeChange = checklistProgress
        displayedChecklistProgress = progressBeforeChange

        do {
            try repository.toggleCheckItem(item)
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }

                // 与任务卡同一条联动规则：子任务全勾 → 自动完成主任务；
                // 已完成任务出现未勾子任务 → 自动回未完成，避免「父完成 + 子未完成」矛盾状态
                let allChecked = !items.isEmpty && items.allSatisfy(\.isChecked)
                if allChecked != task.completed {
                    toggleCompletion()
                }
            }
            applyChecklistProgressChange(from: progressBeforeChange, to: checklistProgress)
        } catch {
            Self.logger.error("切换子任务失败：\(error.localizedDescription)")
        }
    }

    private func deleteCheckItem(_ item: CheckItem) {
        let itemID = item.id
        if editingCheckItemId == itemID {
            editingCheckItemId = nil
            editingCheckItemTitle = ""
            isCheckItemEditing = false
        }
        let progressBeforeChange = checklistProgress
        displayedChecklistProgress = progressBeforeChange

        do {
            // 先移出本地数组再删除：仓库 save 后被删对象即刻失效，
            // 此后任何属性访问（包括 removeAll 闭包里的 .id）都会触发 fault 闪退
            checkItems.removeAll { $0.id == itemID }
            try repository.deleteCheckItem(item)
            applyChecklistProgressChange(from: progressBeforeChange, to: checklistProgress)
        } catch {
            Self.logger.error("删除子任务失败：\(error.localizedDescription)")
            if let task = existingTask {
                let items = task.checkItems?.allObjects as? [CheckItem] ?? []
                checkItems = items.sorted { $0.order < $1.order }
            }
            applyChecklistProgressChange(to: checklistProgress)
        }
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

    private func startCheckItemEdit(_ item: CheckItem) {
        editingCheckItemId = item.id
        editingCheckItemTitle = item.title
        isCheckItemEditing = true
    }

    private func commitCheckItemEdit(_ item: CheckItem) {
        guard editingCheckItemId == item.id else { return }
        let trimmed = editingCheckItemTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != item.title {
            do {
                try repository.updateCheckItemTitle(item, newTitle: trimmed)
            } catch {
                Self.logger.error("更新子任务标题失败：\(error.localizedDescription)")
            }
        }
        editingCheckItemId = nil
        editingCheckItemTitle = ""
    }

    // MARK: - 附件区

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("附件")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                let count = existingTask != nil ? (existingTask?.sortedAttachments.count ?? 0) : pendingImages.count
                if count > 0 {
                    Text("\(count)")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if let task = existingTask {
                existingTaskAttachmentGrid(task)
                    .padding(12)
            } else {
                newTaskAttachmentGrid
                    .padding(12)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .confirmationDialog("添加附件", isPresented: $showAttachmentSourceChoice) {
            Button("拍照") {
                requestCameraAccess()
            }
            Button("从相册选择") {
                showAttachmentPhotoPicker = true
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func existingTaskAttachmentGrid(_ task: TodoTask) -> some View {
        let _ = attachmentsRevision
        let attachments = task.sortedAttachments
        let attachmentItems = attachments.map {
            TaskAttachmentGridItem(id: $0.id, objectID: $0.objectID, thumbnailFileName: $0.thumbnailFileName, thumbnailData: $0.thumbnailData)
        }

        TaskAttachmentGrid(
            attachments: attachmentItems,
            taskId: task.id,
            maxCount: 9,
            onAdd: { showAttachmentSourceChoice = true },
            onDelete: { attachmentID in
                do {
                    try repository.deleteAttachment(with: attachmentID)
                    attachmentsRevision += 1
                } catch {
                    Self.logger.error("删除附件失败：\(error.localizedDescription)")
                }
            },
            onTap: { index in
                galleryStartIndex = index
                showAttachmentGallery = true
            }
        )
    }

    private var newTaskAttachmentGrid: some View {
        VStack(spacing: 8) {
            if !pendingImages.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, image in
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.3), radius: 2)
                                }
                                .padding(4)
                            }
                    }

                    if pendingImages.count < 9 {
                        addAttachmentButton
                    }
                }
            } else {
                addAttachmentButton
            }
        }
    }

    private var addAttachmentButton: some View {
        Button {
            showAttachmentSourceChoice = true
        } label: {
            HStack {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("添加附件")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPlaceholder)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showAttachmentCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showAttachmentCamera = true
                    }
                }
            }
        default:
            break
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

            if let task = existingTask {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    do {
                        try await repository.addAttachment(imageData: data, to: task)
                    } catch {
                        Self.logger.error("添加附件失败：\(error.localizedDescription)")
                    }
                }
                attachmentsRevision += 1
            } else {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }
                guard !images.isEmpty else { return }
                pendingImages.append(contentsOf: images)
            }
        }
    }

    // MARK: - 属性区（时间 / 清单 / 优先级 / 状态 / 目标）

    private var propertiesSection: some View {
        VStack(spacing: 0) {
            // 时间（日期/全天/提醒/重复合并在同一入口）+ 延期快捷入口
            HStack(spacing: 0) {
                Button {
                    showTimeSheet = true
                } label: {
                    HStack(spacing: HoloSpacing.sm) {
                        rowIcon("calendar")

                        Text("时间")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer(minLength: HoloSpacing.md)

                        Text(timeSummaryText)
                            .font(.holoCaption)
                            .foregroundColor(hasDueDate ? timeValueColor : .holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.trailing)

                        rowChevron
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // 延期：与时间行同层而非嵌套（避免按钮嵌按钮的误触）；有截止日期的非重复任务才出现
                if canPostponeExistingTask {
                    Button {
                        showPostponeSheet = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                            Text("延期")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.holoPrimaryDark)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
            }

            Divider().padding(.horizontal, 12)

            // 计划时间段（时间块）：打算做事的时段，与「时间」（截止）语义分离
            Button {
                showPlannedRangeSheet = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    rowIcon("clock")

                    Text("时间段")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer(minLength: HoloSpacing.md)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(plannedRangeSummaryText)
                            .font(.holoCaption)
                            .foregroundColor(hasPlannedRange ? .holoPrimary : .holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.trailing)

                        if let actualText {
                            Text(actualText)
                                .font(.system(size: 10))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }

                    rowChevron
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 12)

            // 清单
            Button {
                showListPicker = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    rowIcon("folder")

                    Text("清单")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer(minLength: HoloSpacing.md)

                    Text(selectedListName)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)

                    rowChevron
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 12)

            // 优先级：四档平铺，不再折叠
            priorityRow

            // 状态（编辑模式）
            if existingTask != nil {
                Divider().padding(.horizontal, 12)
                statusRow
            }

            // 目标归属（可改：弹单选目标 sheet，由 GoalRepository 落库）
            if existingTask != nil {
                Divider().padding(.horizontal, 12)
                goalRow
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var timeValueColor: Color {
        guard hasDueDate else { return .holoTextSecondary }
        if let task = existingTask, dueDate < Date(), !task.completed,
           !Calendar.current.isDateInToday(dueDate) {
            return .holoError
        }
        return Calendar.current.isDateInToday(dueDate) ? .holoPrimary : .holoTextPrimary
    }

    /// 时间段行右侧摘要：「今天 10:00–12:00」；非今明用「M/d」
    private var plannedRangeSummaryText: String {
        guard hasPlannedRange else { return "未设置" }
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "M/d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let dayText = calendar.isDateInToday(plannedStart)
            ? "今天"
            : (calendar.isDateInTomorrow(plannedStart) ? "明天" : dayFormatter.string(from: plannedStart))
        return "\(dayText) \(timeFormatter.string(from: plannedStart))–\(timeFormatter.string(from: plannedEnd))"
    }

    /// 时间段行副行：实际 vs 计划对比（已记录实际用时时显示）
    private var actualText: String? {
        guard let actual = existingTask?.actualDurationMinutes?.intValue,
              let planned = existingTask?.plannedDurationMinutes else { return nil }
        let actualText = ActualDurationSheet.durationText(actual)
        let plannedText = ActualDurationSheet.durationText(planned)
        return actual == planned ? "实际 \(actualText)" : "实际 \(actualText)（计划 \(plannedText)）"
    }

    /// 延期入口条件：编辑模式 + 有截止日期 + 未完成 + 非重复（重复任务一期不接延期）。
    /// 显隐跟编辑态走：时间弹窗里关掉截止日期/打开重复后立即消失，不必等保存重进。
    private var canPostponeExistingTask: Bool {
        guard let task = existingTask else { return false }
        return TaskPostponePolicy.canPostpone(
            dueDate: hasDueDate ? dueDate : nil,
            completed: task.completed,
            repeatRuleExists: hasRepeat
        )
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

    private var priorityRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            rowIcon("flag")

            Text("优先级")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer(minLength: HoloSpacing.md)

            HStack(spacing: 5) {
                ForEach([TaskPriority.urgent, .high, .medium, .low], id: \.self) { p in
                    Button {
                        priority = p
                    } label: {
                        Text(p.shortTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(priority == p ? .white : p.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(priority == p ? p.color : p.color.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            rowIcon(taskStatus.iconName)

            Text("状态")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Menu {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button {
                        taskStatus = status
                    } label: {
                        HStack {
                            Text(status.displayTitle)
                            if taskStatus == status {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(taskStatus.color)
                        .frame(width: 8, height: 8)
                    Text(taskStatus.displayTitle)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var goalRow: some View {
        Button {
            showGoalPicker = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                rowIcon(existingTask?.goal?.goalDomain.icon ?? "target")

                Text("目标")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: HoloSpacing.md)

                Text(existingTask?.goal?.title ?? "无")
                    .font(.holoCaption)
                    .foregroundColor(existingTask?.goal.map { $0.goalDomain.badgeColor } ?? .holoTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.trailing)

                rowChevron
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
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

    private func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(.holoTextSecondary)
            .frame(width: 22)
    }

    private var rowChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.holoTextSecondary)
    }

    // MARK: - 时间摘要

    /// 是否全天（由 hasTime 反向推导）
    private var isAllDay: Bool { !hasTime }

    private var timeSummaryText: String {
        var parts: [String] = []
        if hasDueDate {
            parts.append(hasTime ? "\(formattedDueDateSummary) \(formattedTime)" : "\(formattedDueDateSummary)")
        }
        if !selectedReminders.isEmpty {
            let absoluteCount = selectedReminders.filter { $0.isAbsolute }.count
            if hasDueDate {
                parts.append("提醒\(selectedReminders.count)项")
            } else {
                // 无截止日时，摘要直接展示绝对提醒时刻
                let reminder = selectedReminders.first(where: { $0.isAbsolute })
                if let reminder = reminder {
                    parts.append("⏰ \(reminder.displayTitle)")
                    if absoluteCount > 1 {
                        parts[parts.count - 1] += " 等\(absoluteCount)项"
                    }
                }
            }
        }
        if hasRepeat {
            parts.append("重复\(repeatType.displayTitle)")
        }
        return parts.isEmpty ? "设置时间、提醒" : parts.joined(separator: " · ")
    }

    private var formattedDueDateSummary: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: dueDate)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: dueDate)
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

    // MARK: - 清单选择器 Sheet

    private var listPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.md) {
                        Button {
                            showAddListSheet = true
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoPrimary)

                                Text("新建清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoPrimary)

                                Spacer()
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(.plain)

                        Button {
                            selectedListId = nil
                            showListPicker = false
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "tray")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)

                                Text("收件箱（未归类）")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                if selectedListId == nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.holoPrimary)
                                }
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(selectedListId == nil ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(.plain)

                        ForEach(allLists, id: \.id) { list in
                            Button {
                                selectedListId = list.id
                                showListPicker = false
                            } label: {
                                HStack(spacing: HoloSpacing.sm) {
                                    Circle()
                                        .fill(Color(hex: list.color ?? "#007AFF"))
                                        .frame(width: 10, height: 10)

                                    Text(list.name)
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPrimary)

                                    Spacer()

                                    if selectedListId == list.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.holoPrimary)
                                    }
                                }
                                .padding(.horizontal, HoloSpacing.lg)
                                .padding(.vertical, HoloSpacing.md)
                                .background(selectedListId == list.id ? Color(hex: list.color ?? "#007AFF").opacity(0.1) : Color.holoCardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editingList = list
                                    showEditListSheet = true
                                } label: {
                                    Label("编辑清单", systemImage: "pencil")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    itemToDelete = .list(list)
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除清单", systemImage: "trash")
                                }
                            }
                        }

                        if allLists.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)

                                Text("点击上方\"新建清单\"创建")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary.opacity(0.7))
                            }
                            .padding(.top, HoloSpacing.xl)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("选择清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        showListPicker = false
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(isPresented: $showAddListSheet) {
                AddListSheet(repository: repository, folder: nil)
            }
            .sheet(isPresented: $showEditListSheet) {
                if let list = editingList {
                    EditListSheet(repository: repository, list: list, folders: repository.folders)
                }
            }
            .alert("确认删除", isPresented: $showDeleteConfirm, presenting: itemToDelete) { target in
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    deleteTarget(target)
                }
            } message: { target in
                switch target {
                case .list(let list):
                    Text("确定要删除清单「\(list.name)」吗？该清单下的所有任务都将被删除。")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 所有清单（包括没有文件夹的）
    private var allLists: [TodoList] {
        var lists = repository.folders.flatMap { $0.listsArray }
        let unfiledLists = repository.unfiledLists
        lists.insert(contentsOf: unfiledLists, at: 0)
        return lists
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
            return "收件箱（未归类）"
        }
        return findList(byId: listId)?.name ?? "收件箱（未归类）"
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
                        priority: priority,
                        dueDate: hasDueDate ? .set(dueDate) : .clear,
                        isAllDay: !hasTime,
                        list: selectedList,
                        reminders: remindersToSave,
                        plannedTime: hasPlannedRange ? .set(start: plannedStart, end: plannedEnd) : .clear
                    )

                    try applyRepeatRule(to: task, shouldCreate: shouldCreateRepeat)
                } else {
                    let newTask = try repository.createTask(
                        title: trimmedTitle,
                        description: description.isEmpty ? nil : description,
                        list: selectedList,
                        priority: priority,
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
                    saveErrorMessage = "保存失败：\(error.localizedDescription)"
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

    private var dateTimeSheet: some View {
        TaskDatePickerSheet(
            dueDate: $dueDate,
            isAllDay: Binding(
                get: { !hasTime },
                set: { allDay in
                    hasTime = !allDay
                    // 新建任务默认落「当天 00:00」；直接关掉全天使任务瞬间过期。
                    // 此刻把时刻垫到「当前时间向上取整到 15 分钟」，跨天则落 23:59。
                    if !allDay, dueDate == Calendar.current.startOfDay(for: dueDate) {
                        dueDate = TaskDetailTimeDefault.timedDate(from: dueDate)
                    }
                }
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
        self == .urgent ? "紧急" : displayTitle
    }
}

// MARK: - 关「全天」时的默认时刻规则

/// 新建任务默认落「当天 00:00（全天）」；用户关掉全天的瞬间，00:00 已是过去时，
/// 任务会立即显示「已过期」。这里把整点日期值垫成有意义的时刻：
/// 当前时钟向上取整到下一个 15 分钟；若已越过午夜则落回当天 23:59。
/// 非 00:00 的时刻说明用户或流程已显式选过时间，保持不动。
enum TaskDetailTimeDefault {
    static func timedDate(
        from allDayDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        guard allDayDate == calendar.startOfDay(for: allDayDate) else { return allDayDate }

        var minute = calendar.component(.minute, from: now)
        var hour = calendar.component(.hour, from: now)
        let remainder = minute % 15
        if remainder == 0 && calendar.component(.second, from: now) == 0 {
            // 恰好整 15 分钟倍数：直接用当前时刻
        } else {
            minute += 15 - remainder
            if minute >= 60 {
                minute -= 60
                hour += 1
            }
        }
        if hour >= 24 {
            hour = 23
            minute = 59
        }

        var components = calendar.dateComponents([.year, .month, .day], from: allDayDate)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? allDayDate
    }
}

// MARK: - TaskChecklistProgressBar

private struct TaskChecklistProgressBar: View {
    let progress: Double
    let isComplete: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.holoTextSecondary.opacity(0.15))

                RoundedRectangle(cornerRadius: 3)
                    .fill(isComplete ? Color.holoSuccess : Color.holoPrimary)
                    .frame(width: geometry.size.width * progress)
                    .shadow(
                        color: (isComplete ? Color.holoSuccess : Color.holoPrimary).opacity(isComplete ? 0.24 : 0),
                        radius: 4,
                        x: 0,
                        y: 0
                    )
                    .animation(.easeInOut(duration: 0.62), value: progress)
            }
        }
    }
}

// MARK: - TaskChecklistCelebrationView

private struct TaskChecklistCelebrationView: View {
    let onComplete: () -> Void

    @State private var isActive = false
    @State private var ribbons: [Ribbon] = []

    private struct Ribbon: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
        let color: Color
        let width: CGFloat
        let height: CGFloat
        let delay: Double
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(ribbons) { ribbon in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ribbon.color)
                        .frame(width: ribbon.width, height: ribbon.height)
                        .rotationEffect(.degrees(isActive ? ribbon.rotation : 0))
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 8)
                        .offset(x: isActive ? ribbon.x : 0, y: isActive ? ribbon.y : 0)
                        .opacity(isActive ? 0 : 1)
                        .animation(.easeOut(duration: 1.05).delay(ribbon.delay), value: isActive)
                }

                Circle()
                    .stroke(Color.holoSuccess.opacity(isActive ? 0 : 0.28), lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(isActive ? 1.7 : 0.45)
                    .opacity(isActive ? 0 : 1)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 10)
                    .animation(.easeOut(duration: 0.5), value: isActive)
            }
        }
        .onAppear {
            generate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                isActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                onComplete()
            }
        }
    }

    private func generate() {
        guard ribbons.isEmpty else { return }
        let palette: [Color] = [
            .holoPrimary,
            .holoSuccess,
            Color(red: 1.0, green: 0.68, blue: 0.38),
            Color(red: 0.42, green: 0.68, blue: 1.0),
        ]

        ribbons = (0..<24).map { index in
            let side = index.isMultiple(of: 2) ? -1.0 : 1.0
            return Ribbon(
                x: CGFloat(side * Double.random(in: 24...118)),
                y: CGFloat.random(in: -74...(-18)),
                rotation: Double.random(in: -170...170),
                color: palette[index % palette.count],
                width: CGFloat.random(in: 5...8),
                height: CGFloat.random(in: 12...22),
                delay: Double.random(in: 0...0.08)
            )
        }
    }
}

// MARK: - Preview

#Preview("编辑") {
    TaskDetailView(task: TodoTask(context: CoreDataStack.shared.viewContext), repository: TodoRepository.shared)
}

#Preview("新建") {
    TaskDetailView(repository: TodoRepository.shared, list: nil)
}
