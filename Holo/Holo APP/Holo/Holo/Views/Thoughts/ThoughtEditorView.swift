//
//  ThoughtEditorView.swift
//  Holo
//
//  观点模块 - 编辑器视图
//  用于创建和编辑想法
//

import SwiftUI
import CoreData
import PhotosUI
import AVFoundation

import os.log

/// 简易日志工具
private enum ThoughtLog {
    private static let logger = Logger(subsystem: "com.holo.app", category: "ThoughtEditor")
    static func error(_ message: String, _ error: String) {
        logger.error("\(message): \(error)")
    }
}

// MARK: - ThoughtEditorView

/// 想法编辑器视图
struct ThoughtEditorView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    private let thoughtRepository = ThoughtRepository()

    /// 保存完成回调
    var onSave: (() -> Void)?
    /// 编辑模式（传入已有想法 ID）
    var editingThoughtId: UUID? = nil
    /// 由列表双击直达编辑时自动聚焦正文；从详情页菜单进入仍保持阅读优先。
    var autoFocusExistingThought: Bool = false

    // MARK: - Form State
    @State private var content: String = ""

    /// AI 归类标签（只读回显，不参与编辑保存；来自 fetchVisibleAIAssignments）
    @State private var aiAssignments: [ThoughtTagAssignment] = []

    // MARK: - Original Values (for change detection)
    @State private var originalContent: String = ""

    // MARK: - 结构化编辑状态（#/@ Token）
    /// 当前 #/@ 触发上下文（候选面板数据源）
    @State private var triggerContext: EditorTriggerContext? = nil
    /// 当前选中的 Token（弹操作菜单）
    @State private var selectedToken: HoloContentNode? = nil
    /// 编辑器节点模型（onNodesChange 回调提供）
    @State private var editorNodes: [HoloContentNode] = []
    /// 是否已收到编辑器节点回调（区分「未编辑」与「删空」）
    @State private var editorNodesLoaded: Bool = false
    /// 编辑模式初始结构化内容（恢复 Token 用）
    @State private var initialRichJSON: String? = nil
    /// 候选面板数据层
    @StateObject private var suggestionViewModel = SuggestionPanelViewModel()
    /// 「查看记录」跳转目标
    @State private var navigateToThoughtId: UUID? = nil

    // MARK: - UI State
    @State private var showVoiceInput: Bool = false
    @State private var pendingEditorAction: MarkdownEditorAction? = nil
    @State private var pendingVoiceTranscriptToInsert: String? = nil
    // 先用短内容的舒适起步高度，避免编辑器等待第一次布局回调时先闪出大块空白。
    @State private var editorHeight: CGFloat = 240
    @State private var typingFormatState: TypingFormatState = TypingFormatState()
    /// 当前光标在编辑器视图局部坐标系内的 rect（由 MarkdownTextView 上报，候选浮层据此吸附）
    @State private var caretRect: CGRect = .zero
    /// 键盘（含工具栏）当前遮挡屏幕底部的高度；编辑器据此收缩高度上限，保证光标始终可见
    @State private var keyboardOverlapHeight: CGFloat = 0
    /// 工具栏色板显隐；光标活动或候选面板触发时自动关闭
    @State private var showsColorPalette: Bool = false
    @AppStorage("com.holo.thought.voice.smartSummary.enabled") private var smartSummaryEnabled: Bool = true

    // MARK: - 转为任务
    /// 提取确认面板的参数（用 item 模式确保弹窗拿到的参数是一次性写好的、自洽的）
    @State private var taskExtractionRequest: TaskExtractionRequest? = nil

    /// 转任务面板所需参数（content + sourceThought 一次性确定，避免 sheet 闭包读到中间态）
    private struct TaskExtractionRequest: Identifiable {
        let id = UUID()
        let content: String
        let sourceThought: Thought
        let isFromSelection: Bool
        let sourceRange: NSRange?
    }

    // MARK: - 自动保存
    /// 新建模式下首次落库后拿到的草稿 ID（之后转为 update）。
    /// 编辑模式（editingThoughtId != nil）时不使用此字段。
    @State private var draftThoughtId: UUID? = nil
    /// 防抖自动保存任务（用户停顿 2 秒后落库一次）
    @State private var autoSaveTask: Task<Void, Never>? = nil
    /// AI 分类是否已触发（每个草稿只触发一次，避免自动保存重复消耗配额）
    @State private var didEnqueueAIClassification: Bool = false

    // MARK: - Attachment State
    @State private var pendingImages: [UIImage] = []
    @State private var showAttachmentSourceChoice: Bool = false
    @State private var showAttachmentPhotoPicker: Bool = false
    @State private var selectedAttachmentPhotos: [PhotosPickerItem] = []
    @State private var showAttachmentCamera: Bool = false
    @State private var pendingCameraImageData: Data?
    @State private var showAttachmentGallery: Bool = false
    @State private var galleryStartIndex: Int = 0
    @State private var editingAttachments: [ThoughtAttachmentGridItem] = []

    /// 当前正在编辑的想法 ID（编辑模式用注入的 id，新建模式用草稿 id）
    private var currentThoughtId: UUID? { editingThoughtId ?? draftThoughtId }
    /// 是否为编辑模式（已有记录）
    private var isEditing: Bool { currentThoughtId != nil }

    /// 是否有实质内容（去空格换行后非空）
    private var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    // 内容编辑区（含光标吸附候选浮层）
                    contentSection
                    // AI 归类区域（只读回显）
                    if !aiAssignments.isEmpty {
                        aiTagsSection
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)  // 底部留白（工具栏已沉入编辑器卡片底部）
            }
            .background(Color.holoBackground)
            // 长文编辑时允许用户下滑交互式收起键盘，避免只能点「完成」或额外点击空白处。
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "编辑想法" : "记录想法")
            .navigationBarTitleDisplayMode(.inline)
            // 「查看记录」跳转：通过 navigationDestination 驱动（须在 NavigationStack 内部生效）
            .navigationDestination(isPresented: Binding(
                get: { navigateToThoughtId != nil },
                set: { if !$0 { navigateToThoughtId = nil } }
            )) {
                ThoughtDetailView(
                    thoughtId: navigateToThoughtId ?? UUID(),
                    thoughtRepository: ThoughtRepository()
                )
            }
            // 工具栏是编辑器卡片的一部分（见 contentSection 底部的 EditorFormatToolbar），
            // 不需要 SwiftUI 层 safeAreaInset，也不依赖键盘附属条。
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("完成")
                    .buttonStyle(.plain)
                    .foregroundColor(.holoTextSecondary)
                }
            }
        }
        // 右滑退出：自动保存由 onDisappear 兜底，不再弹窗确认。
        .swipeBackToDismiss(isEnabled: true) {
            dismiss()
        }
        .sheet(item: $taskExtractionRequest) { request in
            ThoughtTaskExtractionSheet(
                content: request.content,
                sourceThought: request.sourceThought,
                isFromSelection: request.isFromSelection,
                visibleSourceText: visibleEditorText(for: request.sourceThought),
                sourceRange: request.sourceRange,
                onDismiss: {
                    taskExtractionRequest = nil
                },
                onCreated: { createdTasks in
                    taskExtractionRequest = nil
                    // 每个任务都携带自己的来源范围：选中文字是一段，整篇提取则是多行。
                    // 无法可靠映射的 AI 结果不强行下划线，避免给用户错误关系暗示。
                    let insertions = createdTasks.compactMap { task -> TaskMarkInsertion? in
                        guard let sourceRange = task.sourceRange else { return nil }
                        return TaskMarkInsertion(
                            taskId: task.id,
                            displayText: task.title,
                            sourceRange: sourceRange
                        )
                    }
                    if !insertions.isEmpty {
                        pendingEditorAction = .insertTaskMarks(insertions)
                    }
                    NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                }
            )
        }
        .sheet(isPresented: $showVoiceInput, onDismiss: insertPendingVoiceTranscript) {
            if smartSummaryEnabled {
                VoiceInputSheet(
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .thought),
                    readySubtitle: "确认后插入到想法内容",
                    submitButtonTitle: "插入",
                    resultConfig: VoiceResultConfig(
                        title: "智能总结完成",
                        subtitle: "已整理成更适合想法记录的表达",
                        showsOriginalToggle: true
                    ),
                    postProcessor: ThoughtVoiceSummaryProcessor(),
                    transcriptFormatter: formatThoughtVoiceTranscript
                ) { transcript in
                    pendingVoiceTranscriptToInsert = transcript
                    showVoiceInput = false
                }
            } else {
                VoiceInputSheet(
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .thought),
                    readySubtitle: "确认后插入到想法内容",
                    submitButtonTitle: "插入",
                    transcriptFormatter: formatThoughtVoiceTranscript
                ) { transcript in
                    pendingVoiceTranscriptToInsert = transcript
                    showVoiceInput = false
                }
            }
        }
        .onAppear {
            loadEditingData()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardOverlap(note)
        }
        .onDisappear {
            // 兜底：退出时落库当前内容（防抖任务可能还没触发）。
            // cancel 旧任务避免 dismiss 后的竞争写入。
            autoSaveTask?.cancel()
            autoSaveTask = nil
            persistContent(shouldDismiss: false, notifyDataChange: true)
        }
        .onChange(of: content) { _, _ in
            scheduleAutoSave()
        }
        .onChange(of: triggerContext) { _, newValue in
            suggestionViewModel.search(context: newValue, excludingThoughtId: currentThoughtId)
            if newValue != nil, showsColorPalette {
                showsColorPalette = false
            }
        }
        // 光标任何活动（点正文、移动光标）都意味着用户离开选色语境，色板随之收起
        .onChange(of: caretRect) { _, _ in
            if showsColorPalette {
                showsColorPalette = false
            }
        }
        // Token 操作菜单：用 .sheet(item:) 而非 .confirmationDialog。
        // 原因：confirmationDialog（iPhone 上即 actionSheet）呈现时会让 UITextView 失焦，
        // 触发 textViewDidEndEditing 同步清空 selectedToken，菜单还没弹出就被撤回（点 token 无反应）。
        // sheet 是 modal presentation，压在键盘之上，不受失焦竞态影响。
        .sheet(item: $selectedToken) { token in
            tokenActionSheet(token)
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        // MARK: - Attachment Modifiers
        .photosPicker(
            isPresented: $showAttachmentPhotoPicker,
            selection: $selectedAttachmentPhotos,
            maxSelectionCount: maxAttachmentSelection,
            matching: .images
        )
        .onChange(of: selectedAttachmentPhotos) { _, newValue in
            guard !newValue.isEmpty else { return }
            loadAttachmentPhotos(newValue)
        }
        .fullScreenCover(isPresented: $showAttachmentCamera, onDismiss: {
            handleCapturedImageData()
        }) {
            CameraView(
                onCapture: { imageData in
                    pendingCameraImageData = imageData
                    showAttachmentCamera = false
                },
                onDismiss: {
                    showAttachmentCamera = false
                }
            )
        }
        .fullScreenCover(isPresented: $showAttachmentGallery, onDismiss: nil) {
            if let thought = currentEditingThought {
                ThoughtGalleryView(
                    attachments: thought.sortedAttachments,
                    startIndex: galleryStartIndex
                )
            }
        }
        .confirmationDialog("添加图片", isPresented: $showAttachmentSourceChoice) {
            Button("拍照") {
                requestCameraAccess()
            }
            Button("从相册选择") {
                showAttachmentPhotoPicker = true
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 自动保存

    private func formatThoughtVoiceTranscript(_ transcript: String) -> String {
        ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: transcript,
            currentContent: content,
            selectedRange: NSRange(location: content.count, length: 0)
        )
    }

    /// 防抖自动保存：内容变化后停顿 2 秒落库一次，避免逐字写入的性能开销。
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            persistContent(shouldDismiss: false, notifyDataChange: false)
        }
    }

    /// 核心持久化：根据当前状态 create / update / 删除空草稿。
    /// - Parameters:
    ///   - shouldDismiss: 是否在保存后关闭页面（手动点保存 / 空内容退出时为 true）
    ///   - notifyDataChange: 是否发送数据变更通知（退出时为 true；防抖中间保存为 false，
    ///     避免 Widget 快照、列表刷新等重链路频繁触发）
    @discardableResult
    private func persistContent(shouldDismiss: Bool, notifyDataChange: Bool) -> UUID? {
        // 无内容：不创建空记录。已创建过的草稿（draftThoughtId != nil）删除回退。
        if !hasContent {
            if let draftId = draftThoughtId {
                try? thoughtRepository.hardDelete(draftId)
                draftThoughtId = nil
            }
            if shouldDismiss { dismiss() }
            return nil
        }

        let repository = thoughtRepository
        let nodes = editorNodesLoaded
            ? editorNodes
            : RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: content)
        // 结构化内容不只包括 @/标签/任务，也包括颜色、粗体、斜体和下划线。
        // 如果只按 Token 判断，纯格式想法会退回“只有 content 字符串”的路径，
        // 外层阅读、详情页和下一次编辑无法共享同一份可恢复事实源。
        let hasStructuredContent = nodes.contains { node in
            if case .text = node { return false }
            return true
        } || content != MarkdownTextView.visiblePlainText(from: nodes)
        let richJSON = hasStructuredContent ? try? RichContentSerializer.jsonString(from: nodes) : nil
        let referenceSnapshots: [ThoughtRepository.ReferenceSnapshot] = nodes.compactMap { node in
            guard case .reference(let noteId, let displayText, let snapshot) = node else { return nil }
            return ThoughtRepository.ReferenceSnapshot(targetId: noteId, displayText: displayText, snapshot: snapshot)
        }
        let inlineTags = InlineTagDetector.extractTags(from: content)

        let persistedThoughtId: UUID
        do {
            if let thoughtId = currentThoughtId {
                // 已有记录（编辑模式或草稿已创建）：update
                try repository.update(
                    thoughtId,
                    content: content,
                    mood: nil,
                    inlineTags: inlineTags,
                    richContentJSON: .some(richJSON)
                )
                try repository.replaceReferences(thoughtId: thoughtId, references: referenceSnapshots)
                persistedThoughtId = thoughtId
            } else {
                // 新建模式首次落库：create
                let thought = try repository.create(
                    content: content,
                    mood: nil,
                    manualTags: [],
                    inlineTags: inlineTags,
                    richContentJSON: richJSON
                )
                draftThoughtId = thought.id
                try repository.replaceReferences(thoughtId: thought.id, references: referenceSnapshots)
                // 不能依赖上面的 @State 在本次同步调用中立即回写；调用方需要继续使用刚创建的 ID。
                persistedThoughtId = thought.id

                // 上传暂存图片（新建模式首次 create 后转为编辑模式，图片落库）
                let imagesToUpload = pendingImages
                if !imagesToUpload.isEmpty {
                    pendingImages = []
                    Task { @MainActor in
                        var failedCount = 0
                        for image in imagesToUpload {
                            guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
                                failedCount += 1
                                continue
                            }
                            do {
                                _ = try await repository.addAttachment(imageData: jpegData, to: thought)
                            } catch {
                                failedCount += 1
                            }
                        }
                        if failedCount > 0 {
                            HoloToastCenter.shared.show(
                                failedCount == imagesToUpload.count
                                    ? "图片保存失败，请重新编辑添加"
                                    : "\(failedCount) 张图片保存失败，部分图片可能丢失",
                                type: .error
                            )
                        }
                    }
                }

                // AI 自动分类：每个草稿仅首次创建时触发一次
                if !didEnqueueAIClassification,
                   ThoughtAIClassificationPolicy.isEnabled(), content.count >= 10 {
                    didEnqueueAIClassification = true
                    Task { @MainActor in
                        ThoughtOrganizationQueue.shared.enqueue(thoughtId: thought.id)
                    }
                }
            }
        } catch {
            ThoughtLog.error("观点自动保存失败", error.localizedDescription)
            return nil
        }

        // 同步修改检测基线
        originalContent = content

        if notifyDataChange {
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            onSave?()
        }

        if shouldDismiss {
            dismiss()
        }
        return persistedThoughtId
    }

    // MARK: - 转为任务

    /// 触发「转为任务」：先落库（含草稿首次创建），再弹确认面板。
    /// 整篇转化（selectedText=nil）和选中文字转化共用此入口。
    private func startTaskExtraction(selectedText: String? = nil, selectedRange: NSRange? = nil) {
        guard hasContent else { return }
        guard let thoughtId = persistContent(shouldDismiss: false, notifyDataChange: false),
              let thought = try? thoughtRepository.fetchById(thoughtId) else { return }
        // 一次性构建完整请求，避免 sheet 闭包分两步读状态导致拿到中间态
        taskExtractionRequest = TaskExtractionRequest(
            content: selectedText ?? thought.content,
            sourceThought: thought,
            isFromSelection: selectedText != nil,
            sourceRange: selectedRange
        )
    }

    /// 任务范围必须以编辑器当前的可见文本为基准：Markdown 原文中的 `**`、列表符号
    /// 与编辑器实际下划线位置并不等长，直接按 Thought.content 计算会标错字符。
    private func visibleEditorText(for thought: Thought) -> String {
        let nodes = editorNodesLoaded
            ? editorNodes
            : RichContentSerializer.nodes(
                richJSON: thought.richContentJSON,
                fallbackPlainText: thought.content
            )
        // 来源范围必须基于用户真正看到的文字；任务关系附件在 attributed string
        // 中占一个 U+FFFC，但不属于正文，不能参与后续整篇任务的偏移计算。
        return MarkdownTextView.visiblePlainText(from: nodes)
    }

    /// 转任务面板所需的来源 Thought
    private var resolvedThoughtForExtraction: Thought? {
        guard let thoughtId = currentThoughtId else { return nil }
        return try? thoughtRepository.fetchById(thoughtId)
    }

    /// 查看任务：通过 deep link 跳转到任务详情（与 ChatView 跳转任务同一路径）
    private func viewTask(_ taskId: UUID) {
        DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
        dismiss()
    }

    // MARK: - Sections

    /// 内容编辑区域：编辑器是页面主体，不套表单字段的「内容」标题层级。
    /// 卡片从上到下：正文输入区（弹性高度）→ 附件条 → 工具栏（沉底，与卡片一体）。
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownTextView(
                text: $content,
                pendingAction: $pendingEditorAction,
                dynamicHeight: $editorHeight,
                formatState: $typingFormatState,
                triggerContext: $triggerContext,
                selectedToken: $selectedToken,
                caretRect: $caretRect,
                autoFocus: !isEditing || autoFocusExistingThought,
                // 语音按钮已收进底部工具栏，正文区不再为悬浮入口预留大片底部空白
                textContainerInset: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
                initialRichJSON: initialRichJSON,
                placeholder: "写点什么吧…",
                onNodesChange: { newNodes in
                    editorNodes = newNodes
                    editorNodesLoaded = true
                },
                onConvertToTask: { startTaskExtraction() },
                onConvertSelection: { selectedText, selectedRange in
                    startTaskExtraction(selectedText: selectedText, selectedRange: selectedRange)
                },
                onSuggestionCommand: handleSuggestionKeyboardCommand,
                suggestionKeyboardEnabled: triggerContext != nil,
                suggestionKeyboardHasItems: !suggestionViewModel.visibleItems.isEmpty
            )
            .frame(height: editorFrameHeight)

            attachmentStrip

            // 工具栏沉在卡片底部：同底色、同圆角，是输入框自身的一部分而不是键盘附属
            EditorFormatToolbar(
                onAction: { action in
                    pendingEditorAction = action
                    // 任何格式/插入动作都意味着用户离开选色语境
                    if showsColorPalette {
                        showsColorPalette = false
                    }
                },
                onConvertToTask: {
                    if showsColorPalette { showsColorPalette = false }
                    pendingEditorAction = .convertToTask
                },
                onAddImage: {
                    if showsColorPalette { showsColorPalette = false }
                    showAttachmentSourceChoice = true
                },
                onVoiceInput: {
                    if showsColorPalette { showsColorPalette = false }
                    HapticManager.selection()
                    showVoiceInput = true
                },
                smartSummaryEnabled: $smartSummaryEnabled,
                formatState: typingFormatState,
                showsColorPalette: $showsColorPalette
            )
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        // 候选浮层必须挂在卡片的圆角裁剪之后，才能越过短编辑器卡片展示完整列表；
        // 同时仍以卡片左上角为坐标原点，与 caretRect 保持一致。
        .overlay(alignment: .topLeading) {
            suggestionOverlay
        }
    }

    /// #/@ 候选浮层（光标吸附版）
    /// - 位置：紧贴光标上方（光标 rect 是 MarkdownTextView 局部坐标，本 overlay 与编辑器同 frame）
    /// - 对齐：默认左对齐到光标 x，右侧溢出时右对齐
    /// - 偏移：浮层底部距光标顶部 6pt；光标太靠顶部时翻转到光标下方
    /// - 触摸：浮层容器只占卡片大小（offset 定位，无 Color.clear 填充），卡片外的触摸穿透到下层编辑器
    @ViewBuilder
    private var suggestionOverlay: some View {
        if let triggerContext {
            suggestionPanelContainer(triggerContext)
        }
    }

    /// 根据光标位置计算浮层 frame 并放置 SuggestionPanelView
    /// 用编辑器实际尺寸计算边界；透明区域不设置背景，避免拦截下层编辑器触摸
    @ViewBuilder
    private func suggestionPanelContainer(_ context: EditorTriggerContext) -> some View {
        GeometryReader { proxy in
            let gap: CGFloat = 6
            let horizontalInset: CGFloat = 8
            let maximumPanelWidth: CGFloat = 280
            let maximumPanelHeight = SuggestionPanelView.referenceRowHeight * 4
            let panelWidth = min(maximumPanelWidth, max(160, proxy.size.width - horizontalInset * 2))
            let availableAbove = max(0, caretRect.minY - gap)
            let availableBelow = max(0, proxy.size.height - caretRect.maxY - gap)
            // 候选浮层允许越过编辑器的短内容边界，使用空白区域承载完整候选列表；
            // 否则 GeometryReader 会把面板压缩成两行并在卡片底部截断。
            let showBelow = availableBelow >= availableAbove
            let panelHeight = SuggestionPanelView.preferredHeight(
                for: context,
                itemCount: suggestionViewModel.visibleItems.count,
                maxHeight: maximumPanelHeight
            )
            let rawY = showBelow
                ? caretRect.maxY + gap
                : caretRect.minY - panelHeight - gap
            let offsetY = max(horizontalInset, rawY)
            let offsetX = min(
                max(horizontalInset, caretRect.minX),
                max(horizontalInset, proxy.size.width - panelWidth - horizontalInset)
            )

            SuggestionPanelView(
                context: context,
                viewModel: suggestionViewModel,
                maxHeight: panelHeight,
                onSelectTag: { tagId, path in
                    applySuggestion(.tag(id: tagId, path: path))
                },
                onCreateTag: { path in
                    applySuggestion(.createTag(path: path))
                },
                onSelectReference: { thoughtId, title, snapshot in
                    applyReferenceSuggestion(id: thoughtId, title: title, snapshot: snapshot)
                }
            )
            .frame(width: panelWidth, alignment: .topLeading)
            .offset(x: offsetX, y: offsetY)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)).animation(.easeOut(duration: 0.14)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))
                )
            )
        }
    }

    /// 鼠标/触摸与硬件键盘共用同一套候选提交规则，避免两条路径的 @ 展示逻辑再次分叉。
    private func applySuggestion(_ item: SuggestionPanelViewModel.Item) {
        suggestionViewModel.clearSelection()

        switch item {
        case .tag(let id, let path):
            pendingEditorAction = .insertTagToken(id: id, displayPath: path)
        case .createTag(let path):
            if let tag = suggestionViewModel.createTag(path: path) {
                pendingEditorAction = .insertTagToken(id: tag.id, displayPath: tag.name)
            }
        case .reference(let id, let title, _, let snapshot, _):
            applyReferenceSuggestion(id: id, title: title, snapshot: snapshot)
        }
    }

    private func applyReferenceSuggestion(id: UUID, title: String, snapshot: String) {
        // displayText 的契约是「不含 @ 前缀」的纯展示文字（makeTokenAttributedText 会补 @）。
        // 当目标想法正文以 @引用 开头时，它的 firstLine 会忠实带 @，这里必须剥掉，
        // 否则 makeTokenAttributedText 再补一个 @ 会变成 @@。
        pendingEditorAction = .insertReferenceToken(
            id: id,
            displayText: RichContentSerializer.normalizedReferenceDisplayText(
                displayText: title,
                snapshot: snapshot
            ),
            snapshot: snapshot
        )
    }

    /// 候选面板打开且有条目时，硬件键盘上下键移动、回车提交、Escape 关闭。
    private func handleSuggestionKeyboardCommand(_ command: SuggestionKeyboardCommand) {
        guard triggerContext != nil else { return }

        switch command {
        case .moveSelection(let offset):
            suggestionViewModel.moveSelection(by: offset)
        case .commitSelection:
            guard let item = suggestionViewModel.defaultCommitItem else { return }
            applySuggestion(item)
        case .dismiss:
            suggestionViewModel.clearSelection()
            pendingEditorAction = .dismissSuggestion
        }
    }

    /// AI 归类区域（只读回显）
    /// 编辑能力（保留/拒绝/重新分类）留待后续与「二次分类」一起设计
    private var aiTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 4) {
                Text("AI 归类")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(aiAssignments, id: \.id) { assignment in
                        aiTagChip(assignment)
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    /// AI 标签 chip：未确认时提供保留/拒绝操作（与详情页一致）
    private func aiTagChip(_ assignment: ThoughtTagAssignment) -> some View {
        let tagName = assignment.tag?.name ?? ""
        let isConfirmed = assignment.source == ThoughtTagAssignment.Source.confirmedAI.rawValue

        return HStack(spacing: 4) {
            // AI 归类展示归一化后的完整主题路径（#碎碎念/加班），与列表/详情页口径一致
            Text("#\(ThoughtTagNormalizer.displayPath(tagName))")
                .font(.holoLabel)
                .foregroundColor(isConfirmed ? .holoPrimary : .holoTextSecondary)

            Text("AI")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(isConfirmed ? .holoPrimary.opacity(0.6) : .holoTextSecondary.opacity(0.5))

            if !isConfirmed {
                Button {
                    let service = ThoughtOrganizationService()
                    service.confirmAssignment(assignmentId: assignment.id)
                    if let thoughtId = currentThoughtId {
                        ThoughtClassificationFeedbackStore.log(.confirm, thoughtId: thoughtId, tagName: tagName)
                    }
                    refreshAIAssignments()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoSuccess)
                }

                // FR-06′：× 默认仅本条不适合（与详情页一致），不写全局抑制
                Button {
                    let service = ThoughtOrganizationService()
                    service.rejectAssignmentCurrentOnly(assignmentId: assignment.id)
                    if let thoughtId = currentThoughtId {
                        ThoughtClassificationFeedbackStore.log(.rejectCurrent, thoughtId: thoughtId, tagName: tagName)
                    }
                    refreshAIAssignments()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.holoError.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isConfirmed
                ? Color.holoPrimary.opacity(0.08)
                : Color.holoTextSecondary.opacity(0.06)
        )
        .cornerRadius(HoloRadius.sm)
        // 标签名称来自用户/AI数据，横向滚动时保持完整内容宽度
        .fixedSize(horizontal: true, vertical: false)
        // FR-06′：全局抑制放长按菜单（90 天内不再推荐）
        .contextMenu {
            if !isConfirmed {
                Button(role: .destructive) {
                    let service = ThoughtOrganizationService()
                    service.rejectAndRecord(assignmentId: assignment.id, tagName: tagName)
                    if let thoughtId = currentThoughtId {
                        ThoughtClassificationFeedbackStore.log(.suppressGlobal, thoughtId: thoughtId, tagName: tagName)
                    }
                    refreshAIAssignments()
                } label: {
                    Label("以后不要推荐 #\(tagName)", systemImage: "hand.raised")
                }
            }
        }
    }

    /// 刷新 AI 归类标签（确认/拒绝后调用）
    private func refreshAIAssignments() {
        guard let thoughtId = currentThoughtId else { return }
        aiAssignments = (try? thoughtRepository.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []
    }

    /// 引用区域已收敛：引用统一通过正文行内 @ 添加，见 v2 方案 §10.4
    /// Token 操作菜单（sheet 形态，自绘按钮）
    @ViewBuilder
    private func tokenActionSheet(_ token: HoloContentNode) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            // 标题行
            VStack(spacing: 4) {
                Text(tokenMenuTitle(token))
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let subtitle = tokenMenuSubtitle(token) {
                    Text(subtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, HoloSpacing.sm)

            Divider()
                .padding(.vertical, 2)

            // 操作按钮（每个动作先关 sheet 再执行，避免 sheet 与跳转/dismiss 叠加）
            VStack(spacing: 0) {
                switch token {
                case .tag(_, let displayPath):
                    tokenMenuButton("复制标签", icon: "doc.on.doc") {
                        selectedToken = nil
                        MarkdownTextView.copyNodesToPasteboard([token])
                    }
                    tokenMenuButton("查看标签", icon: "tag") {
                        selectedToken = nil
                        viewTagThoughts(displayPath)
                    }
                    tokenMenuButton("移除标签", icon: "trash", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .reference(let noteId, _, _):
                    tokenMenuButton("复制引用", icon: "doc.on.doc") {
                        selectedToken = nil
                        MarkdownTextView.copyNodesToPasteboard([token])
                    }
                    tokenMenuButton("查看记录", icon: "doc.text") {
                        selectedToken = nil
                        // 先让 Token 操作菜单完成收起，再推进导航状态；同一事务内同时改
                        // sheet 和 navigationDestination，会被 UIKit 的弹层状态覆盖。
                        DispatchQueue.main.async {
                            navigateToThoughtId = noteId
                        }
                    }
                    tokenMenuButton("取消引用", icon: "link.badge.minus", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .taskMark(_, let taskId, _, _):
                    tokenMenuButton("查看任务", icon: "checklist") {
                        selectedToken = nil
                        viewTask(taskId)
                    }
                    tokenMenuButton("取消标记", icon: "xmark.circle", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .text:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.md)
        .background(Color.holoCardBackground)
    }

    private func tokenMenuTitle(_ token: HoloContentNode) -> String {
        switch token {
        case .tag(_, let displayPath):
            return "#\(displayPath)"
        case .reference(_, let displayText, _):
            return "@\(displayText)"
        case .taskMark(_, _, let displayText, _):
            return "已转任务：\(displayText)"
        case .text:
            return "操作"
        }
    }

    /// 行内 Token 为了不撑坏正文会截断；操作面板补一条来源摘要，帮助用户确认引用对象。
    /// 只对确实存在额外来源信息的引用显示，避免普通短引用增加无意义层级。
    private func tokenMenuSubtitle(_ token: HoloContentNode) -> String? {
        guard case .reference(_, let displayText, let snapshot) = token else { return nil }
        let sourceLine = RichContentSerializer.firstLine(fromPlainText: snapshot)
        guard !sourceLine.isEmpty else { return nil }
        let normalizedSource = sourceLine.hasPrefix("@") ? String(sourceLine.dropFirst()) : sourceLine
        guard normalizedSource != displayText else { return nil }
        return "来源：\(normalizedSource)"
    }

    private func tokenMenuButton(_ title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 24)
                Text(title)
                    .font(.holoBody)
                Spacer()
            }
            .foregroundColor(isDestructive ? .holoError : .holoTextPrimary)
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
    }

    /// 查看标签：保存当前内容后发筛选通知并退出
    private func viewTagThoughts(_ path: String) {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        persistContent(shouldDismiss: false, notifyDataChange: false)
        NotificationCenter.default.post(name: .thoughtRequestTagFilter, object: path)
        dismiss()
    }

    // MARK: - 图片附件区域

    /// 最大可选数量（新建模式用 pendingImages，编辑模式用 editingAttachments）
    private var maxAttachmentSelection: Int {
        if isEditing {
            return max(0, 9 - editingAttachments.count)
        }
        return max(0, 9 - pendingImages.count)
    }

    /// 当前编辑中的 Thought 对象（用于全屏浏览）
    private var currentEditingThought: Thought? {
        guard let thoughtId = editingThoughtId else { return nil }
        let repo = ThoughtRepository()
        return try? repo.fetchById(thoughtId)
    }

    private var contentEditorMinimumHeight: CGFloat {
        // 起步画布给到约屏幕 40%：想法编辑器是「一页纸」的心智，而不是表单里的一个小格子。
        min(380, UIScreen.main.bounds.height * 0.4)
    }

    /// 编辑器显示高度：短内容给足起步画布，随内容自然增长；
    /// 上限为键盘上方可视预算——超出部分由 UITextView 内部滚动承接，
    /// UIKit 打字时会自动把光标滚进可视区，键盘不再遮住正在输入的文字。
    private var editorFrameHeight: CGFloat {
        min(max(editorHeight, contentEditorMinimumHeight), editorHeightBudget)
    }

    /// 键盘弹起时编辑器卡片必须整体落在键盘上方，底部光标才可见、内部滚动才会跟随光标。
    /// 预算依次扣除：顶部导航区（状态栏+导航条+页面留白）、卡片内底部工具栏、附件条。
    private var editorHeightBudget: CGFloat {
        let attachmentHeight: CGFloat = hasAttachments ? 128 : 0
        let toolbarHeight: CGFloat = 46
        return UIScreen.main.bounds.height - keyboardOverlapHeight - 110 - toolbarHeight - attachmentHeight
    }

    private var hasAttachments: Bool {
        isEditing ? !editingAttachments.isEmpty : !pendingImages.isEmpty
    }

    // MARK: - 键盘避让

    /// 跟随键盘目标 frame 计算遮挡高度，并同步键盘动画曲线更新（与 ChatView 同一模式）。
    private func updateKeyboardOverlap(_ note: Notification) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let screenBounds = UIScreen.main.bounds
        // 只处理贴底的全宽键盘；浮动/分体键盘（iPad）不做避让
        let isDocked = endFrame.width >= screenBounds.width - 1
        let overlap = isDocked ? max(0, screenBounds.maxY - endFrame.minY) : 0
        guard overlap != keyboardOverlapHeight else { return }

        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let animation: Animation
        switch UIView.AnimationCurve(rawValue: curveRaw) {
        case .easeIn: animation = .easeIn(duration: duration)
        case .easeOut: animation = .easeOut(duration: duration)
        case .linear: animation = .linear(duration: duration)
        default: animation = .easeInOut(duration: duration)
        }
        withAnimation(animation) {
            keyboardOverlapHeight = overlap
        }
    }

    /// 已添加图片的横向缩略图条（带可见删除按钮）
    @ViewBuilder
    private var attachmentStrip: some View {
        if isEditing {
            if !editingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoloSpacing.sm) {
                        ForEach(Array(editingAttachments.enumerated()), id: \.element.id) { index, item in
                            ThoughtAttachmentThumbnailView(
                                thumbnailData: item.thumbnailData,
                                fileName: item.thumbnailFileName,
                                thoughtId: editingThoughtId ?? UUID()
                            )
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    deleteEditingAttachment(item.objectID)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                galleryStartIndex = index
                                showAttachmentGallery = true
                            }
                        }
                    }
                }
                .padding(HoloSpacing.md)
            }
        } else {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoloSpacing.sm) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, image in
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(1, contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        pendingImages.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white)
                                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                    }
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                }
                        }
                    }
                }
                .padding(HoloSpacing.md)
            }
        }
    }

    // MARK: - Actions
    /// 加载编辑数据
    private func loadEditingData() {
        guard let thoughtId = editingThoughtId else { return }

        do {
            let repo = ThoughtRepository()
            guard let thought = try repo.fetchById(thoughtId) else {
                return
            }

            // 设置当前值
            content = thought.content
            initialRichJSON = thought.richContentJSON
            // AI 归类标签只读回显（不写入行内标签，避免被 update 误处理）
            aiAssignments = (try? repo.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []

            // 设置原始值（用于比较是否有修改）
            originalContent = thought.content

            // 加载附件列表
            editingAttachments = thought.sortedAttachments.map { attachment in
                ThoughtAttachmentGridItem(
                    id: attachment.id,
                    objectID: attachment.objectID,
                    thumbnailFileName: attachment.thumbnailFileName,
                    thumbnailData: attachment.thumbnailData
                )
            }
        } catch {
            ThoughtLog.error("加载编辑数据失败", error.localizedDescription)
        }
    }

    // MARK: - Attachment Actions

    /// 加载相册选中的图片
    private func loadAttachmentPhotos(_ photos: [PhotosPickerItem]) {
        Task { @MainActor in
            for photo in photos {
                guard let data = try? await photo.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }

                if isEditing {
                    // 编辑模式：直接保存到 CoreData
                    guard let thoughtId = editingThoughtId,
                          let thought = try? thoughtRepository.fetchById(thoughtId) else { continue }
                    do {
                        _ = try await thoughtRepository.addAttachment(imageData: data, to: thought)
                        refreshEditingAttachments()
                    } catch {
                        ThoughtLog.error("添加附件失败", error.localizedDescription)
                    }
                } else {
                    // 新建模式：暂存到内存
                    let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
                    if let preview {
                        pendingImages.append(preview)
                    }
                }
            }
            selectedAttachmentPhotos = []
        }
    }

    /// 处理相机拍照数据
    private func handleCapturedImageData() {
        guard let imageData = pendingCameraImageData else { return }
        pendingCameraImageData = nil

        if isEditing {
            guard let thoughtId = editingThoughtId,
                  let thought = try? thoughtRepository.fetchById(thoughtId) else { return }
            Task { @MainActor in
                do {
                    _ = try await thoughtRepository.addAttachment(
                        imageData: imageData,
                        to: thought,
                        sourceType: "camera"
                    )
                    refreshEditingAttachments()
                } catch {
                    ThoughtLog.error("添加拍照附件失败", error.localizedDescription)
                }
            }
        } else {
            guard let image = UIImage(data: imageData) else { return }
            Task { @MainActor in
                let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
                if let preview {
                    pendingImages.append(preview)
                }
            }
        }
    }

    /// 请求相机权限
    private func requestCameraAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
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

    /// 刷新编辑模式的附件列表
    private func refreshEditingAttachments() {
        guard let thoughtId = editingThoughtId,
              let thought = try? thoughtRepository.fetchById(thoughtId) else { return }
        editingAttachments = thought.sortedAttachments.map { attachment in
            ThoughtAttachmentGridItem(
                id: attachment.id,
                objectID: attachment.objectID,
                thumbnailFileName: attachment.thumbnailFileName,
                thumbnailData: attachment.thumbnailData
            )
        }
    }

    /// 删除编辑模式的附件
    private func deleteEditingAttachment(_ objectID: NSManagedObjectID) {
        do {
            try thoughtRepository.deleteAttachment(with: objectID)
            refreshEditingAttachments()
        } catch {
            ThoughtLog.error("删除附件失败", error.localizedDescription)
        }
    }

    private func insertVoiceTranscript(_ transcript: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        pendingEditorAction = .insertText(trimmedTranscript)
    }

    private func insertPendingVoiceTranscript() {
        guard let transcript = pendingVoiceTranscriptToInsert else { return }
        pendingVoiceTranscriptToInsert = nil

        DispatchQueue.main.async {
            insertVoiceTranscript(transcript)
        }
    }
}

// MARK: - Preview
#Preview {
    ThoughtEditorView()
}
