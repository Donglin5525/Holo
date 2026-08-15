//
//  ThoughtDetailView.swift
//  Holo
//
//  观点模块 - 想法详情页
//  展示想法完整内容、引用关系和反向链接
//

import SwiftUI
import CoreData
import os.log

// MARK: - ThoughtDetailView

/// 想法详情视图
struct ThoughtDetailView: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtDetailView")

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    let thoughtId: UUID
    let thoughtRepository: ThoughtRepository
    /// 从主列表以全屏详情打开时显示关闭按钮；从编辑器的导航栈进入时保留系统返回按钮。
    var showsDismissButton: Bool = false

    /// 当前想法
    @State private var thought: Thought? = nil

    /// 该想法引用的其他想法
    @State private var references: [Thought] = []

    /// 引用该想法的其他想法
    @State private var referencedBy: [Thought] = []

    /// 选中的引用想法 ID（用于跳转）
    @State private var selectedReferenceId: UUID? = nil

    /// 是否显示编辑 sheet
    @State private var showEditSheet: Bool = false

    /// 是否显示全屏图片浏览
    @State private var showAttachmentGallery: Bool = false
    @State private var galleryStartIndex: Int = 0

    /// 转为任务：弹确认面板（AI 提炼 / 手动勾选），不直接建任务
    @State private var showTaskExtraction: Bool = false

    /// AI 标签分配
    @State private var aiAssignments: [ThoughtTagAssignment] = []

    /// 阅读态渲染节点（richContentJSON 非空时使用）
    @State private var renderNodes: [HoloContentNode] = []

    /// 目标已删除的引用 ID 集合（灰色「原记录已删除」样式）
    @State private var deletedReferenceIds: Set<UUID> = []

    /// 已删除引用的快照（点击灰色引用时展示）
    @State private var deletedSnapshot: String? = nil

    private var deletedSnapshotPresented: Binding<Bool> {
        Binding(
            get: { deletedSnapshot != nil },
            set: { if !$0 { deletedSnapshot = nil } }
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    // 内容区域
                    contentSection

                    // 标签区域
                    if let thought = thought, !thought.tagArray.isEmpty {
                        tagsSection
                    }

                    // AI 归类区域
                    if !aiAssignments.isEmpty {
                        aiTagsSection
                    }

                    // 引用区域（该想法引用的其他想法）
                    if !references.isEmpty {
                        referencesSection
                    }

                    // 反向链接区域（引用该想法的其他想法）
                    if !referencedBy.isEmpty {
                        referencedBySection
                    }

                    // 底部间距
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("想法详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("关闭详情")
                        .buttonStyle(.plain)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showTaskExtraction = true
                        } label: {
                            Label("转为任务", systemImage: "checkmark.square")
                        }

                        Button {
                            showEditSheet = true
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
            }
            .sheet(item: $selectedReferenceId) { refId in
                ThoughtDetailSheetView(
                    thoughtId: refId,
                    thoughtRepository: thoughtRepository
                )
            }
            .alert("原记录已删除", isPresented: deletedSnapshotPresented) {
                Button("知道了", role: .cancel) {
                    deletedSnapshot = nil
                }
            } message: {
                Text(deletedSnapshot ?? "")
            }
            .sheet(isPresented: $showTaskExtraction) {
                if let thought = thought {
                    let sourceNodes = renderNodes.isEmpty
                        ? RichContentSerializer.nodes(fromPlainText: thought.content)
                        : renderNodes
                    ThoughtTaskExtractionSheet(
                        content: thought.content,
                        sourceThought: thought,
                        isFromSelection: false,
                        visibleSourceText: MarkdownTextView.visiblePlainText(from: sourceNodes),
                        onDismiss: { showTaskExtraction = false },
                        onCreated: { createdTasks in
                            applyCreatedTasks(createdTasks, to: thought)
                            showTaskExtraction = false
                            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                        }
                    )
                }
            }
            // fullScreenCover：编辑器作为完整页面承载，避免 sheet 下滑误触丢内容
            .fullScreenCover(isPresented: $showEditSheet) {
                ThoughtEditorView(
                    onSave: {
                        loadData()
                    },
                    editingThoughtId: thoughtId
                )
            }
            .fullScreenCover(isPresented: $showAttachmentGallery) {
                if let thought = thought {
                    ThoughtGalleryView(
                        attachments: thought.sortedAttachments,
                        startIndex: galleryStartIndex
                    )
                }
            }
            .onAppear {
                loadData()
            }
        }
    }

    // MARK: - 数据加载

    private func loadData() {
        do {
            thought = try thoughtRepository.fetchById(thoughtId)
            references = try thoughtRepository.getReferences(for: thoughtId)
            referencedBy = try thoughtRepository.getReferencedBy(id: thoughtId)
            aiAssignments = (try? thoughtRepository.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []
            loadRenderNodes()
        } catch {
            logger.error("加载数据失败：\(error)")
        }
    }

    /// 解析结构化内容并检测已删除的引用目标
    private func loadRenderNodes() {
        guard let thought, thought.richContentJSON != nil else {
            renderNodes = []
            deletedReferenceIds = []
            return
        }

        let nodes = RichContentSerializer.nodes(richJSON: thought.richContentJSON, fallbackPlainText: thought.content)
        renderNodes = nodes

        var deleted: Set<UUID> = []
        for node in nodes {
            if case .reference(let noteId, _, _) = node,
               (try? thoughtRepository.fetchById(noteId)) == nil {
                deleted.insert(noteId)
            }
        }
        deletedReferenceIds = deleted
    }

    /// 阅读态 Token 点击：标签 → 请求列表筛选；引用 → 打开目标；已删除 → 展示快照；任务标记 → 跳转任务
    private func handleTokenTap(_ node: HoloContentNode) {
        switch node {
        case .tag(_, let displayPath):
            NotificationCenter.default.post(name: .thoughtRequestTagFilter, object: displayPath)
            dismiss()
        case .reference(let noteId, _, let snapshot):
            if deletedReferenceIds.contains(noteId) {
                deletedSnapshot = snapshot
            } else {
                selectedReferenceId = noteId
            }
        case .taskMark(_, let taskId, _, _):
            DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
            dismiss()
        case .text:
            break
        }
    }

    /// 详情页转任务也必须把任务关系写回正文，保证下划线和编辑器入口一致。
    private func applyCreatedTasks(_ tasks: [CreatedThoughtTask], to thought: Thought) {
        let sourceNodes = renderNodes.isEmpty
            ? RichContentSerializer.nodes(fromPlainText: thought.content)
            : renderNodes
        let insertions = tasks.compactMap { task -> TaskMarkInsertion? in
            guard let sourceRange = task.sourceRange else { return nil }
            return TaskMarkInsertion(
                taskId: task.id,
                displayText: task.title,
                sourceRange: sourceRange
            )
        }
        guard let markedText = MarkdownTextView.attributedTextByInsertingTaskMarks(
            insertions,
            into: MarkdownTextView.makeAttributedText(from: sourceNodes)
        ) else {
            loadData()
            return
        }

        let markedNodes = MarkdownTextView.serializeNodes(from: markedText)
        guard let richJSON = try? RichContentSerializer.jsonString(from: markedNodes) else {
            loadData()
            return
        }

        do {
            _ = try thoughtRepository.update(
                thought.id,
                // content 是编辑源文本，必须保留 Markdown 标记；visiblePlainText 只用于
                // 阅读、复制和任务来源匹配，不能拿来覆盖用户下一次编辑要恢复的格式。
                content: RichContentSerializer.plainText(from: markedNodes),
                richContentJSON: .some(richJSON)
            )
        } catch {
            logger.error("详情页任务关系保存失败：\(error.localizedDescription)")
        }
        loadData()
    }

    // MARK: - 转为任务
    // 详情页转任务入口改为弹出 ThoughtTaskExtractionSheet 确认面板，
    // 与编辑器入口统一，不再直接建任务。

    // MARK: - 内容区域

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 日期
            HStack {
                Spacer()

                Text(thought?.formattedDate ?? "")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 内容统一走结构化阅读管线：即使是存量纯文本，也先转成 text/tag 节点，
            // 与编辑器共用字号、行距、Markdown 和空行语义，避免详情页另起一套渲染规则。
            let contentNodes = detailRenderNodes
            if !contentNodes.isEmpty {
                ReadOnlyRichTextView(
                    nodes: contentNodes,
                    deletedReferenceIds: deletedReferenceIds,
                    onTokenTap: handleTokenTap
                )
            } else {
                Text("")
                    .font(.body)
            }

            if let thought = thought, !thought.sortedAttachments.isEmpty {
                inlineAttachmentsSection
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    /// 结构化内容是事实源；没有 rich JSON 的存量想法也通过同一阅读组件渲染。
    private var detailRenderNodes: [HoloContentNode] {
        if !renderNodes.isEmpty {
            return renderNodes
        }
        guard let content = thought?.content, !content.isEmpty else { return [] }
        return RichContentSerializer.nodes(fromPlainText: content)
    }

    // MARK: - 图片附件区域

    private var inlineAttachmentsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    if let attachments = thought?.sortedAttachments {
                        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                            ThoughtAttachmentThumbnailView(
                                thumbnailData: attachment.thumbnailData,
                                fileName: attachment.thumbnailFileName,
                                thoughtId: thoughtId
                            )
                            .frame(width: 80, height: 80)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                galleryStartIndex = index
                                showAttachmentGallery = true
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 标签区域

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(thought?.tagArray ?? []) { tag in
                    TagChip(
                        text: "#\(tag.name)",
                        isSelected: true,
                        color: tag.tagColor
                    ) {
                        // 无操作
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - AI 归类区域

    private var aiTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("AI 归类")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }

            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(aiAssignments, id: \.id) { assignment in
                    aiTagChip(assignment)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - AI 标签 Chip（带操作按钮）

    private func aiTagChip(_ assignment: ThoughtTagAssignment) -> some View {
        let tagName = assignment.tag?.name ?? ""
        let isConfirmed = assignment.source == ThoughtTagAssignment.Source.confirmedAI.rawValue

        return HStack(spacing: 4) {
            Text("#\(tagName)")
                .font(.holoLabel)
                .foregroundColor(isConfirmed ? .holoPrimary : .holoTextSecondary)

            // AI 角标
            Text("AI")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(isConfirmed ? .holoPrimary.opacity(0.6) : .holoTextSecondary.opacity(0.5))

            // 确认按钮（保留 AI 标签）
            if !isConfirmed {
                Button {
                    let service = ThoughtOrganizationService()
                    service.confirmAssignment(assignmentId: assignment.id)
                    loadData()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                }

                // 拒绝按钮（删除 AI 标签）
                Button {
                    guard let tagName = assignment.tag?.name else { return }
                    let service = ThoughtOrganizationService()
                    service.rejectAndRecord(assignmentId: assignment.id, tagName: tagName)
                    loadData()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red.opacity(0.7))
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
    }

    // MARK: - 引用区域

    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("引用")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: HoloSpacing.sm) {
                ForEach(references) { ref in
                    ReferenceCardView(thought: ref) {
                        selectedReferenceId = ref.id
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - 反向链接区域

    private var referencedBySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("被引用")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "link.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimary)
            }

            VStack(spacing: HoloSpacing.sm) {
                ForEach(referencedBy) { ref in
                    ReferenceCardView(thought: ref) {
                        selectedReferenceId = ref.id
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }
}

private struct ThoughtDetailSheetView: View {
    let thoughtId: UUID
    let thoughtRepository: ThoughtRepository

    var body: some View {
        ThoughtDetailView(
            thoughtId: thoughtId,
            thoughtRepository: thoughtRepository,
            showsDismissButton: true
        )
    }
}

// MARK: - ReferenceCardView

/// 引用卡片组件
struct ReferenceCardView: View {
    let thought: Thought
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部：日期
            HStack {
                Text(thought.formattedDate)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
            }

            // 内容预览也走正文富文本管线，保证关系卡片里的 Markdown、@ 引用、任务标记
            // 与详情正文/列表卡片使用同一字号、行距和 Token 展示逻辑。
            ReadOnlyRichTextView(
                nodes: contentNodes,
                onTokenTap: { _ in },
                lineLimit: 2,
                allowsTokenInteraction: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // 标签
            if !thought.tagArray.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(thought.tagArray.prefix(3)) { tag in
                        Text("#\(tag.name)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(tag.tagColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tag.tagColor.opacity(0.1))
                            .cornerRadius(HoloRadius.sm)
                    }
                }
            }
        }
        .padding(HoloSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
        .accessibilityHint(onTap == nil ? "" : "双击打开想法")
        .accessibilityAction {
            onTap?()
        }
    }

    private var contentNodes: [HoloContentNode] {
        RichContentSerializer.nodes(
            richJSON: thought.richContentJSON,
            fallbackPlainText: thought.content
        )
    }
}

// MARK: - Preview

#Preview {
    // 需要 Core Data 环境
    Text("ThoughtDetailView Preview")
}
