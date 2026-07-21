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

    // MARK: - Form State
    @State private var content: String = ""
    @State private var selectedMood: ThoughtMoodType? = nil

    /// AI 归类标签（只读回显，不参与编辑保存；来自 fetchVisibleAIAssignments）
    @State private var aiAssignments: [ThoughtTagAssignment] = []

    // MARK: - Original Values (for change detection)
    @State private var originalContent: String = ""
    @State private var originalMood: ThoughtMoodType? = nil

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
    @State private var isSaving: Bool = false
    @State private var showDismissAlert: Bool = false
    @State private var pendingEditorAction: MarkdownEditorAction? = nil
    @State private var pendingVoiceTranscriptToInsert: String? = nil
    @State private var editorHeight: CGFloat = 360
    @State private var typingFormatState: TypingFormatState = TypingFormatState()
    /// 当前光标在编辑器视图局部坐标系内的 rect（由 MarkdownTextView 上报，候选浮层据此吸附）
    @State private var caretRect: CGRect = .zero
    @AppStorage("com.holo.thought.voice.smartSummary.enabled") private var smartSummaryEnabled: Bool = true

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
    /// 是否为编辑模式
    private var isEditing: Bool { editingThoughtId != nil }

    /// 是否可保存
    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    /// 是否有内容（用于判断退出时是否需要保存）
    private var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    // 内容编辑区（含光标吸附候选浮层）
                    contentSection
                    // 标签区域（只读展示正文中已识别的 # 标签）
                    tagsSection
                    // AI 归类区域（只读回显）
                    if !aiAssignments.isEmpty {
                        aiTagsSection
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, 120)  // 给底部工具栏 + 安全区留位
            }
            .background(Color.holoBackground)
            .scrollDismissesKeyboard(.never)  // 禁止下滑自动收键盘（编辑器自己管焦点）
            .navigationTitle(isEditing ? "编辑想法" : "记录想法")
            .navigationBarTitleDisplayMode(.inline)
            // 「查看记录」跳转：NavigationLink 必须在 NavigationView 内部才生效
            .background(
                NavigationLink(
                    destination: ThoughtDetailView(
                        thoughtId: navigateToThoughtId ?? UUID(),
                        thoughtRepository: ThoughtRepository()
                    ),
                    isActive: Binding(
                        get: { navigateToThoughtId != nil },
                        set: { if !$0 { navigateToThoughtId = nil } }
                    )
                ) {
                    EmptyView()
                }
            )
            .safeAreaInset(edge: .bottom) {
                // 底栏只保留编辑工具栏（吸附键盘上方）；候选浮层已移至 contentSection 内光标吸附
                RichTextToolbarView(pendingAction: $pendingEditorAction, formatState: typingFormatState, onAddImage: {
                    showAttachmentSourceChoice = true
                })
                .background(Color.holoCardBackground)
                .overlay(
                    Rectangle()
                        .fill(Color.holoBorder)
                        .frame(height: 1),
                    alignment: .top
                )
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        handleDismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveThought()
                    }
                    .foregroundColor(canSave ? .holoPrimary : .holoTextSecondary)
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
        .navigationViewStyle(.stack)
        // 关键：接管系统返回手势 —— fullScreenCover 下无系统下滑关闭，
        // 左边缘右滑由 SwipeBackModifier 统一处理，回调走 handleDismiss（自动保存）
        .swipeBackToDismiss(isEnabled: true) {
            handleDismiss()
        }
        .sheet(isPresented: $showVoiceInput, onDismiss: insertPendingVoiceTranscript) {
            if smartSummaryEnabled {
                VoiceInputSheet(
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(),
                    maximumDuration: 300,
                    readySubtitle: "确认后插入到观点内容",
                    submitButtonTitle: "插入",
                    resultConfig: VoiceResultConfig(
                        title: "智能总结完成",
                        subtitle: "已整理成更适合观点记录的表达",
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
                    speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(),
                    maximumDuration: 300,
                    readySubtitle: "确认后插入到观点内容",
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
        // 兜底：视图销毁时若仍有未保存内容则强制保存（防任何意外退出路径丢数据）
        .onDisappear {
            saveIfHasUnsavedChanges()
        }
        .onChange(of: triggerContext) { _, newValue in
            suggestionViewModel.search(context: newValue, excludingThoughtId: editingThoughtId)
        }
        .confirmationDialog(
            tokenMenuTitle,
            isPresented: tokenMenuPresented,
            titleVisibility: .visible
        ) {
            tokenMenuButtons
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

    // MARK: - Dismiss Handling

    private func formatThoughtVoiceTranscript(_ transcript: String) -> String {
        ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: transcript,
            currentContent: content,
            selectedRange: NSRange(location: content.count, length: 0)
        )
    }

    /// 处理取消/右滑退出：有未保存内容则自动保存，否则直接退出
    /// 这是「右滑返回 / 取消按钮」的统一出口，保证任何退出路径都不会丢内容
    private func handleDismiss() {
        if hasContent && hasUnsavedChanges {
            // 有内容且有修改时自动保存
            saveThought()
        } else {
            // 无内容或无修改时直接退出
            dismiss()
        }
    }

    /// onDisappear 兜底：视图销毁时若仍有未保存修改则强制保存
    /// 防止任何意外退出路径（系统回收、路由跳转等）丢失用户输入
    private func saveIfHasUnsavedChanges() {
        guard hasContent, hasUnsavedChanges, !isSaving else { return }
        // 标记 isSaving 避免与按钮触发的 saveThought 重复保存
        saveThought()
    }

    // MARK: - 未保存修改检测

    /// 是否有未保存的修改
    private var hasUnsavedChanges: Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = originalContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // 内容发生变化（含 Token 增删，派生文本随之变化）
        if trimmedContent != trimmedOriginal {
            return true
        }

        // 新建模式有暂存图片
        if !isEditing && !pendingImages.isEmpty {
            return true
        }

        return false
    }

    // MARK: - Sections

    /// 内容编辑区域
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("内容")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                ZStack(alignment: .bottomTrailing) {
                    MarkdownTextView(
                        text: $content,
                        pendingAction: $pendingEditorAction,
                        dynamicHeight: $editorHeight,
                        formatState: $typingFormatState,
                        triggerContext: $triggerContext,
                        selectedToken: $selectedToken,
                        caretRect: $caretRect,
                        textContainerInset: UIEdgeInsets(top: 22, left: 16, bottom: 88, right: 16),
                        initialRichJSON: initialRichJSON,
                        onNodesChange: { newNodes in
                            editorNodes = newNodes
                            editorNodesLoaded = true
                        }
                    )
                        .frame(height: max(editorHeight, contentEditorMinimumHeight))
                        // 光标吸附候选浮层：挂在 MarkdownTextView 自身上，
                        // 这样 overlay 坐标系与 caretRect（UITextView 局部坐标）完全对齐
                        .overlay(alignment: .topLeading) {
                            suggestionOverlay
                        }

                    voiceInputButton
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                }

                attachmentStrip
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
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
    /// 纯 offset 定位（不用 GeometryReader/Color.clear），避免透明区域拦截下层触摸
    @ViewBuilder
    private func suggestionPanelContainer(_ context: EditorTriggerContext) -> some View {
        let panelWidth: CGFloat = 280
        let gap: CGFloat = 6
        let estimatedPanelHeight: CGFloat = 200
        // 翻转判断：光标在编辑器顶部 1/4 以上时，浮层显示在光标下方
        let showBelow = caretRect.minY < estimatedPanelHeight + gap + 8
        // x 边界：光标右侧对齐，超出时左移（保守估算，编辑器宽度通常 > panelWidth + 32）
        let editorEstimatedWidth: CGFloat = max(panelWidth + 32, UIScreen.main.bounds.width - 32 - 32)  // 减去卡片左右 padding
        let clampedX = max(0, min(caretRect.maxX, editorEstimatedWidth - panelWidth))
        // 浮层左上角偏移：x 已裁剪；y 让浮层底部贴光标顶部（或翻转时顶部贴光标下方）
        let offsetX = clampedX
        let offsetY: CGFloat = showBelow
            ? caretRect.maxY + gap
            : max(8, caretRect.minY - estimatedPanelHeight - gap)

        SuggestionPanelView(
            context: context,
            viewModel: suggestionViewModel,
            onSelectTag: { tagId, path in
                pendingEditorAction = .insertTagToken(id: tagId, displayPath: path)
            },
            onCreateTag: { path in
                if let tag = suggestionViewModel.createTag(path: path) {
                    pendingEditorAction = .insertTagToken(id: tag.id, displayPath: tag.name)
                }
            },
            onSelectReference: { thoughtId, title, snapshot in
                pendingEditorAction = .insertReferenceToken(
                    id: thoughtId,
                    displayText: RichContentSerializer.truncatedReferenceDisplay(title),
                    snapshot: snapshot
                )
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

    private var voiceInputButton: some View {
        HStack(spacing: 8) {
            Button {
                HapticManager.selection()
                showVoiceInput = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.holoPrimary)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.16), radius: 8, x: 0, y: 4)
            }
            .accessibilityLabel("语音输入")
            .accessibilityHint("录音并将识别结果插入到当前光标位置")

            Button {
                smartSummaryEnabled.toggle()
            } label: {
                Image(systemName: smartSummaryEnabled ? "sparkles" : "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(smartSummaryEnabled ? .holoPrimary : .holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(smartSummaryEnabled ? Color.holoPrimary.opacity(0.12) : Color.holoCardBackground)
                    )
            }
            .accessibilityLabel(smartSummaryEnabled ? "关闭智能总结" : "开启智能总结")
        }
    }

    /// 标签区域（只读展示正文中已识别的 # 标签，新增标签统一走行内 #）
    private var tagsSection: some View {
        let inlineTags = InlineTagDetector.extractTags(from: content)

        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text("正文中输入 # 添加")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }

            if !inlineTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(inlineTags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.holoLabel)
                                .foregroundColor(.holoPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.holoPrimary.opacity(0.1))
                                .cornerRadius(HoloRadius.sm)
                        }
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
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
                        aiTagChip(assignment.tag?.name ?? "")
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    /// 只读 AI 标签 chip（灰色调 + AI 角标，视觉与卡片/详情页一致）
    private func aiTagChip(_ tagName: String) -> some View {
        HStack(spacing: 3) {
            Text("#\(tagName)")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
            Text("AI")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.holoTextSecondary.opacity(0.08))
        .cornerRadius(HoloRadius.sm)
    }

    /// 引用区域已收敛：引用统一通过正文行内 @ 添加，见 v2 方案 §10.4
    /// Token 操作菜单
    private var tokenMenuTitle: String {
        switch selectedToken {
        case .tag(_, let displayPath):
            return "#\(displayPath)"
        case .reference(_, let displayText, _):
            return "@\(displayText)"
        case .text, .none:
            return "操作"
        }
    }

    private var tokenMenuPresented: Binding<Bool> {
        Binding(
            get: { selectedToken != nil },
            set: { if !$0 { selectedToken = nil } }
        )
    }

    @ViewBuilder
    private var tokenMenuButtons: some View {
        switch selectedToken {
        case .tag(_, let displayPath):
            Button("查看标签") {
                viewTagThoughts(displayPath)
            }
            Button("移除标签", role: .destructive) {
                pendingEditorAction = .removeSelectedToken
            }
        case .reference(let noteId, _, _):
            Button("查看记录") {
                navigateToThoughtId = noteId
            }
            Button("取消引用", role: .destructive) {
                pendingEditorAction = .removeSelectedToken
            }
        case .text, .none:
            EmptyView()
        }
    }

    /// 查看标签：关闭编辑器（自动保存）并请求列表按该标签筛选
    private func viewTagThoughts(_ path: String) {
        NotificationCenter.default.post(name: .thoughtRequestTagFilter, object: path)
        handleDismiss()
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

    private var hasAttachments: Bool {
        isEditing ? !editingAttachments.isEmpty : !pendingImages.isEmpty
    }

    private var contentEditorMinimumHeight: CGFloat {
        hasAttachments ? 220 : 360
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
                                .padding(2)
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
                                    .padding(2)
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
            selectedMood = ThoughtMoodType(from: thought.mood)
            initialRichJSON = thought.richContentJSON
            // AI 归类标签只读回显（不写入行内标签，避免被 update 误处理）
            aiAssignments = (try? repo.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []

            // 设置原始值（用于比较是否有修改）
            originalContent = thought.content
            originalMood = ThoughtMoodType(from: thought.mood)

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

    /// 保存想法
    private func saveThought() {
        guard canSave else {
            // 如果没有内容，直接退出
            dismiss()
            return
        }

        // 如果是编辑模式且没有修改，直接退出
        if isEditing && !hasUnsavedChanges {
            dismiss()
            return
        }

        isSaving = true

        let repository = ThoughtRepository()

        // 结构化内容：节点模型优先，未编辑过时回退到初始 JSON/纯文本
        let nodes = editorNodesLoaded
            ? editorNodes
            : RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: content)
        let hasTokens = nodes.contains { node in
            if case .text = node { return false }
            return true
        }
        let richJSON = hasTokens ? try? RichContentSerializer.jsonString(from: nodes) : nil
        let referenceSnapshots: [ThoughtRepository.ReferenceSnapshot] = nodes.compactMap { node in
            guard case .reference(let noteId, let displayText, let snapshot) = node else { return nil }
            return ThoughtRepository.ReferenceSnapshot(targetId: noteId, displayText: displayText, snapshot: snapshot)
        }

        // 分离手动标签与内联 # 标签（不再合并后传入，保留来源信息）
        let inlineTags = InlineTagDetector.extractTags(from: content)

        do {
            if isEditing, let thoughtId = editingThoughtId {
                // 编辑模式：更新已有想法（标签全部来自正文行内 #，保存时以当前内容重建）
                // 用 inlineTags 参数（而非 tags）让 repository 保留 AI assignments，新标签标 inline source
                try repository.update(
                    thoughtId,
                    content: content,
                    mood: selectedMood?.rawValue,
                    inlineTags: inlineTags,
                    richContentJSON: .some(richJSON)
                )
                try repository.replaceReferences(thoughtId: thoughtId, references: referenceSnapshots)
            } else {
                // 新建模式
                let thought = try repository.create(
                    content: content,
                    mood: selectedMood?.rawValue,
                    manualTags: [],
                    inlineTags: inlineTags,
                    richContentJSON: richJSON
                )
                try repository.replaceReferences(thoughtId: thought.id, references: referenceSnapshots)

                // 保存待上传图片（后台逐张处理）—— 先快照到局部变量，避免后续清空 state 影响迭代
                let imagesToUpload = pendingImages
                if !imagesToUpload.isEmpty {
                    Task { @MainActor in
                        for image in imagesToUpload {
                            guard let jpegData = image.jpegData(compressionQuality: 0.85) else { continue }
                            _ = try? await repository.addAttachment(imageData: jpegData, to: thought)
                        }
                    }
                }

                // AI 自动整理：新想法保存后触发（仅新建，编辑不触发）
                if ThoughtAIClassificationPolicy.isEnabled() && content.count >= 10 {
                    Task { @MainActor in
                        ThoughtOrganizationQueue.shared.enqueue(thoughtId: thought.id)
                    }
                }
            }
        } catch {
            ThoughtLog.error("观点保存失败", error.localizedDescription)
            isSaving = false
            return
        }

        // 标记为已保存：同步 originalContent，避免后续 onDisappear 兜底重复保存
        // （saveThought 与 onDisappear 可能先后触发，必须用 originalContent 作为「干净基线」）
        originalContent = content
        originalMood = selectedMood
        // 新建模式的 pendingImages 已在后台 Task 处理，清空以避免 hasUnsavedChanges 误判
        pendingImages = []

        // 发送数据变更通知
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        onSave?()
        dismiss()
    }
}

// MARK: - Preview
#Preview {
    ThoughtEditorView()
}
