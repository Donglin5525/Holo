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
    /// 所属主题的查询与修改（本页就近使用，与主仓储同上下文）
    private let topicRepository = TopicRepository()
    /// 从主列表以全屏详情打开时显示关闭按钮；从编辑器的导航栈进入时保留系统返回按钮。
    var showsDismissButton: Bool = false
    /// 从卡片「待确认」徽章进入时滚动到 AI 归纳确认区（长笔记确认位在首屏之外）
    var focusAIConfirmation: Bool = false

    /// 滚动锚点：AI 归纳确认区
    private enum DetailScrollAnchor {
        static let aiSummary = "aiSummarySection"
    }

    /// 当前想法
    @State private var thought: Thought? = nil

    /// 数据加载是否已完成（完成后 thought 仍为 nil 说明想法已被删除/清除）
    @State private var hasLoadedData: Bool = false

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

    /// 分享卡面板
    @State private var showShareCard: Bool = false

    /// AI 标签分配
    @State private var aiAssignments: [ThoughtTagAssignment] = []
    /// P0 分级判定：用户认可标签集合（归一化 key）
    @State private var recognizedTagKeys: Set<String> = []
    /// P0 重新整理节流（防连点重复入队消耗配额）
    @State private var retryInFlight: Bool = false

    /// 所属主题修改入口（TopicPickerView）
    @State private var showTopicPicker: Bool = false

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
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                        // 目标想法已被删除/清除时的占位提示
                        if thought == nil && hasLoadedData {
                            deletedThoughtPlaceholder
                        }

                        // 内容区域
                        if thought != nil {
                            contentSection
                        }

                        // AI 归纳（三区合一：主题 + 标签 + 理由放一个区块——
                        // 它们本来就是同一次 AI 调用的产出，不再让用户自己拼图）
                        if thought != nil {
                            aiSummarySection
                                .id(DetailScrollAnchor.aiSummary)
                        }

                        // 整理失败：人话原因 + 一键重试（独立于 AI 归纳区，红色轻提示）
                        if thought?.organizedStatus == "failed" {
                            organizationFailedSection
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
                .onChange(of: hasLoadedData) { _, loaded in
                    scrollToConfirmationIfRequested(loaded, proxy: proxy)
                }
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
                        .accessibilityLabel(String(localized: "关闭详情"))
                        .buttonStyle(.plain)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showShareCard = true
                        } label: {
                            Label("生成分享卡", systemImage: "square.and.arrow.up")
                        }

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

                        // FR-05′：单条重新整理（failed/已整理均可；skipped 短文本无意义不显示）
                        if canRetryOrganization {
                            Button {
                                retryOrganization()
                            } label: {
                                Label("重新整理", systemImage: "arrow.clockwise")
                            }
                            .disabled(retryInFlight)
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
            .sheet(isPresented: $showShareCard) {
                if let thought {
                    ThoughtShareSheet(thought: thought)
                }
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
                .holoContentColumn()
            }
            .fullScreenCover(isPresented: $showAttachmentGallery) {
                if let thought = thought {
                    ThoughtGalleryView(
                        attachments: thought.sortedAttachments,
                        startIndex: galleryStartIndex
                    )
                }
            }
            .sheet(isPresented: $showTopicPicker, onDismiss: {
                loadData()
            }) {
                TopicPickerView(
                    thoughtId: thoughtId,
                    topicRepository: topicRepository,
                    onAssigned: {
                        ThoughtClassificationFeedbackStore.log(
                            .topicChange, thoughtId: thoughtId, tagName: "",
                            topicConfidence: thought?.topicConfidence
                        )
                        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                    },
                    allowsRemove: true
                )
            }
            .onAppear {
                loadData()
            }
            }
        }
        // 全屏详情形态（showsDismissButton=true）补边缘右滑返回；编辑器导航栈形态保留系统返回。
        // 条件挂载：holoEdgeSwipeBack 无让位逻辑，与系统手势并存会双重 pop。
        .holoEdgeSwipeBack(isEnabled: showsDismissButton) { dismiss() }
    }

    // MARK: - 数据加载

    /// 从「待确认」徽章进入时滚到 AI 归纳区（数据就绪、区块已渲染后才有效）
    private func scrollToConfirmationIfRequested(_ loaded: Bool, proxy: ScrollViewProxy) {
        guard loaded, focusAIConfirmation else { return }
        // 等本帧布局完成再滚，否则 scrollTo 找不到锚点
        DispatchQueue.main.async {
            proxy.scrollTo(DetailScrollAnchor.aiSummary, anchor: .top)
        }
    }

    private func loadData() {
        do {
            thought = try thoughtRepository.fetchById(thoughtId)
            references = try thoughtRepository.getReferences(for: thoughtId)
            referencedBy = try thoughtRepository.getReferencedBy(id: thoughtId)
            aiAssignments = (try? thoughtRepository.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []
            // P0 分级判定输入：用户认可标签集合（归一化 key）
            recognizedTagKeys = Set(thoughtRepository.fetchUserRecognizedTagNames()
                .map { ThoughtTagNormalizer.key($0) })
            loadRenderNodes()
        } catch {
            logger.error("加载数据失败：\(error)")
        }
        hasLoadedData = true
    }

    /// 想法已被删除/清除时的占位视图
    private var deletedThoughtPlaceholder: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "trash.slash")
                .font(.system(size: 32))
                .foregroundColor(.holoTextSecondary)
            Text("该想法已被删除")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
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

    // MARK: - AI 归纳（三区合一：主题 + 标签 + 理由）

    /// 是否还有未确认的 AI 建议（决定标题轻提示）
    private var hasUnconfirmedAISuggestions: Bool {
        aiAssignments.contains { $0.source == ThoughtTagAssignment.Source.ai.rawValue }
    }

    /// 一次 AI 调用的产出放一个区块：主题一行、标签一行（你的彩色 + AI 建议灰色内联 ✓✗）、理由一句。
    /// 确认即毕业：确认后的标签立即出现在彩色池，AI 角标与按钮消失，不留残影。
    private var aiSummarySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text(hasUnconfirmedAISuggestions ? String(localized: "AI 归纳 · 待你确认") : String(localized: "AI 归纳"))
                    .font(.holoCaption)
                    .fontWeight(.semibold)
            }
            .foregroundColor(hasUnconfirmedAISuggestions ? .holoAI : .holoTextSecondary)

            topicRow

            Divider()
                .overlay(Color.holoDivider)

            if let thought = thought,
               !thought.recognizedTagNames.isEmpty || hasUnconfirmedAISuggestions {
                tagRows
            } else if thought?.organizedStatus == "organized" {
                // 正常空分类：不是失败，轻文案
                Text("这条想法还没有形成稳定方向，可以先放着。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.8))
            }

            // 理由永远显示（含未归类时的「为什么不归类」）；手动归档/短内容无理由则安静
            if let reason = thought?.topicAssignmentReason, !reason.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundColor(.holoAI)
                        .padding(.top, 2)
                    Text(reason)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// 主题行：有主题展示归属（点击更换），无主题为「未归类 + 选择主题」
    @ViewBuilder
    private var topicRow: some View {
        if let topic = thought?.classificationTopic {
            let color = Color.topicPalette(for: topic.title)
            Button {
                showTopicPicker = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Text(TopicIconProvider.icon(for: topic))
                        .font(.system(size: 17))

                    Text(topic.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Text("更换 ›")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
                .padding(HoloSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(color.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(color.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        } else {
            Button {
                showTopicPicker = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 15))
                        .foregroundColor(.holoTextSecondary)

                    Text("未归类")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Text("选择主题 ›")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
                .padding(HoloSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(Color.holoTextSecondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// 标签行：认可标签（彩色，点击跳筛选）+ 未确认 AI 建议（灰色 + AI 角标 + ✓✗）
    private var tagRows: some View {
        FlowLayout(spacing: HoloSpacing.sm) {
            // 彩色池 = 自己打的 + 确认过 AI 建议的（同身份折叠，确认即毕业到此）
            ForEach(thought?.recognizedTagNames ?? [], id: \.self) { tagName in
                TagChip(
                    // 展示叶段名（路径是存储结构，不进 UI 文案）
                    text: "#\(ThoughtTagNormalizer.lastSegment(tagName))",
                    isSelected: true,
                    color: thought?.tagArray.first {
                        ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key(tagName)
                    }?.tagColor ?? .holoPrimary
                ) {
                    // 与正文 # 标签 token 同一行为：跳列表按该标签筛选
                    NotificationCenter.default.post(name: .thoughtRequestTagFilter, object: tagName)
                    dismiss()
                }
            }
            // 灰池 = 仅未确认建议（确认后即从这消失，毕业为上面的彩色池）
            ForEach(
                aiAssignments.filter { $0.source == ThoughtTagAssignment.Source.ai.rawValue },
                id: \.id
            ) { assignment in
                aiTagChip(assignment)
            }
        }
    }

    // MARK: - 整理失败（人话原因 + 一键重试）

    private var organizationFailedSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Label("整理失败", systemImage: "exclamationmark.triangle.fill")
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(.holoError)
            HStack(spacing: HoloSpacing.sm) {
                Text("网络不稳定，这条想法还没整理好。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    retryOrganization()
                } label: {
                    Text("重新整理 ›")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
                .disabled(retryInFlight)
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoError.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - AI 标签 Chip（带操作按钮）

    private func aiTagChip(_ assignment: ThoughtTagAssignment) -> some View {
        let tagName = assignment.tag?.name ?? ""
        let isConfirmed = assignment.source == ThoughtTagAssignment.Source.confirmedAI.rawValue

        return HStack(spacing: 4) {
            // AI 归类展示完整主题路径（#碎碎念/加班），与列表卡片口径一致
            Text("#\(ThoughtTagNormalizer.displayPath(tagName))")
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
                    ThoughtClassificationFeedbackStore.log(
                        .confirm, thoughtId: thoughtId, tagName: tagName,
                        topicConfidence: thought?.topicConfidence
                    )
                    loadData()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "保留标签 \(ThoughtTagNormalizer.displayPath(tagName))"))

                // FR-06′：× 默认仅本条不适合，不写全局抑制
                Button {
                    let service = ThoughtOrganizationService()
                    service.rejectAssignmentCurrentOnly(assignmentId: assignment.id)
                    ThoughtClassificationFeedbackStore.log(
                        .rejectCurrent, thoughtId: thoughtId, tagName: tagName,
                        topicConfidence: thought?.topicConfidence
                    )
                    loadData()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "不适合这条 \(ThoughtTagNormalizer.displayPath(tagName))"))
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
        // FR-06′：全局抑制是更高影响操作，放长按菜单（90 天内不再推荐）
        .contextMenu {
            if !isConfirmed {
                Button(role: .destructive) {
                    let service = ThoughtOrganizationService()
                    service.rejectAndRecord(assignmentId: assignment.id, tagName: tagName)
                    ThoughtClassificationFeedbackStore.log(
                        .suppressGlobal, thoughtId: thoughtId, tagName: tagName,
                        topicConfidence: thought?.topicConfidence
                    )
                    loadData()
                } label: {
                    Label("以后不要推荐 #\(ThoughtTagNormalizer.displayPath(tagName))", systemImage: "hand.raised")
                }
            }
        }
    }

    // MARK: - 重新整理（FR-05′）

    /// skipped（<10 字）重试无意义不显示；failed / organized / disabled 均可手动重整
    private var canRetryOrganization: Bool {
        guard let status = thought?.organizedStatus else { return false }
        return status != "skipped" && status != "pending" && status != "processing"
    }

    private func retryOrganization() {
        guard !retryInFlight else { return }
        retryInFlight = true
        defer { retryInFlight = false }

        do {
            try thoughtRepository.updateOrganizedStatus(thoughtId: thoughtId, status: "pending")
        } catch {
            logger.error("重置整理状态失败：\(error)")
            return
        }
        ThoughtClassificationFeedbackStore.log(
            .retry, thoughtId: thoughtId, tagName: "",
            topicConfidence: thought?.topicConfidence
        )
        // 状态先置 pending 再入队；旧 ai 建议保留展示，新结果写入时自然替换（方案 L-3）
        ThoughtOrganizationQueue.shared.enqueueManual(thoughtId: thoughtId)
        loadData()
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
                        Text("#\(ThoughtTagNormalizer.lastSegment(tag.name))")
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
        .accessibilityHint(onTap == nil ? "" : String(localized: "双击打开想法"))
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
