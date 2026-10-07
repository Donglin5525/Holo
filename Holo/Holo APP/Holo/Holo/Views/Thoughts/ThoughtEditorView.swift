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
    static func info(_ message: String) {
        logger.info("\(message)")
    }
}

// MARK: - ThoughtEditorView

/// 想法编辑器视图
struct ThoughtEditorView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    private let thoughtRepository = ThoughtRepository()
    /// 所属主题的查询与修改（「移入主题」就近使用，与主仓储同上下文）
    private let topicRepository = TopicRepository()

    /// 保存完成回调
    var onSave: (() -> Void)?
    /// 编辑模式（传入已有想法 ID）
    var editingThoughtId: UUID? = nil
    /// 由列表双击直达编辑时自动聚焦正文；点卡片进入编辑器仍保持阅读优先。
    var autoFocusExistingThought: Bool = false
    /// 从卡片「待确认」徽章进入时滚动到 AI 归类确认区（长笔记确认位在首屏之外）
    var focusAIConfirmation: Bool = false
    /// 非-nil 即宽屏右栏内联形态：完成键收起右栏而非关闭弹层，边缘右滑停用。
    var onRequestClose: (() -> Void)? = nil

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
    /// 「查看记录」要打开的引用想法（sheet 打开对方编辑器）
    @State private var viewReferenceThoughtId: UUID? = nil

    // MARK: - UI State
    @State private var showVoiceInput: Bool = false
    @State private var pendingEditorAction: MarkdownEditorAction? = nil
    @State private var pendingVoiceTranscriptToInsert: String? = nil
    // 先用短内容的舒适起步高度，避免编辑器等待第一次布局回调时先闪出大块空白。
    @State private var editorHeight: CGFloat = 240
    @State private var typingFormatState: TypingFormatState = TypingFormatState()
    /// 正文选区长度（flomo 改版补：「…」菜单在有选中文字时切换「转为选中任务」）
    @State private var editorSelectionLength: Int = 0
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

    // MARK: - 「…」菜单（承接原详情页能力）
    /// 分享卡面板
    @State private var showShareCard: Bool = false
    /// 移入主题选择器
    @State private var showTopicPicker: Bool = false
    /// 引用关系列表（引用 / 被引用）
    @State private var showReferenceList: Bool = false
    /// 删除想法二次确认
    @State private var showDeleteConfirm: Bool = false
    /// 整理状态（决定「重新整理」是否显示；随编辑数据一并加载）
    @State private var organizedStatus: String? = nil
    /// 重新整理节流（防连点重复入队消耗配额）
    @State private var retryInFlight: Bool = false
    /// 已删除当前想法：onDisappear 的兜底保存必须跳过，否则删除后凭内容重建一条
    @State private var didDeleteCurrentThought: Bool = false
    /// 编辑数据是否加载完成（「待确认」滚动锚点等布局后动作的触发时机）
    @State private var hasLoadedEditorData: Bool = false

    /// 滚动锚点：AI 归类确认区
    private enum EditorScrollAnchor {
        static let aiTags = "editorAITagsSection"
    }

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
    /// IME 组字进行中（输入法候选未确认）。组字窗口内整页必须静默：
    /// 此刻落库会触发草稿创建/导航栏变更等全页重渲染，iOS 26 上会打断
    /// 输入法会话，造成组字文字叠影闪动（真机实锤，见 imediag.log）。
    @State private var isComposingIME = false
    /// 组字期间到期的自动保存：组字结束后补跑
    @State private var autoSaveDeferredByComposition = false
    /// AI 分类是否已触发（每个草稿只触发一次，避免自动保存重复消耗配额）
    @State private var didEnqueueAIClassification: Bool = false
    /// 短想法「暂不整理」提示是否已发过（每个编辑器会话只提示一次，避免反复打扰）
    @State private var didAnnounceShortSkip: Bool = false
    /// 本次会话是否新建过想法（V3「已记录」轻提示只在新建退出时给一次）
    @State private var didCreateThoughtInSession: Bool = false

    // MARK: - G1 保存可信（2026-10-04 体检整改）
    /// 本会话稳定身份（恢复日志 key，与 thoughtId 解耦：未落库的草稿没有 thoughtId）
    @State private var sessionId = UUID()
    /// 新建会话预分配的草稿 ID：首次落库前就固定，所有保存重试复用同一 ID，杜绝重复记录
    @State private var newSessionThoughtId: UUID? = nil
    /// 恢复日志防抖任务（比落库防抖更短，先保住已确认文本）
    @State private var recoveryTask: Task<Void, Never>? = nil
    /// 可恢复的未提交草稿（横幅展示，用户确认后才恢复，不自动覆盖）
    @State private var recoverableDraft: ThoughtEditorRecoveryDraft? = nil
    /// 完成键在图片在途时置位：全部转正结束后自动收口
    @State private var finishAfterUploadCompletes = false
    /// 编辑器强制重建令牌（恢复草稿后重建 UITextView 实例——hasLocalEdits 之后
    /// 外部改 text binding 不再刷入编辑器，必须换 identity 才能可靠载入恢复内容）
    @State private var editorReloadToken = 0

    // MARK: - Attachment State
    /// 新建模式暂存图：保留原始数据（落库走与编辑模式一致的 2048 压缩管线），
    /// preview 仅供缩略条展示，不再作为持久化来源。
    @State private var pendingImageItems: [PendingImageItem] = []
    /// 图片暂存「转正」在途标志：暂存已清空、附件尚未落库完成。
    /// 此间草稿处于「看起来无内容」的中间态，自动保存不得按空草稿删除
    /// （否则附件挂到已删除的想法上，界面刷新读到已失效对象直接崩溃）。
    @State private var isUploadingPendingImages = false
    /// 渐进加载中的图片（微信式）：占位帧先上缩略条，成品流转进暂存/附件，失败留卡可重试。
    @State private var inFlightImages: [InFlightImageItem] = []
    /// 渐进加载任务句柄：按卡 ID 索引，删除卡/退出编辑器时取消对应系统请求。
    @State private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
    /// 完成键在加载中图片在途时置位：全部流出（成功转出/删除）后自动续行收口。
    @State private var finishAfterInFlightCompletes = false
    @State private var showAttachmentPhotoPicker: Bool = false
    @State private var selectedAttachmentPhotos: [PhotosPickerItem] = []
    @State private var showAttachmentCamera: Bool = false
    @State private var pendingCameraImageData: Data?
    @State private var showAttachmentGallery: Bool = false
    @State private var galleryStartIndex: Int = 0
    @State private var editingAttachments: [ThoughtAttachmentGridItem] = []
    /// 相机权限被拒时的提示（对齐 TaskImagePicker 的做法）
    @State private var showCameraPermissionAlert: Bool = false

    /// 当前正在编辑的想法 ID（编辑模式用注入的 id，新建模式用草稿 id）
    private var currentThoughtId: UUID? { editingThoughtId ?? draftThoughtId }
    /// 是否为编辑模式（已有记录，含新建后已落库的草稿）。
    /// 注意：导航栏标题故意不用它——草稿在打字中途首次落库时若标题翻成
    /// 「编辑想法」就是一次全页重渲染，砸在组字窗口内打断输入法（叠影根因之一）。
    /// 标题只看 editingThoughtId（用户进编辑器时的意图），新建会话全程「记录想法」。
    private var isEditing: Bool { currentThoughtId != nil }

    /// 是否有实质内容：文字非空，或已有图片（纯图片想法同样合法，不再被当空草稿丢弃）
    private var hasContent: Bool {
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingImageItems.isEmpty || !editingAttachments.isEmpty
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.md) {
                        // G1：杀进程后未提交内容的恢复入口（用户确认才恢复，不自动覆盖）
                        recoveryBanner
                        // 内容编辑区（含光标吸附候选浮层）
                        contentSection
                        // AI 归类区域（只读回显）
                        // V3 新 UI：AI 建议标签确认不进主路径（§4.1 删除清单），主题徽章由列表卡片承载
                        if !ThoughtSemanticFeatureFlags.uiEnabled, !aiAssignments.isEmpty {
                            aiTagsSection
                                .id(EditorScrollAnchor.aiTags)
                        }
                        // 相关旧想法（B 阶段可感知能力 §5.2）：有历史时局部呈现 1-3 条
                        // 可回原文的旧想法；无命中安静留空，不打扰记录。
                        // id 随想法/正文版本变化——编辑后旧召回结果整体重建
                        if let currentThoughtId, hasLoadedEditorData {
                            if ThoughtSemanticFeatureFlags.uiEnabled,
                               content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 {
                                ThoughtInsightButton(content: content)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if ThoughtSemanticFeatureFlags.resurfacingEnabled {
                                ThoughtRelatedSection(
                                    thoughtID: currentThoughtId,
                                    content: content,
                                    onOpenThought: { targetId in
                                        NotificationCenter.default.post(
                                            name: .thoughtRequestOpenEditor, object: targetId)
                                    })
                                    .id("\(currentThoughtId.uuidString)-\(content.count)")
                            }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.xl)  // 底部留白（工具栏已沉入编辑器卡片底部）
                }
                .background(Color.holoToolBackground)
                // 长文编辑时允许用户下滑交互式收起键盘，避免只能点「完成」或额外点击空白处。
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(editingThoughtId != nil
                    ? String(localized: "编辑想法")
                    : String(localized: "记录想法"))
                .navigationBarTitleDisplayMode(.inline)
                // 「待确认」徽章进入：数据就绪、区块渲染后滚到 AI 归类确认位
                .onChange(of: hasLoadedEditorData) { _, loaded in
                    scrollToConfirmationIfRequested(loaded, proxy: proxy)
                }
                // 工具栏是编辑器卡片的一部分（见 contentSection 底部的 EditorFormatToolbar），
                // 不需要 SwiftUI 层 safeAreaInset，也不依赖键盘附属条。
                // 「完成」已下沉到工具栏最右（✔/纸飞机），导航栏右上只放「…」操作菜单。
                // 菜单本体新建会话也显示：「转为任务」自带先落库能力；
                // 分享/重整/删除等只在已落库时出现（菜单内部按 currentThoughtId 分支）。
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        editorOptionsMenu
                    }
                }
            }
        }
        // 右滑退出：自动保存由 onDisappear 兜底，不再弹窗确认。
        // 宽屏右栏内联形态没有「退出」语义，停用边缘手势。
        .swipeBackToDismiss(isEnabled: onRequestClose == nil) {
            dismiss()
        }
        .sheet(isPresented: $showShareCard) {
            if let thought = currentThoughtObject {
                ThoughtShareSheet(thought: thought)
            }
        }
        .sheet(isPresented: $showTopicPicker) {
            if let thoughtId = currentThoughtId {
                TopicPickerView(
                    thoughtId: thoughtId,
                    topicRepository: topicRepository,
                    onAssigned: {
                        ThoughtClassificationFeedbackStore.log(
                            .topicChange, thoughtId: thoughtId, tagName: "",
                            topicConfidence: currentThoughtObject?.topicConfidence
                        )
                        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                    },
                    allowsRemove: true
                )
            }
        }
        .sheet(isPresented: $showReferenceList) {
            if let thoughtId = currentThoughtId {
                ThoughtReferenceListView(
                    thoughtId: thoughtId,
                    thoughtRepository: thoughtRepository
                )
            }
        }
        .confirmationDialog(
            "删除这条想法？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleteCurrentThought()
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 单条删除已建批次进回收站（2026-09-06 拍板），30 天内可在最近删除自助恢复
            Text(String(localized: "删除后将进入回收站并保留 30 天，可在「设置 → 数据管理 → 最近删除」中恢复。"))
        }
        // @ 引用「查看记录」：sheet 打开对方想法的编辑器（阅读优先，不抢键盘）
        .sheet(item: $viewReferenceThoughtId) { refId in
            ThoughtEditorView(editingThoughtId: refId)
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
                    readySubtitle: String(localized: "确认后插入到想法内容"),
                    submitButtonTitle: String(localized: "插入"),
                    resultConfig: VoiceResultConfig(
                        title: String(localized: "智能总结完成"),
                        subtitle: String(localized: "已整理成更适合想法记录的表达"),
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
                    readySubtitle: String(localized: "确认后插入到想法内容"),
                    submitButtonTitle: String(localized: "插入"),
                    transcriptFormatter: formatThoughtVoiceTranscript
                ) { transcript in
                    pendingVoiceTranscriptToInsert = transcript
                    showVoiceInput = false
                }
            }
        }
        .onAppear {
            loadEditingData()
            // G1：孤儿 staged 文件对账（不被任何恢复记录引用且超期的清理掉）
            Task { await ThoughtEditorRecoveryStore.shared.cleanupOrphans() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardOverlap(note)
        }
        .onDisappear {
            // 兜底：退出时落库当前内容（防抖任务可能还没触发）。
            // cancel 旧任务避免 dismiss 后的竞争写入。
            // 删除动作走 deleteCurrentThought，不能让兜底保存凭内容把已删想法重建一条。
            autoSaveTask?.cancel()
            autoSaveTask = nil
            recoveryTask?.cancel()
            recoveryTask = nil
            // 渐进加载中的图随编辑器退出取消（加载完成前的图不进想法）
            for (_, task) in inFlightTasks {
                task.cancel()
            }
            inFlightTasks.removeAll()
            guard !didDeleteCurrentThought else { return }
            let outcome = persistContent(shouldDismiss: false, notifyDataChange: true)
            // G1：主路径已由「完成」承担；这里只兜底退出沿。保存成功时恢复记录已清，
            // 不再补写快照（避免给已落库内容留一份假草稿）；失败时内容留本机快照可找回。
            if case .failed = outcome {
                Task { @MainActor in await writeRecoverySnapshot() }
            }
        }
        // G1 §E13：无实质修改不触发保存周期——加载时设置的初始值、用户撤销回原文
        // 都在这里被挡住；真正的变化判断由 commit 层 no-op 跳过兜底。
        .onChange(of: content) { _, newValue in
            guard newValue != originalContent else { return }
            scheduleAutoSave()
            scheduleRecoverySnapshot()
        }
        // 纯图片想法同样要落库：加图/删图与文字变化走同一套防抖自动保存
        .onChange(of: pendingImageItems) { _, _ in
            scheduleAutoSave()
            scheduleRecoverySnapshot()
        }
        .alert("无法访问", isPresented: $showCameraPermissionAlert) {
            Button("取消", role: .cancel) {}
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(String(localized: "请在系统设置中允许 Holo 访问相机"))
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
            matching: .images,
            photoLibrary: .shared()
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
            if let thought = currentThoughtObject {
                ThoughtGalleryView(
                    attachments: thought.sortedAttachments,
                    startIndex: galleryStartIndex
                )
            }
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
    /// 组字（IME 候选未确认）期间不落库：保存触发的草稿创建/标题与工具栏变更
    /// 是全页重渲染，砸在组字中途就是叠影闪动的根因；推迟到组字结束再存。
    private func scheduleAutoSave() {
        guard !isComposingIME else {
            autoSaveDeferredByComposition = true
            MarkdownTextView.IMEDiag.log("autoSave deferred (composing)")
            return
        }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            persistContent(shouldDismiss: false, notifyDataChange: false)
        }
    }

    /// 编辑器上报的组字状态变化：结束时补跑被推迟的自动保存
    private func handleCompositionChange(_ composing: Bool) {
        isComposingIME = composing
        guard !composing, autoSaveDeferredByComposition else { return }
        autoSaveDeferredByComposition = false
        scheduleAutoSave()
    }

    /// 保存结果（G1）：
    /// - saved: 落库成功，带想法 ID
    /// - nothingToSave: 无需保存（未落库的空会话 / 图片转正中间态），可直接收口
    /// - failed: 落库失败，页面必须留在原地（内容未丢，可重试）
    private enum SaveOutcome: Equatable {
        case saved(UUID)
        case nothingToSave
        case failed
    }

    /// 核心持久化：单笔事务提交（正文/富文本/行内标签/引用），随后补传暂存图。
    /// - Parameters:
    ///   - shouldDismiss: 是否在保存成功后关闭页面
    ///   - notifyDataChange: 是否发送数据变更通知（退出时为 true；防抖中间保存为 false，
    ///     避免 Widget 快照、列表刷新等重链路频繁触发）
    @discardableResult
    private func persistContent(shouldDismiss: Bool, notifyDataChange: Bool) -> SaveOutcome {
        // 无文字且无图片：
        if !hasContent {
            // 图片转正在途：暂存列表刚清空、附件还没落库，「无内容」只是中间态，
            // 草稿必须保留（曾因这里误删导致新建带图想法必崩）。
            // 渐进加载在途同理：图还没转进暂存条，加载完成前草稿不得按空删除。
            guard !isUploadingPendingImages, inFlightImages.isEmpty else { return .nothingToSave }
            if let thoughtId = currentThoughtId {
                // G1 §3.4：清空已落库想法（含新建会话已自动保存过的草稿）是合法编辑——
                // 落库空正文，不再硬删除；清空前的内容已先行写入本机恢复日志可找回。
                do {
                    _ = try thoughtRepository.commitEditorContent(
                        thoughtId: thoughtId,
                        content: "",
                        inlineTags: [],
                        richContentJSON: .some(nil),
                        references: [],
                        createIfMissing: false
                    )
                    clearRecoveryRecordAfterCommit()
                    if notifyDataChange {
                        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                        onSave?()
                    }
                    if shouldDismiss { dismiss() }
                    return .saved(thoughtId)
                } catch {
                    ThoughtLog.error("清空想法保存失败", error.localizedDescription)
                    HoloToastCenter.shared.show(String(localized: "保存失败，请重试"), type: .error)
                    return .failed
                }
            }
            // 从未落库的新空会话：不创建空记录，直接收口
            if shouldDismiss { dismiss() }
            return .nothingToSave
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

        // G1：新建会话的稳定草稿 ID 在首次落库前就固定，保存重试永远复用同一 ID。
        if editingThoughtId == nil, newSessionThoughtId == nil {
            newSessionThoughtId = UUID()
        }
        let commitThoughtId = currentThoughtId ?? newSessionThoughtId!
        let createIfMissing = editingThoughtId == nil

        let persistedThoughtId: UUID
        do {
            // G1：正文/富文本/行内标签/引用同一笔事务提交——行内差异只增删 inline 来源
            //（手动标签保护），引用完全一致时不重建，无变化时跳过写入（打开即退出
            // 不动 updatedAt）；中途失败不会出现「正文已存、引用丢了」的半提交状态。
            let receipt = try repository.commitEditorContent(
                thoughtId: commitThoughtId,
                content: content,
                inlineTags: inlineTags,
                richContentJSON: .some(richJSON),
                references: referenceSnapshots,
                createIfMissing: createIfMissing
            )
            persistedThoughtId = receipt.thoughtId
            if currentThoughtId == nil {
                draftThoughtId = receipt.thoughtId
                didCreateThoughtInSession = true
                MarkdownTextView.IMEDiag.log("persistContent: draft created wasComposing=\(isComposingIME)")

                // AI 自动分类：每个草稿仅首次创建时触发一次
                if !didEnqueueAIClassification,
                   ThoughtAIClassificationPolicy.isEnabled(), content.count >= 10 {
                    didEnqueueAIClassification = true
                    Task { @MainActor in
                        ThoughtOrganizationQueue.shared.enqueue(thoughtId: receipt.thoughtId)
                    }
                }
            }

            // V2 §5.5：离开编辑器（notifyDataChange=true 即退出沿）且正文已变——
            // commit 已把状态回 pending，这里重新排队整理。防抖中间保存不触发，
            // 避免打字过程中每 2 秒消耗一次整理配额。
            if notifyDataChange, originalContent != content,
               let updated = try? repository.fetchById(persistedThoughtId),
               updated.organizedStatus == "pending" {
                Task { @MainActor in
                    ThoughtOrganizationQueue.shared.enqueue(thoughtId: persistedThoughtId)
                }
            }
        } catch {
            ThoughtLog.error("观点自动保存失败", error.localizedDescription)
            // 保存失败必须可见（flomo 改版批4）：静默失败会让用户以为已记录；
            // 继续编辑会再次触发防抖自动保存、退出还有 onDisappear 兜底，两者都是重试路径
            HoloToastCenter.shared.show(String(localized: "保存失败，继续编辑会自动重试"), type: .error)
            return .failed
        }

        // G1：正文已落库且暂存图已清空时才清恢复记录；图片在途时保留记录，
        // 进程被杀后 staged 图片仍可找回（T11）。
        clearRecoveryRecordAfterCommit()

        // 暂存图转正（新建首次落库后 / 失败重试共用一条路径）
        if !pendingImageItems.isEmpty, !isUploadingPendingImages,
           pendingImageItems.contains(where: { $0.retryCount < 3 }) {
            startPendingImageUpload()
        }

        // 同步修改检测基线
        originalContent = content

        if notifyDataChange {
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            onSave?()

            if ThoughtSemanticFeatureFlags.uiEnabled {
                // V3 §4.2：保存完成即「已记录」，保存永不等待 AI。
                // 只在新建退出时给一次；AI 相关的短想法提示不进新 UI。
                if didCreateThoughtInSession {
                    didCreateThoughtInSession = false
                    HoloToastCenter.shared.show(String(localized: "已记录"), type: .success)
                }
            } else if !didAnnounceShortSkip,
               ThoughtAIClassificationPolicy.isEnabled(),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               content.count < 10 {
                // 短想法告知（2026-09-06 东林拍板：不参与整理但要让用户知道）。
                // 与 ThoughtAIClassificationPolicy 同口径（<10 字 → skipped）；纯图想法心智上
                // 本就不期待文字整理，不提示；每个编辑器会话只提示一次。
                didAnnounceShortSkip = true
                HoloToastCenter.shared.show(
                    String(localized: "内容较短，暂不自动整理；补充内容后会自动整理"),
                    type: .info
                )
            }
        }

        if shouldDismiss {
            dismiss()
        }
        return .saved(persistedThoughtId)
    }

    // MARK: - G1 完成协议与恢复日志

    /// 「完成」主动作（G1 §3.3）：先落库并核对附件，成功才关闭；失败留在页面。
    /// 不再把关闭交给 onDisappear 兜底保存。
    private func finishEditing() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if didDeleteCurrentThought {
            closeEditor()
            return
        }
        if !inFlightImages.isEmpty {
            // 渐进加载在途：失败卡直接丢弃（进不了想法）并汇总告知；
            // 加载中的等完成自动续行收口（微信式：完成不被下载卡死，也不静默丢图）
            let failedCount = inFlightImages.filter {
                if case .failed = $0.phase { return true }
                return false
            }.count
            inFlightImages.removeAll { item in
                if case .failed = item.phase {
                    inFlightTasks[item.id]?.cancel()
                    inFlightTasks[item.id] = nil
                    return true
                }
                return false
            }
            if failedCount > 0 {
                HoloToastCenter.shared.show(
                    String(localized: "\(failedCount) 张图片加载失败，未保存"),
                    type: .error
                )
            }
            if !inFlightImages.isEmpty {
                finishAfterInFlightCompletes = true
                HoloToastCenter.shared.show(
                    String(localized: "图片正在加载，完成后自动保存"),
                    type: .info
                )
                return
            }
        }
        if isUploadingPendingImages {
            // 图片转正在途：结束后自动收口，不伪装成功
            finishAfterUploadCompletes = true
            return
        }
        if !pendingImageItems.isEmpty {
            // 有未转正的暂存图：退出前补传一轮；失败则留在页面（staged 文件与恢复
            // 记录都在，但让用户明确处理，不静默留半成品）
            finishAfterUploadCompletes = true
            startPendingImageUpload()
            return
        }
        let outcome = persistContent(shouldDismiss: false, notifyDataChange: true)
        if case .saved(let thoughtID) = outcome, editingThoughtId == nil {
            HoloMotionFeedbackCenter.shared.saved(thoughtID, domain: .thought, operationID: sessionId)
        }
        if outcome != .failed {
            closeEditor()
        }
    }

    private func closeEditor() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    /// 恢复日志防抖（800ms 合并写）：只序列化已确认文本，组字期间不写。
    private func scheduleRecoverySnapshot() {
        guard !isComposingIME else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await writeRecoverySnapshot()
        }
    }

    private func writeRecoverySnapshot() async {
        guard hasContent || editingThoughtId != nil else { return }
        let nodes = editorNodesLoaded
            ? editorNodes
            : RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: content)
        let hasStructuredContent = nodes.contains { node in
            if case .text = node { return false }
            return true
        } || content != MarkdownTextView.visiblePlainText(from: nodes)
        let richJSON = hasStructuredContent ? try? RichContentSerializer.jsonString(from: nodes) : nil
        let draft = ThoughtEditorRecoveryDraft(
            sessionId: sessionId,
            thoughtId: currentThoughtId,
            content: content,
            richContentJSON: richJSON,
            stagedImageFiles: pendingImageItems.compactMap(\.stagedFileName),
            updatedAt: Date()
        )
        await ThoughtEditorRecoveryStore.shared.save(draft)
    }

    /// 正文落库成功后同步恢复日志：暂存图还有在途时保留记录（staged 图片仍需可恢复），
    /// 否则清除本会话记录——已提交的内容不冒充「未保存草稿」。
    private func clearRecoveryRecordAfterCommit() {
        guard pendingImageItems.isEmpty else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        let sid = sessionId
        Task { await ThoughtEditorRecoveryStore.shared.clear(sessionId: sid) }
    }

    /// 恢复横幅：把上次未提交的内容载回编辑器。
    /// staged 图片回到暂存条；编辑器实例通过 editorReloadToken 重建以可靠载入。
    private func restoreRecoverableDraft(_ draft: ThoughtEditorRecoveryDraft) {
        recoverableDraft = nil
        content = draft.content
        originalContent = draft.content
        if draft.richContentJSON != nil {
            initialRichJSON = draft.richContentJSON
        }
        editorNodesLoaded = false
        editorReloadToken += 1
        // 旧记录由当前会话接管身份：清旧记录文件（staged 文件保留给新记录引用）
        let oldSessionId = draft.sessionId
        Task { await ThoughtEditorRecoveryStore.shared.clear(sessionId: oldSessionId) }
        Task { @MainActor in
            var restored: [PendingImageItem] = []
            for file in draft.stagedImageFiles {
                if let data = await ThoughtEditorRecoveryStore.shared.stagedImageData(file),
                   let image = UIImage(data: data) {
                    let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
                    if let preview {
                        restored.append(PendingImageItem(data: data, preview: preview, stagedFileName: file))
                        continue
                    }
                }
                await ThoughtEditorRecoveryStore.shared.removeStagedImage(file)
            }
            pendingImageItems.append(contentsOf: restored)
            scheduleRecoverySnapshot()
        }
    }

    /// 丢弃恢复草稿：记录与 staged 图片一并清理（用户明确说不要了）
    private func discardRecoverableDraft(_ draft: ThoughtEditorRecoveryDraft) {
        recoverableDraft = nil
        let sid = draft.sessionId
        let files = draft.stagedImageFiles
        Task {
            let store = ThoughtEditorRecoveryStore.shared
            await store.clear(sessionId: sid)
            for file in files {
                await store.removeStagedImage(file)
            }
        }
    }

    /// 恢复入口横幅
    @ViewBuilder
    private var recoveryBanner: some View {
        if let draft = recoverableDraft {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .foregroundColor(.holoPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("检测到上次未保存的内容")
                        .holoText(.body)
                    Text("保存于 \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                }
                Spacer()
                Button {
                    restoreRecoverableDraft(draft)
                } label: {
                    Text("恢复")
                        .holoText(.body)
                        .foregroundColor(.holoPrimary)
                }
                Button(role: .destructive) {
                    discardRecoverableDraft(draft)
                } label: {
                    Text("丢弃")
                        .holoText(.body)
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoToolSurface)
            .cornerRadius(HoloRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoToolBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - G1 暂存图转正

    /// 把暂存图转正为附件（新建首次落库后 / 失败重试 / 完成前补传共用）。
    /// 失败项保留原图与 staged 文件回填暂存条；连续失败 3 次停止自动重试。
    private func startPendingImageUpload() {
        let retryable = pendingImageItems.filter { $0.retryCount < 3 }
        guard !retryable.isEmpty,
              let thoughtId = currentThoughtId,
              let thought = try? thoughtRepository.fetchById(thoughtId) else {
            // 全部超限或草稿不可用：只对用户主动触发的收口给提示
            if finishAfterUploadCompletes {
                finishAfterUploadCompletes = false
                if !pendingImageItems.isEmpty {
                    HoloToastCenter.shared.show(
                        String(localized: "图片保存失败，请重试或删除后再退出"),
                        type: .error
                    )
                }
            }
            return
        }
        pendingImageItems = []
        // 清空暂存会触发 onChange 的防抖自动保存，在途标志保证中间态不被误判
        isUploadingPendingImages = true
        Task { @MainActor in
            var failed: [PendingImageItem] = []
            for var item in retryable {
                do {
                    _ = try await thoughtRepository.addAttachment(imageData: item.data, to: thought)
                    if let staged = item.stagedFileName {
                        await ThoughtEditorRecoveryStore.shared.removeStagedImage(staged)
                        item.stagedFileName = nil
                    }
                } catch {
                    ThoughtLog.error("保存图片失败", error.localizedDescription)
                    item.retryCount += 1
                    failed.append(item)
                }
            }
            if !failed.isEmpty {
                pendingImageItems.append(contentsOf: failed)
            }
            refreshEditingAttachments()
            isUploadingPendingImages = false
            if !failed.isEmpty {
                let allExhausted = failed.allSatisfy { $0.retryCount >= 3 }
                HoloToastCenter.shared.show(
                    allExhausted
                        ? String(localized: "图片保存失败，请重试或删除后再退出")
                        : String(localized: "有 \(failed.count) 张图片未保存成功，稍后自动重试"),
                    type: .error
                )
            }
            if finishAfterUploadCompletes {
                finishAfterUploadCompletes = false
                if pendingImageItems.isEmpty {
                    finishEditing()
                } else {
                    HoloToastCenter.shared.show(
                        String(localized: "图片尚未保存成功，请重试或删除后再退出"),
                        type: .error
                    )
                }
            }
        }
    }

    // MARK: - 转为任务

    /// 触发「转为任务」：先落库（含草稿首次创建），再弹确认面板。
    /// 整篇转化（selectedText=nil）和选中文字转化共用此入口。
    private func startTaskExtraction(selectedText: String? = nil, selectedRange: NSRange? = nil) {
        guard hasContent else { return }
        guard case .saved(let thoughtId) = persistContent(shouldDismiss: false, notifyDataChange: false),
              let thought = try? thoughtRepository.fetchById(thoughtId) else {
            // 落库失败不再静默（persistContent 已弹保存失败 toast；这里补动作受阻的说明）
            HoloToastCenter.shared.show(String(localized: "保存未完成，暂时无法转为任务"), type: .error)
            return
        }
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
                placeholder: String(localized: "写点什么吧…"),
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
                suggestionKeyboardHasItems: !suggestionViewModel.visibleItems.isEmpty,
                onCompositionChange: handleCompositionChange,
                onSelectionLengthChange: { length in
                    if editorSelectionLength != length {
                        editorSelectionLength = length
                    }
                }
            )
            // G1：恢复草稿后必须换 identity 重建编辑器实例——发生过本地输入的
            // UITextView 不会再消费外部 text binding，仅改绑定恢复不生效。
            .id(editorReloadToken)
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
                onCamera: {
                    if showsColorPalette { showsColorPalette = false }
                    requestCameraAccess()
                },
                onPickFromLibrary: {
                    if showsColorPalette { showsColorPalette = false }
                    Task { @MainActor in
                        // 相册读取权限是一次性前置申请：它是「iCloud 原图自动下载」的前提；
                        // 被拒也不阻断选图，本地照片不受影响
                        await PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()
                        showAttachmentPhotoPicker = true
                    }
                },
                onVoiceInput: {
                    if showsColorPalette { showsColorPalette = false }
                    HapticManager.selection()
                    showVoiceInput = true
                },
                onDone: {
                    if showsColorPalette { showsColorPalette = false }
                    ThoughtLog.info("onDone: onRequestClose=\(onRequestClose != nil)")
                    // G1 §E01：完成 = 先落库并核对附件，成功才关闭；失败留在页面可重试。
                    // onDisappear 只作最终保险，不再承担唯一成功保存路径。
                    finishEditing()
                },
                isComposingSession: editingThoughtId == nil,
                smartSummaryEnabled: $smartSummaryEnabled,
                formatState: typingFormatState,
                showsColorPalette: $showsColorPalette
            )
        }
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoToolBorder, lineWidth: 1)
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
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
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
        .background(Color.holoToolSurface)
        .cornerRadius(HoloRadius.md)
    }

    /// AI 标签 chip：未确认时提供保留/拒绝操作（与详情页一致）
    private func aiTagChip(_ assignment: ThoughtTagAssignment) -> some View {
        let tagName = assignment.tag?.name ?? ""
        let isConfirmed = assignment.source == ThoughtTagAssignment.Source.confirmedAI.rawValue

        return HStack(spacing: 4) {
            // AI 归类展示归一化后的完整主题路径（#碎碎念/加班），与列表/详情页口径一致
            Text("#\(ThoughtTagNormalizer.displayPath(tagName))")
                .holoText(.metadata)
                .foregroundColor(isConfirmed ? .holoPrimary : .holoToolTextSecondary)

            Text("AI")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(isConfirmed ? .holoPrimary.opacity(0.6) : .holoToolTextSecondary.opacity(0.5))

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
                : Color.holoToolTextSecondary.opacity(0.06)
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

    // MARK: - 「…」菜单（承接原详情页能力）

    /// 导航栏右上操作菜单：转为任务 / 分享卡 / 重新整理（条件） / 移入主题 / 查看引用 / 删除。
    /// 「转为任务」收进本菜单（flomo 改版批4：工具栏主位只留给语音与完成）；
    /// 它自带先落库能力，新建会话也可用。其余操作需要已落库的对象。
    /// 正文有选中文字时出现「转为选中文字任务」——走同一条 .convertToTask 管线
    /// （管线内部：有选中转选中、无选中转整篇），补回工具栏按钮退役后的选区能力。
    private var editorOptionsMenu: some View {
        Menu {
            if editorSelectionLength > 0 {
                Button {
                    pendingEditorAction = .convertToTask
                } label: {
                    Label("转为选中文字任务", systemImage: "text.insert")
                }
            }
            Button {
                startTaskExtraction()
            } label: {
                Label("转为任务", systemImage: "checklist")
            }

            if currentThoughtId != nil {
                Button {
                    showShareCard = true
                } label: {
                    Label("生成分享卡", systemImage: "square.and.arrow.up")
                }

                // FR-05′：单条重新整理（failed/已整理均可；skipped 短文本无意义不显示）
                if canRetryOrganization {
                    Button {
                        retryOrganization()
                    } label: {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                    .disabled(retryInFlight)
                }

                Button {
                    showTopicPicker = true
                } label: {
                    Label("移入主题", systemImage: "folder")
                }

                Button {
                    showReferenceList = true
                } label: {
                    Label("查看引用", systemImage: "link")
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除想法", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundColor(.holoToolText)
        }
    }

    /// skipped（<10 字）重试无意义不显示；failed / organized / disabled 均可手动重整
    private var canRetryOrganization: Bool {
        guard let status = organizedStatus else { return false }
        return status != "skipped" && status != "pending" && status != "processing"
    }

    private func retryOrganization() {
        guard let thoughtId = currentThoughtId, !retryInFlight else { return }
        retryInFlight = true
        defer { retryInFlight = false }

        do {
            try thoughtRepository.updateOrganizedStatus(thoughtId: thoughtId, status: "pending")
        } catch {
            ThoughtLog.error("重置整理状态失败", error.localizedDescription)
            return
        }
        ThoughtClassificationFeedbackStore.log(
            .retry, thoughtId: thoughtId, tagName: "",
            topicConfidence: currentThoughtObject?.topicConfidence
        )
        organizedStatus = "pending"
        // 状态先置 pending 再入队；旧 ai 建议保留展示，新结果写入时自然替换（方案 L-3）
        ThoughtOrganizationQueue.shared.enqueueManual(thoughtId: thoughtId)
    }

    /// 删除当前想法：软删进 30 天回收站后关闭编辑器。
    /// didDeleteCurrentThought 置位让 onDisappear 兜底保存跳过，防止删除后凭内容重建一条。
    private func deleteCurrentThought() {
        guard let thoughtId = currentThoughtId else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        didDeleteCurrentThought = true
        // 恢复记录随删除一并清理（记录里引用的 staged 文件也删）
        let sid = sessionId
        Task { await ThoughtEditorRecoveryStore.shared.clear(sessionId: sid) }
        do {
            try thoughtRepository.delete(thoughtId)
        } catch {
            ThoughtLog.error("删除想法失败", error.localizedDescription)
            didDeleteCurrentThought = false
            return
        }
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        onSave?()
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    /// 从「待确认」徽章进入时滚到 AI 归类区（数据就绪、区块已渲染后才有效）
    private func scrollToConfirmationIfRequested(_ loaded: Bool, proxy: ScrollViewProxy) {
        guard loaded, focusAIConfirmation else { return }
        // 等本帧布局完成再滚，否则 scrollTo 找不到锚点
        DispatchQueue.main.async {
            proxy.scrollTo(EditorScrollAnchor.aiTags, anchor: .top)
        }
    }

    /// 引用区域已收敛：引用统一通过正文行内 @ 添加，见 v2 方案 §10.4
    /// Token 操作菜单（sheet 形态，自绘按钮）
    @ViewBuilder
    private func tokenActionSheet(_ token: HoloContentNode) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            // 标题行
            VStack(spacing: 4) {
                Text(tokenMenuTitle(token))
                    .holoText(.sectionTitle)
                    .foregroundColor(.holoToolText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let subtitle = tokenMenuSubtitle(token) {
                    Text(subtitle)
                        .holoText(.supporting)
                        .foregroundColor(.holoToolTextSecondary)
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
                    tokenMenuButton(String(localized: "复制标签"), icon: "doc.on.doc") {
                        selectedToken = nil
                        MarkdownTextView.copyNodesToPasteboard([token])
                    }
                    tokenMenuButton(String(localized: "查看标签"), icon: "tag") {
                        selectedToken = nil
                        viewTagThoughts(displayPath)
                    }
                    tokenMenuButton(String(localized: "移除标签"), icon: "trash", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .reference(let noteId, _, _):
                    tokenMenuButton(String(localized: "复制引用"), icon: "doc.on.doc") {
                        selectedToken = nil
                        MarkdownTextView.copyNodesToPasteboard([token])
                    }
                    tokenMenuButton(String(localized: "查看记录"), icon: "doc.text") {
                        selectedToken = nil
                        // 先让 Token 操作菜单完成收起，再推进导航状态；同一事务内同时改
                        // sheet 状态会被 UIKit 的弹层系统覆盖。
                        DispatchQueue.main.async {
                            viewReferenceThoughtId = noteId
                        }
                    }
                    tokenMenuButton(String(localized: "取消引用"), icon: "link.badge.minus", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .taskMark(_, let taskId, _, _):
                    tokenMenuButton(String(localized: "查看任务"), icon: "checklist") {
                        selectedToken = nil
                        viewTask(taskId)
                    }
                    tokenMenuButton(String(localized: "取消标记"), icon: "xmark.circle", isDestructive: true) {
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
        .background(Color.holoToolSurface)
    }

    private func tokenMenuTitle(_ token: HoloContentNode) -> String {
        switch token {
        case .tag(_, let displayPath):
            return "#\(displayPath)"
        case .reference(_, let displayText, _):
            return "@\(displayText)"
        case .taskMark(_, _, let displayText, _):
            return String(localized: "已转任务：\(displayText)")
        case .text:
            return String(localized: "操作")
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
        return String(localized: "来源：\(normalizedSource)")
    }

    private func tokenMenuButton(_ title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 24)
                Text(title)
                    .holoText(.body)
                Spacer()
            }
            .foregroundColor(isDestructive ? .holoError : .holoToolText)
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

    /// 最大可选数量（已落库附件 + 暂存图 + 加载中图片共同占用 9 张上限）
    private var maxAttachmentSelection: Int {
        max(0, 9 - editingAttachments.count - pendingImageItems.count - inFlightImages.count)
    }

    /// 当前编辑中的 Thought 对象（草稿转正后也可取到；用于图库浏览、分享卡等）
    private var currentThoughtObject: Thought? {
        guard let thoughtId = currentThoughtId else { return nil }
        return try? thoughtRepository.fetchById(thoughtId)
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
        !editingAttachments.isEmpty || !pendingImageItems.isEmpty || !inFlightImages.isEmpty
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

    /// 已添加图片的横向缩略图条（带可见删除按钮）。
    /// G1：多种来源合并展示——已落库附件（点按进图库）+ 暂存图（转正失败带角标，
    /// 点按立即重试）+ 渐进加载中图片（占位帧即显，失败留卡重试），
    /// 失败图不再只是 toast 一闪而过。
    @ViewBuilder
    private var attachmentStrip: some View {
        if !editingAttachments.isEmpty || !pendingImageItems.isEmpty || !inFlightImages.isEmpty {
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
                    ForEach(pendingImageItems) { item in
                        pendingImageThumbnail(item)
                    }
                    ForEach(inFlightImages) { item in
                        inFlightThumbnail(item)
                    }
                }
            }
            .padding(HoloSpacing.md)
        }
    }

    /// 暂存图缩略块：右上删除；转正失败过（retryCount > 0）显示角标，点按立即重试
    private func pendingImageThumbnail(_ item: PendingImageItem) -> some View {
        Image(uiImage: item.preview)
            .resizable()
            .aspectRatio(1, contentMode: .fill)
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            .overlay(alignment: .topTrailing) {
                Button {
                    removePendingImage(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .overlay(alignment: .bottomTrailing) {
                if item.retryCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoError)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.retryCount > 0 {
                    retryPendingImage(item)
                }
            }
    }

    /// 加载中图片缩略块：占位帧（本机缓存低清）立即显示，加载转圈；
    /// 失败显示警示+重试字样，点按整卡重试；右上删除随时可撤。
    private func inFlightThumbnail(_ item: InFlightImageItem) -> some View {
        ZStack {
            if let placeholder = item.placeholder {
                Image(uiImage: placeholder)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                Rectangle().fill(Color.holoToolSurface)
            }
            switch item.phase {
            case .loading, .placeholderReady:
                ProgressView()
            case .failed:
                VStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoError)
                    Text("重试")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        .overlay(alignment: .topTrailing) {
            Button {
                removeInFlightImage(item)
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
            if case .failed = item.phase {
                retryInFlightImage(item)
            }
        }
    }

    /// 删除暂存图：连同 staged 文件一起清理
    private func removePendingImage(_ item: PendingImageItem) {
        pendingImageItems.removeAll { $0.id == item.id }
        if let staged = item.stagedFileName {
            Task { await ThoughtEditorRecoveryStore.shared.removeStagedImage(staged) }
        }
    }

    /// 手动重试单张失败图：清零重试计数后走统一补传
    private func retryPendingImage(_ item: PendingImageItem) {
        guard let index = pendingImageItems.firstIndex(where: { $0.id == item.id }) else { return }
        pendingImageItems[index].retryCount = 0
        if !isUploadingPendingImages {
            startPendingImageUpload()
        }
    }

    // MARK: - Actions
    /// 加载编辑数据
    private func loadEditingData() {
        guard let thoughtId = editingThoughtId else {
            // G1：新建会话查孤儿草稿（从未落库就被杀的会话），有则弹恢复横幅
            Task { @MainActor in
                let orphans = await ThoughtEditorRecoveryStore.shared.orphanDrafts()
                guard let latest = orphans.first,
                      content.isEmpty, pendingImageItems.isEmpty else { return }
                recoverableDraft = latest
            }
            return
        }

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
            // 「…」菜单的「重新整理」可见性依据
            organizedStatus = thought.organizedStatus

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
            hasLoadedEditorData = true

            // G1：查该想法的未提交修改。恢复记录比实体新（且用户尚未输入）才提示，
            // 已保存的内容不冒充未保存草稿。
            let entityUpdatedAt = thought.updatedAt
            Task { @MainActor in
                let drafts = await ThoughtEditorRecoveryStore.shared.drafts(forThoughtId: thoughtId)
                guard let latest = drafts.first,
                      latest.updatedAt > entityUpdatedAt,
                      content == (thought.content) else { return }
                recoverableDraft = latest
            }
        } catch {
            ThoughtLog.error("加载编辑数据失败", error.localizedDescription)
        }
    }

    // MARK: - Attachment Actions

    /// 加载相册选中的图片：微信式渐进加载——占位帧先上缩略条（iCloud 图秒回），
    /// 成品后台补齐后自动转正，失败留卡点按重试；多张并发互不阻塞。
    /// G1 §E02 口径保留：转正一律用会话稳定 ID（currentThoughtId），不读新建会话恒为
    /// nil 的 editingThoughtId——渐进等待期间草稿可能首次落库，settle 时实时读取即可。
    private func loadAttachmentPhotos(_ photos: [PhotosPickerItem]) {
        for photo in photos {
            startInFlightLoad(photo)
        }
        selectedAttachmentPhotos = []
    }

    /// 启动单张渐进加载。reuseId 供失败重试复用同一张卡（不新开卡位）。
    /// 注意不在此处 cancel 旧任务：重试只发生在上一轮已结束（失败返回）之后，
    /// cancel 反而会让旧任务的清理 defer 误抹新任务的句柄。
    private func startInFlightLoad(_ photo: PhotosPickerItem, reuseId: UUID? = nil) {
        let id = reuseId ?? UUID()
        if let index = inFlightImages.firstIndex(where: { $0.id == id }) {
            inFlightImages[index] = InFlightImageItem(id: id, pickerItem: photo)
        } else {
            inFlightImages.append(InFlightImageItem(id: id, pickerItem: photo))
        }
        inFlightTasks[id] = Task { @MainActor in
            defer { inFlightTasks[id] = nil }
            for await event in PhotoLibraryImageLoader.progressiveLoad(from: photo) {
                switch event {
                case .placeholder(let image):
                    if let index = inFlightImages.firstIndex(where: { $0.id == id }) {
                        inFlightImages[index].placeholder = image
                        inFlightImages[index].phase = .placeholderReady
                    }
                case .loaded(let image, let originalData):
                    await settleInFlight(id: id, image: image, originalData: originalData)
                    return
                case .failed(let outcome):
                    failInFlight(id: id, outcome: outcome)
                    return
                }
            }
        }
    }

    /// 成品到达：已落库（编辑模式/草稿已自动保存）直接转正；未落库 staged 先行落盘进暂存条。
    private func settleInFlight(id: UUID, image: UIImage, originalData: Data?) async {
        guard let data = originalData ?? image.jpegData(compressionQuality: 0.95) else {
            failInFlight(id: id, outcome: .unavailable)
            return
        }
        if let thoughtId = currentThoughtId,
           let thought = try? thoughtRepository.fetchById(thoughtId) {
            // 已落库：直接转正。失败时 commitImageDirectly 已把图挪进暂存条
            //（带 staged 文件）等待重试，不留失败卡。
            let ok = await commitImageDirectly(data, to: thought, sourceType: "photoLibrary")
            inFlightImages.removeAll { $0.id == id }
            if ok {
                refreshEditingAttachments()
            }
        } else {
            // 未落库：staged 文件先行落盘 + 暂存条展示（与旧管线同口径）
            let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
            inFlightImages.removeAll { $0.id == id }
            if let preview {
                let stagedName = UUID().uuidString + ".jpg"
                await ThoughtEditorRecoveryStore.shared.writeStagedImage(data, fileName: stagedName)
                pendingImageItems.append(
                    PendingImageItem(data: data, preview: preview, stagedFileName: stagedName)
                )
            } else {
                // preview 生成失败极罕见：直接用成品图占缩略条，不丢图
                pendingImageItems.append(PendingImageItem(data: data, preview: image))
            }
        }
        maybeFinishAfterInFlight()
    }

    /// 单张失败：卡上留重试入口；权限类失败补 toast 指引（有明确自救动作），
    /// 网络/下载类失败不再整批弹错，过程反馈由卡片承担。
    private func failInFlight(id: UUID, outcome: PhotoLoadOutcome) {
        if let index = inFlightImages.firstIndex(where: { $0.id == id }) {
            inFlightImages[index].phase = .failed(outcome)
        }
        switch outcome {
        case .permissionRequired:
            PhotoLibraryImageLoader.announceLoadFailure(failedCount: 1, totalCount: 1, permissionRequired: true)
        case .limitedAccess:
            PhotoLibraryImageLoader.announceLoadFailure(failedCount: 1, totalCount: 1, limitedAccess: true)
        default:
            break
        }
    }

    /// 删除加载中/失败卡：取消对应系统请求后移除。
    private func removeInFlightImage(_ item: InFlightImageItem) {
        inFlightTasks[item.id]?.cancel()
        inFlightTasks[item.id] = nil
        inFlightImages.removeAll { $0.id == item.id }
        maybeFinishAfterInFlight()
    }

    /// 点按失败卡重试：同卡位重启渐进加载。
    private func retryInFlightImage(_ item: InFlightImageItem) {
        startInFlightLoad(item.pickerItem, reuseId: item.id)
    }

    /// 「完成」等待加载中图片：全部流出后自动续行收口（对齐 finishAfterUploadCompletes 模式）。
    private func maybeFinishAfterInFlight() {
        guard finishAfterInFlightCompletes, inFlightImages.isEmpty else { return }
        finishAfterInFlightCompletes = false
        finishEditing()
    }

    /// 处理相机拍照数据
    private func handleCapturedImageData() {
        guard let imageData = pendingCameraImageData else { return }
        pendingCameraImageData = nil

        Task { @MainActor in
            if let thoughtId = currentThoughtId,
               let thought = try? thoughtRepository.fetchById(thoughtId) {
                // G1 §E02：会话稳定 ID，不再读 editingThoughtId（新建会话拍照图静默丢弃的老坑）
                let ok = await commitImageDirectly(imageData, to: thought, sourceType: "camera")
                if ok {
                    refreshEditingAttachments()
                }
            } else {
                guard let image = UIImage(data: imageData) else { return }
                let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
                if let preview {
                    let stagedName = UUID().uuidString + ".jpg"
                    await ThoughtEditorRecoveryStore.shared.writeStagedImage(imageData, fileName: stagedName)
                    pendingImageItems.append(
                        PendingImageItem(data: imageData, preview: preview, stagedFileName: stagedName)
                    )
                }
            }
        }
    }

    /// staged 文件先行 + 立即转正一张图；转正失败时原图进暂存条保留重试（G1 §E03），
    /// 不再让失败图凭空消失。
    private func commitImageDirectly(_ data: Data, to thought: Thought, sourceType: String) async -> Bool {
        let stagedName = UUID().uuidString + ".jpg"
        await ThoughtEditorRecoveryStore.shared.writeStagedImage(data, fileName: stagedName)
        do {
            _ = try await thoughtRepository.addAttachment(imageData: data, to: thought, sourceType: sourceType)
            await ThoughtEditorRecoveryStore.shared.removeStagedImage(stagedName)
            return true
        } catch {
            ThoughtLog.error("添加附件失败", error.localizedDescription)
            if let image = UIImage(data: data) {
                let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
                if let preview {
                    pendingImageItems.append(
                        PendingImageItem(data: data, preview: preview, stagedFileName: stagedName)
                    )
                    return false
                }
            }
            await ThoughtEditorRecoveryStore.shared.removeStagedImage(stagedName)
            return false
        }
    }

    /// 请求相机权限（被拒时给出提示而非无反馈）
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
            showCameraPermissionAlert = true
        }
    }

    /// 刷新编辑模式的附件列表
    private func refreshEditingAttachments() {
        // 新建模式的图片转正也会走到这里（草稿 id 在 draftThoughtId），不能用 editingThoughtId
        guard let thoughtId = currentThoughtId,
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

// MARK: - InFlightImageItem

/// 渐进加载中的图片卡：placeholder 是系统低清占位帧（iCloud 图秒回）；
/// phase 失败时保留 pickerItem 引用供点按重试。
private struct InFlightImageItem: Identifiable {
    enum Phase: Equatable {
        /// 系统请求已发出，占位帧未到
        case loading
        /// 占位帧已到，成品补齐中
        case placeholderReady
        case failed(PhotoLoadOutcome)
    }

    let id: UUID
    let pickerItem: PhotosPickerItem
    var placeholder: UIImage?
    var phase: Phase = .loading
}

// MARK: - PendingImageItem

/// 暂存图：data 是持久化来源（原始格式），preview 仅用于缩略条展示。
/// stagedFileName 指向本机恢复目录的原图副本（G1：落库失败不丢原图，杀进程可恢复）；
/// retryCount 记录自动重试次数，超过上限停止自动补传、等待用户手动处理。
private struct PendingImageItem: Identifiable, Equatable {
    let id: UUID
    let data: Data
    let preview: UIImage
    var stagedFileName: String?
    var retryCount: Int = 0

    init(id: UUID = UUID(), data: Data, preview: UIImage, stagedFileName: String? = nil) {
        self.id = id
        self.data = data
        self.preview = preview
        self.stagedFileName = stagedFileName
    }

    static func == (lhs: PendingImageItem, rhs: PendingImageItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Preview
#Preview {
    ThoughtEditorView()
}
