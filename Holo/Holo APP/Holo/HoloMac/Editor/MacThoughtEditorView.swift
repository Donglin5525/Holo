//
//  MacThoughtEditorView.swift
//  HoloMac
//
//  想法模块 Mac 编辑器主视图（Phase C+D）
//
//  与 iOS ThoughtEditorView 同一条保存管线：
//  - 保存全部走 ThoughtRepository+EditorCommit.commitEditorContent
//    （richContentJSON + 行内标签差异 + 引用全量对齐 + firstLine + organizedStatus），
//    不存在 Mac 私有写入口，iPhone/Mac 双向读写同一节点模型与同一 JSON；
//  - 草稿恢复复用 ThoughtEditorRecoveryStore（本机恢复日志，与 iOS 同一存储）；
//  - 图片附件走 AttachmentFileManager 压缩管线 + ThoughtRepository+Attachments
//    （新建会话先 staged 暂存、首次落库后转正，与 iOS 同口径）。
//  Mac 特有：心情选择（复用 ThoughtRepository.update 的 mood 通道）、
//  纸感样式选择（复用 ThoughtStylePicker）、macOS 文件选择器插图。
//  Phase E：接入「转为任务」（「…」菜单 → ThoughtTaskExtractionSheet 批量确认，
//  创建后经 .insertTaskMarks 写入任务关系标记，与 iOS 同管线）。
//  「…」菜单的「删除想法」与 iOS deleteCurrentThought 同链路：二次确认后软删
//  进 30 天回收站、清恢复记录、关闭编辑器；仅已落库会话显示。
//  本阶段不做：语音输入、相机、分享卡。
//

import SwiftUI
import CoreData
import os.log
import UniformTypeIdentifiers

// MARK: - 编辑请求（sheet(item:) 载荷）

/// 打开编辑器的请求：thoughtId == nil 表示新建会话
struct MacThoughtEditorRequest: Identifiable {
    let id = UUID()
    let thoughtId: UUID?
}

// MARK: - MacThoughtEditorView

struct MacThoughtEditorView: View {

    @Environment(\.dismiss) private var dismiss
    private let thoughtRepository = ThoughtRepository()

    /// 保存完成回调（刷新列表由 .thoughtDataDidChange 通知承担，这里供宿主联动选中）
    var onSave: (() -> Void)?
    /// 点 Token 菜单「查看标签」：切到该标签浏览范围（由工作台接）
    var onBrowseTag: ((String) -> Void)?
    /// 「…」菜单删除成功：宿主联动选中态（删除的正是右栏选中时收掉，由工作台接）
    var onDeleteThought: ((UUID) -> Void)?
    /// 编辑模式（传入已有想法 ID）
    let editingThoughtId: UUID?

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacThoughtEditor")

    init(
        editingThoughtId: UUID?,
        onSave: (() -> Void)? = nil,
        onBrowseTag: ((String) -> Void)? = nil,
        onDeleteThought: ((UUID) -> Void)? = nil
    ) {
        self.editingThoughtId = editingThoughtId
        self.onSave = onSave
        self.onBrowseTag = onBrowseTag
        self.onDeleteThought = onDeleteThought
    }

    // MARK: - 正文与元数据

    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var selectedStyle: ThoughtStyle = .plain
    @State private var styleNeedsSaving = false
    /// 心情（nil = 未设置；与 Thought.mood 同一存储值）
    @State private var selectedMood: ThoughtMoodType? = nil
    @State private var originalMoodRaw: String? = nil

    // MARK: - 结构化编辑状态（#/@ Token）

    @State private var triggerContext: EditorTriggerContext? = nil
    @State private var selectedToken: HoloContentNode? = nil
    @State private var tokenMenuRect: CGRect? = nil
    @State private var editorNodes: [HoloContentNode] = []
    @State private var editorNodesLoaded: Bool = false
    @State private var initialRichJSON: String? = nil
    @StateObject private var suggestionViewModel = SuggestionPanelViewModel()

    // MARK: - 编辑器 UI 状态

    @State private var pendingEditorAction: MarkdownEditorAction? = nil
    @State private var typingFormatState: TypingFormatState = TypingFormatState()
    @State private var caretRect: CGRect = .zero
    @State private var editorReloadToken = 0
    @State private var showStylePicker = false

    // MARK: - Mac 内联提示（HoloToastCenter 在 macOS 无 overlay window，不可见）

    @State private var statusMessage: String? = nil
    @State private var statusIsError = false
    @State private var statusDismissTask: Task<Void, Never>? = nil

    // MARK: - 自动保存 / 恢复日志（G1 保存可信，与 iOS 同机制）

    @State private var draftThoughtId: UUID? = nil
    @State private var autoSaveTask: Task<Void, Never>? = nil
    @State private var isComposingIME = false
    @State private var autoSaveDeferredByComposition = false
    @State private var didEnqueueAIClassification = false
    @State private var didCreateThoughtInSession = false
    @State private var sessionId = UUID()
    @State private var newSessionThoughtId: UUID? = nil
    @State private var recoveryTask: Task<Void, Never>? = nil
    @State private var recoverableDraft: ThoughtEditorRecoveryDraft? = nil
    @State private var finishAfterUploadCompletes = false

    // MARK: - 附件

    @State private var pendingImageItems: [MacPendingImageItem] = []
    @State private var isUploadingPendingImages = false
    @State private var editingAttachments: [ThoughtAttachmentGridItem] = []
    @State private var showImagePicker = false
    @State private var showAttachmentGallery = false
    @State private var galleryStartIndex = 0

    // MARK: - 转为任务（Phase E）

    /// 提取确认面板的参数（用 item 模式确保弹窗拿到的参数是一次性写好的、自洽的）
    @State private var taskExtractionRequest: MacTaskExtractionRequest? = nil

    // MARK: - 删除想法（「…」菜单，对齐 iOS deleteCurrentThought）

    /// 删除二次确认（文案与 iOS 编辑器同一口径）
    @State private var showDeleteConfirm = false
    /// 删除路径收口标志：onDisappear 兜底保存跳过，防止删除后凭内容重建一条
    @State private var didDeleteCurrentThought = false

    /// 最大可插入数量（已落库附件 + 暂存图共用 9 张上限，与 iOS 同口径）
    private var remainingAttachmentSlots: Int {
        max(0, 9 - editingAttachments.count - pendingImageItems.count)
    }

    private var currentThoughtId: UUID? { editingThoughtId ?? draftThoughtId }
    private var isEditing: Bool { currentThoughtId != nil }
    private var isComposingSession: Bool { editingThoughtId == nil }

    /// 是否有实质内容：文字非空或已有图片（纯图片想法同样合法）
    private var hasContent: Bool {
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingImageItems.isEmpty || !editingAttachments.isEmpty
    }

    private var currentThoughtObject: Thought? {
        guard let thoughtId = currentThoughtId else { return nil }
        return (try? thoughtRepository.fetchById(thoughtId))
            ?? (try? thoughtRepository.fetchByIdInternal(thoughtId))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if statusMessage != nil {
                statusBanner
            }
            recoveryBanner

            MacEditorFormatToolbar(
                onAction: { action in
                    pendingEditorAction = action
                },
                onPickImage: {
                    guard remainingAttachmentSlots > 0 else {
                        showStatus(String(localized: "最多添加 9 张图片"), isError: true)
                        return
                    }
                    showImagePicker = true
                },
                onDone: {
                    finishEditing()
                },
                isComposingSession: isComposingSession,
                formatState: typingFormatState,
                canDeleteThought: currentThoughtId != nil,
                onDeleteThought: {
                    showDeleteConfirm = true
                })

            editorPaper

            metadataBar
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(Color.holoToolBackground)
        .onAppear {
            loadEditingData()
            Task { await ThoughtEditorRecoveryStore.shared.cleanupOrphans() }
        }
        .onDisappear {
            // 兜底：退出时落库当前内容（防抖任务可能还没触发）
            autoSaveTask?.cancel()
            autoSaveTask = nil
            recoveryTask?.cancel()
            recoveryTask = nil
            // 删除动作走 deleteCurrentThought：不能让兜底保存凭内容把已删想法重建一条
            // （与 iOS 同口径）
            guard !didDeleteCurrentThought else { return }
            let outcome = persistContent(shouldDismiss: false, notifyDataChange: true)
            if case .failed = outcome {
                Task { @MainActor in await writeRecoverySnapshot() }
            }
        }
        .onChange(of: content) { _, newValue in
            guard newValue != originalContent else { return }
            scheduleAutoSave()
            scheduleRecoverySnapshot()
        }
        .onChange(of: pendingImageItems) { _, _ in
            scheduleAutoSave()
            scheduleRecoverySnapshot()
        }
        .onChange(of: triggerContext) { _, newValue in
            suggestionViewModel.search(context: newValue, excludingThoughtId: currentThoughtId)
        }
        .sheet(isPresented: $showStylePicker) {
            ThoughtStylePicker(
                style: selectedStyle,
                content: content,
                photoCount: editingAttachments.count + pendingImageItems.count,
                createdAt: currentThoughtObject?.createdAt ?? Date(),
                nodes: editorNodesLoaded ? editorNodes : nil,
                photos: paperPhotoSources
            ) { style in
                guard selectedStyle != style else { return }
                selectedStyle = style
                styleNeedsSaving = true
                scheduleAutoSave()
                scheduleRecoverySnapshot()
            }
        }
        .sheet(isPresented: $showAttachmentGallery) {
            if let thought = currentThoughtObject {
                ThoughtGalleryView(
                    attachments: thought.sortedAttachments,
                    startIndex: galleryStartIndex)
            }
        }
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                loadSelectedImageFiles(urls)
            case .failure(let error):
                Self.logger.error("选择图片失败：\(error.localizedDescription)")
            }
        }
        // 转为任务（Phase E）：批量提取确认面板（跨平台 sheet 直接宿主）
        .sheet(item: $taskExtractionRequest) { request in
            ThoughtTaskExtractionSheet(
                content: request.content,
                sourceThought: request.sourceThought,
                isFromSelection: request.isFromSelection,
                isAIExcluded: request.isAIExcluded,
                visibleSourceText: visibleEditorText(for: request.sourceThought),
                sourceRange: request.sourceRange,
                onDismiss: {
                    taskExtractionRequest = nil
                },
                onCreated: { createdTasks in
                    taskExtractionRequest = nil
                    // 每个任务都携带自己的来源范围：无法可靠映射的 AI 结果不强行
                    // 下划线，避免给用户错误关系暗示（与 iOS 同口径）
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
                })
                .frame(minWidth: 480, minHeight: 540)
        }
        // 删除想法二次确认（标题/按钮/正文与 iOS 编辑器 confirmationDialog 同一文案）
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
    }

    // MARK: - 纸面（编辑器主体）

    private var editorPaper: some View {
        ZStack {
            ThoughtStationeryBackground(style: selectedStyle)
            VStack(spacing: 0) {
                ThoughtPaperHeader(style: selectedStyle, date: currentThoughtObject?.createdAt ?? Date())
                MacRichTextEditor(
                    text: $content,
                    pendingAction: $pendingEditorAction,
                    formatState: $typingFormatState,
                    triggerContext: $triggerContext,
                    selectedToken: $selectedToken,
                    tokenMenuRect: $tokenMenuRect,
                    caretRect: $caretRect,
                    initialRichJSON: initialRichJSON,
                    autoFocus: !isEditing,
                    placeholder: String(localized: "写点什么吧…"),
                    reloadToken: editorReloadToken,
                    onNodesChange: { newNodes in
                        editorNodes = newNodes
                        editorNodesLoaded = true
                    },
                    onSuggestionCommand: handleSuggestionKeyboardCommand,
                    suggestionKeyboardEnabled: triggerContext != nil,
                    suggestionKeyboardHasItems: !suggestionViewModel.visibleItems.isEmpty,
                    onCompositionChange: handleCompositionChange,
                    onConvertToTask: { selectedText, selectedRange in
                        startTaskExtraction(selectedText: selectedText, selectedRange: selectedRange)
                    })
                // 候选浮层 + Token 操作菜单挂在纸面上（编辑器容器坐标）
                .overlay(alignment: .topLeading) {
                    suggestionOverlay
                }
                .overlay(alignment: .topLeading) {
                    tokenMenuOverlay
                }
                attachmentStrip
                if selectedStyle != .plain {
                    ThoughtPaperFooter(style: selectedStyle)
                }
            }
            .padding(.horizontal, selectedStyle == .plain
                ? HoloSpacing.lg
                : selectedStyle.textInset)
        }
        .background(selectedStyle.editorPaper)
        .frame(maxHeight: .infinity)
    }

    /// 编辑中图片缩略条（已落库附件 + 暂存图，删除/查看与 iOS 同交互）
    @ViewBuilder
    private var attachmentStrip: some View {
        if !paperPhotoSources.isEmpty {
            ThoughtEditorPaperPhotos(
                sources: paperPhotoSources,
                style: selectedStyle,
                onOpen: openPaperPhoto,
                onRemove: removePaperPhoto)
        }
    }

    // MARK: - 底部属性区（心情 / 样式）

    private var metadataBar: some View {
        HStack(spacing: HoloSpacing.md) {
            Label(String(localized: "心情"), systemImage: "face.smiling")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            HStack(spacing: 6) {
                moodChip(nil, label: String(localized: "无"))
                ForEach(ThoughtMoodType.allCases, id: \.self) { mood in
                    moodChip(mood, label: "\(mood.emoji) \(mood.displayName)")
                }
            }

            Spacer(minLength: HoloSpacing.md)

            Button {
                showStylePicker = true
            } label: {
                HStack(spacing: 5) {
                    ThoughtStyleSignature(style: selectedStyle)
                    Text(selectedStyle.title)
                        .font(.holoLabel)
                        .foregroundColor(.holoToolText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.holoToolInset)
                .cornerRadius(HoloRadius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .stroke(Color.holoToolBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "记录样式：\(selectedStyle.title)"))
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoToolSurface)
        .overlay(alignment: .top) {
            Color.holoToolBorder.opacity(0.5).frame(height: 0.5)
        }
    }

    private func moodChip(_ mood: ThoughtMoodType?, label: String) -> some View {
        let isSelected = (mood?.rawValue ?? "") == (selectedMood?.rawValue ?? "")
        return Button {
            selectedMood = mood
            scheduleAutoSave()
        } label: {
            Text(label)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoToolTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isSelected ? Color.holoPrimary : Color.holoToolInset))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mood.map { String(localized: "心情：\($0.displayName)") } ?? String(localized: "无心情"))
    }

    // MARK: - 状态提示（macOS 无全局 Toast 窗口，编辑器内联呈现）

    private var statusBanner: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: statusIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundColor(statusIsError ? Color.holoError : Color.holoSuccessText)
            Text(statusMessage ?? "")
                .holoText(.supporting)
                .foregroundColor(.holoToolText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 6)
        .background(statusIsError ? Color.holoError.opacity(0.08) : Color.holoSuccessText.opacity(0.08))
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            statusMessage = text
            statusIsError = isError
        }
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                statusMessage = nil
            }
        }
    }

    // MARK: - 恢复横幅（G1）

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
                .buttonStyle(.plain)
                Button {
                    discardRecoverableDraft(draft)
                } label: {
                    Text("丢弃")
                        .holoText(.body)
                        .foregroundColor(.holoError)
                }
                .buttonStyle(.plain)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoToolSurface)
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoToolBorder, lineWidth: 1))
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
        }
    }

    // MARK: - 候选浮层（复用 SuggestionPanelView，光标吸附）

    @ViewBuilder
    private var suggestionOverlay: some View {
        if let triggerContext {
            GeometryReader { proxy in
                let gap: CGFloat = 6
                let horizontalInset: CGFloat = 8
                let panelWidth: CGFloat = 280
                let availableBelow = max(0, proxy.size.height - caretRect.maxY - gap)
                let showBelow = availableBelow >= SuggestionPanelView.tagRowHeight * 2
                    || caretRect.minY < gap + SuggestionPanelView.tagRowHeight * 2
                let panelHeight = SuggestionPanelView.preferredHeight(
                    for: triggerContext,
                    itemCount: suggestionViewModel.visibleItems.count,
                    maxHeight: SuggestionPanelView.referenceRowHeight * 4)
                let rawY = showBelow
                    ? caretRect.maxY + gap
                    : caretRect.minY - panelHeight - gap
                let offsetY = max(horizontalInset, min(rawY, proxy.size.height - panelHeight - horizontalInset))
                let offsetX = min(
                    max(horizontalInset, caretRect.minX),
                    max(horizontalInset, proxy.size.width - panelWidth - horizontalInset))

                SuggestionPanelView(
                    context: triggerContext,
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
                    })
                .frame(width: panelWidth, alignment: .topLeading)
                .offset(x: offsetX, y: offsetY)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)).animation(.easeOut(duration: 0.14)),
                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
    }

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
        // displayText 契约是「不含 @ 前缀」的纯展示文字（makeTokenAttributedText 会补 @）
        pendingEditorAction = .insertReferenceToken(
            id: id,
            displayText: RichContentSerializer.normalizedReferenceDisplayText(
                displayText: title, snapshot: snapshot),
            snapshot: snapshot)
    }

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

    // MARK: - Token 操作菜单

    @ViewBuilder
    private var tokenMenuOverlay: some View {
        if let token = selectedToken, let rect = tokenMenuRect {
            VStack(alignment: .leading, spacing: 0) {
                Text(tokenMenuTitle(token))
                    .font(.holoLabel)
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                Divider()
                switch token {
                case .tag:
                    tokenMenuButton(String(localized: "复制标签"), icon: "doc.on.doc") {
                        MarkdownTextView.copyNodesToPasteboard([token])
                        selectedToken = nil
                    }
                    tokenMenuButton(String(localized: "查看标签"), icon: "tag") {
                        let displayPath: String
                        if case .tag(_, let path) = token { displayPath = path } else { displayPath = "" }
                        selectedToken = nil
                        viewTagThoughts(displayPath)
                    }
                    tokenMenuButton(String(localized: "移除标签"), icon: "trash", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .reference:
                    tokenMenuButton(String(localized: "复制引用"), icon: "doc.on.doc") {
                        MarkdownTextView.copyNodesToPasteboard([token])
                        selectedToken = nil
                    }
                    tokenMenuButton(String(localized: "取消引用"), icon: "link.badge.minus", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .taskMark:
                    tokenMenuButton(String(localized: "取消标记"), icon: "xmark.circle", isDestructive: true) {
                        selectedToken = nil
                        pendingEditorAction = .removeSelectedToken
                    }
                case .text:
                    EmptyView()
                }
            }
            .frame(minWidth: 160, alignment: .leading)
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoToolSurface)
                    .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoToolBorder, lineWidth: 0.5))
            .offset(x: rect.minX, y: rect.minY + rect.height + 4)
            .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
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

    private func tokenMenuButton(
        _ title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(title)
                    .holoText(.supporting)
                Spacer(minLength: 0)
            }
            .foregroundColor(isDestructive ? .holoError : .holoToolText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 查看标签：保存当前内容后切到该标签的浏览范围并关闭编辑器
    private func viewTagThoughts(_ path: String) {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        persistContent(shouldDismiss: false, notifyDataChange: false)
        onBrowseTag?(path)
        dismiss()
    }

    // MARK: - 自动保存

    /// 防抖自动保存：内容变化后停顿 2 秒落库一次；组字期间推迟到组字结束
    private func scheduleAutoSave() {
        guard !isComposingIME else {
            autoSaveDeferredByComposition = true
            return
        }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            persistContent(shouldDismiss: false, notifyDataChange: false)
        }
    }

    private func handleCompositionChange(_ composing: Bool) {
        isComposingIME = composing
        guard !composing, autoSaveDeferredByComposition else { return }
        autoSaveDeferredByComposition = false
        scheduleAutoSave()
    }

    private enum SaveOutcome: Equatable {
        case saved(UUID)
        case nothingToSave
        case failed
    }

    /// 核心持久化：与 iOS persistContent 同一条链路
    /// - richContentJSON 的写入条件与 iOS 完全一致：结构化内容（Token 或格式）存在才写，
    ///   纯文本想法保持 richContentJSON == nil（iPhone 卡片回退显示 content）
    @discardableResult
    private func persistContent(shouldDismiss: Bool, notifyDataChange: Bool) -> SaveOutcome {
        // 无文字且无图片
        if !hasContent {
            guard !isUploadingPendingImages else { return .nothingToSave }
            if let thoughtId = currentThoughtId {
                // 清空已落库想法是合法编辑：落库空正文，不硬删除
                do {
                    _ = try thoughtRepository.commitEditorContent(
                        thoughtId: thoughtId,
                        content: "",
                        inlineTags: [],
                        richContentJSON: .some(nil),
                        references: [],
                        style: styleNeedsSaving ? selectedStyle : nil,
                        createIfMissing: false)
                    styleNeedsSaving = false
                    applyMoodChangeIfAny(thoughtId: thoughtId)
                    clearRecoveryRecordAfterCommit()
                    if notifyDataChange {
                        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                        onSave?()
                    }
                    if shouldDismiss { dismiss() }
                    return .saved(thoughtId)
                } catch {
                    Self.logger.error("清空想法保存失败：\(error.localizedDescription)")
                    if notifyDataChange {
                        showStatus(String(localized: "保存失败，请重试"), isError: true)
                    }
                    return .failed
                }
            }
            // 从未落库的新空会话：不创建空记录，直接收口
            if shouldDismiss { dismiss() }
            return .nothingToSave
        }

        let nodes = editorNodesLoaded
            ? editorNodes
            : RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: content)
        // 结构化内容包括颜色、粗体、斜体和下划线；只按 Token 判断会把纯格式想法
        // 退回 content 字符串路径，下次编辑无法共享同一份可恢复事实源
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

        // 新建会话的稳定草稿 ID 首次落库前固定，保存重试永远复用同一 ID
        if editingThoughtId == nil, newSessionThoughtId == nil {
            newSessionThoughtId = UUID()
        }
        let commitThoughtId = currentThoughtId ?? newSessionThoughtId!
        let createIfMissing = editingThoughtId == nil

        let persistedThoughtId: UUID
        do {
            let receipt = try thoughtRepository.commitEditorContent(
                thoughtId: commitThoughtId,
                content: content,
                inlineTags: inlineTags,
                richContentJSON: .some(richJSON),
                references: referenceSnapshots,
                style: styleNeedsSaving ? selectedStyle : nil,
                createIfMissing: createIfMissing)
            persistedThoughtId = receipt.thoughtId
            if currentThoughtId == nil {
                draftThoughtId = receipt.thoughtId
                didCreateThoughtInSession = true
                // AI 自动分类：每个草稿仅首次创建时触发一次（与 iOS 同口径）
                if !didEnqueueAIClassification,
                   ThoughtAIClassificationPolicy.isEnabled(), content.count >= 10 {
                    didEnqueueAIClassification = true
                    Task { @MainActor in
                        ThoughtOrganizationQueue.shared.enqueue(thoughtId: receipt.thoughtId)
                    }
                }
            }
            applyMoodChangeIfAny(thoughtId: persistedThoughtId)

            // 离开编辑器（notifyDataChange=true）且正文已变 → commit 已回 pending，重新排队整理
            if notifyDataChange, originalContent != content,
               let updated = try? thoughtRepository.fetchById(persistedThoughtId),
               updated.organizedStatus == "pending" {
                Task { @MainActor in
                    ThoughtOrganizationQueue.shared.enqueue(thoughtId: persistedThoughtId)
                }
            }
        } catch {
            Self.logger.error("自动保存失败：\(error.localizedDescription)")
            if notifyDataChange {
                showStatus(String(localized: "保存失败，继续编辑会自动重试"), isError: true)
            }
            return .failed
        }

        clearRecoveryRecordAfterCommit()

        // 暂存图转正（新建首次落库后 / 失败重试共用一条路径）
        if !pendingImageItems.isEmpty, !isUploadingPendingImages,
           pendingImageItems.contains(where: { $0.retryCount < 3 }) {
            startPendingImageUpload()
        }

        originalContent = content
        styleNeedsSaving = false

        if notifyDataChange {
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            onSave?()
            if didCreateThoughtInSession {
                didCreateThoughtInSession = false
                showStatus(String(localized: "已记录"), isError: false)
            }
        }

        if shouldDismiss {
            dismiss()
        }
        return .saved(persistedThoughtId)
    }

    /// 心情写入：复用 ThoughtRepository.update 的 mood 通道（commit 管线不承载心情字段）。
    /// 只在用户改动过时写一次，避免自动保存反复刷新 updatedAt。
    private func applyMoodChangeIfAny(thoughtId: UUID) {
        guard selectedMood?.rawValue != originalMoodRaw else { return }
        do {
            if let mood = selectedMood {
                _ = try thoughtRepository.update(thoughtId, mood: mood.rawValue)
            } else {
                _ = try thoughtRepository.update(thoughtId, mood: "")
            }
            originalMoodRaw = selectedMood?.rawValue
        } catch {
            Self.logger.error("保存心情失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 转为任务（Phase E，与 iOS startTaskExtraction 同管线）

    /// 触发「转为任务」：先落库（含草稿首次创建），再弹确认面板。
    /// 整篇转化（selectedText=nil）和选中文字转化共用此入口。
    private func startTaskExtraction(selectedText: String? = nil, selectedRange: NSRange? = nil) {
        guard hasContent else { return }
        // 转任务是用户主动动作：先冲刷防抖中的自动保存，保证面板拿到最新正文
        autoSaveTask?.cancel()
        autoSaveTask = nil
        guard case .saved(let thoughtId) = persistContent(shouldDismiss: false, notifyDataChange: false),
              let thought = try? thoughtRepository.fetchById(thoughtId) else {
            showStatus(String(localized: "保存未完成，暂时无法转为任务"), isError: true)
            return
        }
        // 一次性构建完整请求，避免 sheet 闭包分两步读状态导致拿到中间态
        taskExtractionRequest = MacTaskExtractionRequest(
            content: selectedText ?? thought.content,
            sourceThought: thought,
            isFromSelection: selectedText != nil,
            isAIExcluded: ThoughtAIAudience.isExcluded(thought),
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
        // 任务关系附件在 attributed string 中占一个 U+FFFC，但不属于正文，
        // 不能参与整篇任务的偏移计算（与 iOS visibleEditorText 同注释口径）
        return MarkdownTextView.visiblePlainText(from: nodes)
    }

    /// 删除当前想法：软删进 30 天回收站后关闭编辑器（与 iOS deleteCurrentThought 同链路）。
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
            Self.logger.error("删除想法失败：\(error.localizedDescription)")
            didDeleteCurrentThought = false
            return
        }
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        onDeleteThought?(thoughtId)
        dismiss()
    }

    /// 「完成」主动作：先落库并核对附件，成功才关闭；失败留在页面
    private func finishEditing() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if isUploadingPendingImages {
            finishAfterUploadCompletes = true
            return
        }
        if !pendingImageItems.isEmpty {
            finishAfterUploadCompletes = true
            startPendingImageUpload()
            return
        }
        let outcome = persistContent(shouldDismiss: false, notifyDataChange: true)
        if outcome != .failed {
            dismiss()
        }
    }

    // MARK: - 恢复日志

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
            updatedAt: Date(),
            styleRaw: selectedStyle.rawValue)
        await ThoughtEditorRecoveryStore.shared.save(draft)
    }

    private func clearRecoveryRecordAfterCommit() {
        guard pendingImageItems.isEmpty else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        let sid = sessionId
        Task { await ThoughtEditorRecoveryStore.shared.clear(sessionId: sid) }
    }

    private func restoreRecoverableDraft(_ draft: ThoughtEditorRecoveryDraft) {
        recoverableDraft = nil
        content = draft.content
        originalContent = draft.content
        if let styleRaw = draft.styleRaw {
            selectedStyle = ThoughtStyle(storedValue: styleRaw)
            styleNeedsSaving = true
        }
        if draft.richContentJSON != nil {
            initialRichJSON = draft.richContentJSON
        }
        editorNodesLoaded = false
        editorReloadToken += 1
        // 旧记录由当前会话接管身份（staged 图片保留给新记录引用）
        let oldSessionId = draft.sessionId
        Task { await ThoughtEditorRecoveryStore.shared.clear(sessionId: oldSessionId) }
        Task { @MainActor in
            var restored: [MacPendingImageItem] = []
            for file in draft.stagedImageFiles {
                if let data = await ThoughtEditorRecoveryStore.shared.stagedImageData(file),
                   let image = UIImage(data: data) {
                    let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 1024)
                    if let preview {
                        restored.append(MacPendingImageItem(data: data, preview: preview, stagedFileName: file))
                        continue
                    }
                }
                await ThoughtEditorRecoveryStore.shared.removeStagedImage(file)
            }
            pendingImageItems.append(contentsOf: restored)
            scheduleRecoverySnapshot()
        }
    }

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

    // MARK: - 暂存图转正（与 iOS startPendingImageUpload 同链路）

    private func startPendingImageUpload() {
        let retryable = pendingImageItems.filter { $0.retryCount < 3 }
        guard !retryable.isEmpty,
              let thoughtId = currentThoughtId,
              let thought = try? thoughtRepository.fetchById(thoughtId) else {
            if finishAfterUploadCompletes {
                finishAfterUploadCompletes = false
                if !pendingImageItems.isEmpty {
                    showStatus(String(localized: "图片保存失败，请重试或删除后再退出"), isError: true)
                }
            }
            return
        }
        pendingImageItems = []
        isUploadingPendingImages = true
        Task { @MainActor in
            var failed: [MacPendingImageItem] = []
            for var item in retryable {
                do {
                    _ = try await thoughtRepository.addAttachment(imageData: item.data, to: thought, sourceType: "filePicker")
                    if let staged = item.stagedFileName {
                        await ThoughtEditorRecoveryStore.shared.removeStagedImage(staged)
                        item.stagedFileName = nil
                    }
                } catch {
                    Self.logger.error("保存图片失败：\(error.localizedDescription)")
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
                showStatus(
                    failed.allSatisfy { $0.retryCount >= 3 }
                        ? String(localized: "图片保存失败，请重试或删除后再退出")
                        : String(localized: "有 \(failed.count) 张图片未保存成功，稍后自动重试"),
                    isError: true)
            }
            if finishAfterUploadCompletes {
                finishAfterUploadCompletes = false
                if pendingImageItems.isEmpty {
                    finishEditing()
                } else {
                    showStatus(String(localized: "图片尚未保存成功，请重试或删除后再退出"), isError: true)
                }
            }
        }
    }

    // MARK: - 加载编辑数据

    /// onAppear 可重入标志：macOS 14 SwiftUI 的 onAppear 会在同一视图上二次触发
    /// （IME 自检 harness 实测复现）。loadEditingData 会整体重写
    /// content / initialRichJSON / selectedStyle——编辑会话中途重跑等于用打开时
    /// 快照回滚宿主状态，是组字事故的帮凶；一个会话只允许加载一次。
    @State private var didLoadEditingData = false

    private func loadEditingData() {
        guard !didLoadEditingData else { return }
        didLoadEditingData = true
        guard let thoughtId = editingThoughtId else {
            // 新建会话查孤儿草稿（从未落库就被杀的会话）
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
            guard let thought = try repo.fetchById(thoughtId) ?? repo.fetchByIdInternal(thoughtId) else {
                return
            }
            content = thought.content
            initialRichJSON = thought.richContentJSON
            selectedStyle = thought.appearanceStyle
            selectedMood = ThoughtMoodType(from: thought.mood)
            originalMoodRaw = thought.mood
            originalContent = thought.content
            editingAttachments = thought.sortedAttachments.map { attachment in
                ThoughtAttachmentGridItem(
                    id: attachment.id,
                    objectID: attachment.objectID,
                    thumbnailFileName: attachment.thumbnailFileName,
                    thumbnailData: attachment.thumbnailData)
            }
            // 查该想法的未提交修改：恢复记录比实体新才提示
            let entityUpdatedAt = thought.updatedAt
            Task { @MainActor in
                let drafts = await ThoughtEditorRecoveryStore.shared.drafts(forThoughtId: thoughtId)
                guard let latest = drafts.first,
                      latest.updatedAt > entityUpdatedAt,
                      content == thought.content else { return }
                recoverableDraft = latest
            }
        } catch {
            Self.logger.error("加载编辑数据失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 图片附件

    /// 展示层快照（与 iOS paperPhotoSources 同口径）
    private var paperPhotoSources: [ThoughtPaperPhotoSource] {
        let saved = editingAttachments.map {
            ThoughtPaperPhotoSource(
                id: $0.id,
                thumbnailData: $0.thumbnailData,
                fileName: $0.thumbnailFileName,
                thoughtId: currentThoughtId)
        }
        let pending = pendingImageItems.map {
            ThoughtPaperPhotoSource(
                id: $0.id,
                image: $0.preview,
                status: $0.retryCount > 0 ? .failed : .ready)
        }
        return saved + pending
    }

    /// 文件选择器回调：编辑会话直接转正；新建会话 staged 落盘进暂存条
    private func loadSelectedImageFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            var loaded: [(Data, UIImage)] = []
            for url in urls {
                // 沙盒外文件需要安全作用域访问；fileImporter 给出的 URL 按此约定读取
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart { url.stopAccessingSecurityScopedResource() }
                }
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else { continue }
                // macOS 压缩管线在转正时统一执行（processRawImageData），此处仅取展示预览
                let preview = (await AttachmentFileManager.previewImageInBackground(
                    image, maxDimension: 1024)) ?? image
                loaded.append((data, preview))
            }
            guard !loaded.isEmpty else {
                showStatus(String(localized: "无法读取所选图片"), isError: true)
                return
            }

            if let thoughtId = currentThoughtId,
               let thought = try? thoughtRepository.fetchById(thoughtId) {
                // 已落库：直接转正（与 iOS 编辑会话插图同链路）
                var successCount = 0
                for (data, _) in loaded {
                    do {
                        _ = try await thoughtRepository.addAttachment(imageData: data, to: thought, sourceType: "filePicker")
                        successCount += 1
                    } catch {
                        Self.logger.error("添加附件失败：\(error.localizedDescription)")
                    }
                }
                refreshEditingAttachments()
                if successCount < loaded.count {
                    showStatus(String(localized: "有 \(loaded.count - successCount) 张图片未保存成功"), isError: true)
                }
            } else {
                // 未落库：staged 文件先行落盘 + 暂存条展示（与 iOS 新建会话同口径）
                for (data, preview) in loaded {
                    let stagedName = UUID().uuidString + ".jpg"
                    await ThoughtEditorRecoveryStore.shared.writeStagedImage(data, fileName: stagedName)
                    pendingImageItems.append(
                        MacPendingImageItem(data: data, preview: preview, stagedFileName: stagedName))
                }
            }
        }
    }

    private func openPaperPhoto(_ id: UUID) {
        if let index = editingAttachments.firstIndex(where: { $0.id == id }) {
            galleryStartIndex = index
            showAttachmentGallery = true
        } else if let item = pendingImageItems.first(where: { $0.id == id }), item.retryCount > 0 {
            retryPendingImage(item)
        }
    }

    private func removePaperPhoto(_ id: UUID) {
        if let item = editingAttachments.first(where: { $0.id == id }) {
            deleteEditingAttachment(item.objectID)
        } else if let item = pendingImageItems.first(where: { $0.id == id }) {
            removePendingImage(item)
        }
    }

    private func removePendingImage(_ item: MacPendingImageItem) {
        pendingImageItems.removeAll { $0.id == item.id }
        if let staged = item.stagedFileName {
            Task { await ThoughtEditorRecoveryStore.shared.removeStagedImage(staged) }
        }
    }

    private func retryPendingImage(_ item: MacPendingImageItem) {
        guard let index = pendingImageItems.firstIndex(where: { $0.id == item.id }) else { return }
        pendingImageItems[index].retryCount = 0
        if !isUploadingPendingImages {
            startPendingImageUpload()
        }
    }

    private func refreshEditingAttachments() {
        guard let thoughtId = currentThoughtId else { return }
        let thought = (try? thoughtRepository.fetchById(thoughtId))
            ?? (try? thoughtRepository.fetchByIdInternal(thoughtId))
        guard let thought else { return }
        editingAttachments = thought.sortedAttachments.map { attachment in
            ThoughtAttachmentGridItem(
                id: attachment.id,
                objectID: attachment.objectID,
                thumbnailFileName: attachment.thumbnailFileName,
                thumbnailData: attachment.thumbnailData)
        }
    }

    private func deleteEditingAttachment(_ objectID: NSManagedObjectID) {
        do {
            try thoughtRepository.deleteAttachment(with: objectID)
            refreshEditingAttachments()
        } catch {
            Self.logger.error("删除附件失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - MacTaskExtractionRequest

/// 转任务面板所需参数（content + sourceThought 一次性确定，避免 sheet 闭包读到中间态；
/// 与 iOS ThoughtEditorView.TaskExtractionRequest 同结构）
private struct MacTaskExtractionRequest: Identifiable {
    let id = UUID()
    let content: String
    let sourceThought: Thought
    let isFromSelection: Bool
    let isAIExcluded: Bool
    let sourceRange: NSRange?
}

// MARK: - MacPendingImageItem

/// 暂存图（Mac）：data 是持久化来源，preview 仅用于缩略条展示；
/// stagedFileName 指向本机恢复目录的原图副本（落库失败不丢原图）。
/// iOS 版 PendingImageItem 定义在 UIKit 守卫内，Mac 端按同一字段重新声明。
private struct MacPendingImageItem: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let preview: UIImage
    var stagedFileName: String?
    var retryCount: Int = 0

    init(data: Data, preview: UIImage, stagedFileName: String? = nil) {
        self.data = data
        self.preview = preview
        self.stagedFileName = stagedFileName
    }

    static func == (lhs: MacPendingImageItem, rhs: MacPendingImageItem) -> Bool {
        lhs.id == rhs.id
    }
}
