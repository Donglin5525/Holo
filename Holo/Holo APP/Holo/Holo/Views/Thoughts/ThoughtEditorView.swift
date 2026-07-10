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
    @State private var selectedTags: [String] = []
    @State private var referencedThoughtIds: [UUID] = []

    /// AI 归类标签（只读回显，不参与编辑保存；来自 fetchVisibleAIAssignments）
    @State private var aiAssignments: [ThoughtTagAssignment] = []

    // MARK: - Original Values (for change detection)
    @State private var originalContent: String = ""
    @State private var originalMood: ThoughtMoodType? = nil
    @State private var originalTags: [String] = []
    @State private var originalReferencedThoughtIds: [UUID] = []

    // MARK: - UI State
    @State private var showTagInput: Bool = false
    @State private var showReferenceSelector: Bool = false
    @State private var showVoiceInput: Bool = false
    @State private var isSaving: Bool = false
    @State private var showDismissAlert: Bool = false
    @State private var pendingEditorAction: MarkdownEditorAction? = nil
    @State private var pendingVoiceTranscriptToInsert: String? = nil
    @State private var editorHeight: CGFloat = 360
    @State private var typingFormatState: TypingFormatState = TypingFormatState()
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
                    // 内容编辑区
                    contentSection
                    // 标签区域
                    tagsSection
                    // AI 归类区域（只读回显）
                    if !aiAssignments.isEmpty {
                        aiTagsSection
                    }
                    // 引用区域
                    referencesSection
                }
                .padding(.horizontal, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle(isEditing ? "编辑想法" : "记录想法")
            .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showTagInput) {
            TagInputView(selectedTags: $selectedTags)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showReferenceSelector) {
            ReferenceSelectorView(selectedIds: $referencedThoughtIds)
                .presentationDetents([.large])
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

    /// 处理取消/右滑退出
    private func handleDismiss() {
        if hasContent && hasUnsavedChanges {
            // 有内容且有修改时自动保存
            saveThought()
        } else {
            // 无内容或无修改时直接退出
            dismiss()
        }
    }

    // MARK: - 未保存修改检测

    /// 是否有未保存的修改
    private var hasUnsavedChanges: Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = originalContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // 内容发生变化
        if trimmedContent != trimmedOriginal {
            return true
        }

        // 标签发生变化
        if Set(selectedTags) != Set(originalTags) {
            return true
        }

        // 引用发生变化
        if Set(referencedThoughtIds) != Set(originalReferencedThoughtIds) {
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
                        textContainerInset: UIEdgeInsets(top: 22, left: 16, bottom: 88, right: 16)
                    )
                        .frame(height: max(editorHeight, contentEditorMinimumHeight))

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
            RichTextToolbarView(pendingAction: $pendingEditorAction, formatState: typingFormatState, onAddImage: {
                showAttachmentSourceChoice = true
            })
        }
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

    /// 标签区域
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    showTagInput = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
            }

            if selectedTags.isEmpty {
                Text("点击 + 添加标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedTags, id: \.self) { tag in
                            TagChip(
                                text: "#\(tag)",
                                isSelected: true,
                                color: .holoPrimary
                            ) {
                                removeTag(tag)
                            }
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

    /// 引用区域
    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("引用")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    showReferenceSelector = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
            }

            if referencedThoughtIds.isEmpty {
                Text("点击 + 引用其他想法")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            } else {
                Text("已引用 \(referencedThoughtIds.count) 条想法")
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
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
            selectedTags = thought.tagArray.map { $0.name }
            referencedThoughtIds = (thought.references as? Set<ThoughtReference>)?.compactMap { $0.targetThought?.id } ?? []
            // AI 归类标签只读回显（不写入 selectedTags，避免被 update 当作手动标签误处理）
            aiAssignments = (try? repo.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []

            // 设置原始值（用于比较是否有修改）
            originalContent = thought.content
            originalMood = ThoughtMoodType(from: thought.mood)
            originalTags = thought.tagArray.map { $0.name }
            originalReferencedThoughtIds = (thought.references as? Set<ThoughtReference>)?.compactMap { $0.targetThought?.id } ?? []

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

    /// 移除标签
    private func removeTag(_ tag: String) {
        selectedTags.removeAll { $0 == tag }
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

        // 分离手动标签与内联 # 标签（不再合并后传入，保留来源信息）
        let inlineTags = InlineTagDetector.extractTags(from: content)

        do {
            if isEditing, let thoughtId = editingThoughtId {
                // 编辑模式：更新已有想法（仍用合并标签，保留旧 UI 兼容）
                let allTags = Array(Set(selectedTags + inlineTags))
                try repository.update(
                    thoughtId,
                    content: content,
                    mood: selectedMood?.rawValue,
                    tags: allTags
                )
            } else {
                // 新建模式：分别传入 manualTags 和 inlineTags
                let thought = try repository.create(
                    content: content,
                    mood: selectedMood?.rawValue,
                    manualTags: selectedTags,
                    inlineTags: inlineTags
                )
                // 添加引用关系
                for targetId in referencedThoughtIds {
                    try repository.addReference(sourceId: thought.id, targetId: targetId)
                }

                // 保存待上传图片（后台逐张处理）
                if !pendingImages.isEmpty {
                    Task { @MainActor in
                        for image in pendingImages {
                            guard let jpegData = image.jpegData(compressionQuality: 0.85) else { continue }
                            _ = try? await repository.addAttachment(imageData: jpegData, to: thought)
                        }
                    }
                }

                // AI 自动整理：新想法保存后触发（仅新建，编辑不触发）
                let isEnabled = UserDefaults.standard.object(forKey: ThoughtRepository.autoOrganizationEnabledKey) as? Bool ?? true
                if isEnabled && content.count >= 10 {
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
