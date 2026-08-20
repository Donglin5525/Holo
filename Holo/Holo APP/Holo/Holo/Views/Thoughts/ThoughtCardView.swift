//
//  ThoughtCardView.swift
//  Holo
//
//  观点模块 - 想法卡片组件
//  显示单条想法的预览信息
//

import SwiftUI
import CoreData

// MARK: - ThoughtCardView

/// 想法卡片视图
/// 设计参考：
/// - 白色背景，圆角 28pt
/// - 顶部：日期 + 状态
/// - 中间：内容预览（2-3 行）
/// - 底部：标签 + 引用数
struct ThoughtCardView: View {

    // MARK: - Properties

    let thought: Thought
    var onNavigate: (() -> Void)?
    /// 双击正文直接进入编辑器；单击仍保留阅读详情入口。
    var onEdit: (() -> Void)?
    var onTagTap: ((String) -> Void)?
    /// 更多操作：移入主题（可选，由列表页接主题选择器）
    var onMoveToTopic: (() -> Void)?
    /// 更多操作：归档（可选）
    var onArchive: (() -> Void)?
    /// 更多操作：删除（可选）
    var onDelete: (() -> Void)?
    /// 归档操作显示文案（默认「归档」，归档视图下传「恢复」）
    var archiveActionTitle: String = "归档"
    /// P0 分级判定输入：用户认可标签集合（归一化 key）。
    /// 列表主入口传入；其他低频调用点不传时降级为「有 ai 标签即待确认」。
    var recognizedTagKeys: Set<String>? = nil

    /// 操作菜单是否展示
    @State private var showActionSheet = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶部：日期 + 状态
            headerView

            // 中间：内容预览
            contentView

            // 底部：标签 + 引用信息
            footerView
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
                .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        // 双击命中整张卡片，短文下方的留白也能直接进入编辑器；单击详情仍只由正文区域处理。
        // 必须用 onTapGesture：highPriorityGesture 会抢先拦截子视图（「…」按钮、标签 chip）的单击，
        // 导致这些按钮点按无反应（SwiftUI 手势竞争中子视图应优先）。
        .onTapGesture(count: 2) { onEdit?() }
    }

    // MARK: - 顶部区域

    private var headerView: some View {
        HStack(spacing: 8) {
            // 日期
            Text(thought.formattedDate)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            statusBadge

            // 更多操作按钮（仅当至少有一个可用操作时才展示）
            if hasAvailableActions {
                Button {
                    HapticManager.light()
                    showActionSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多操作")
                // 用独立 Button 隔断父卡片的打开手势；点菜单不能同时进入编辑器。
                .confirmationDialog("操作", isPresented: $showActionSheet, titleVisibility: .visible) {
                        if let onMoveToTopic {
                            Button("移入主题") { onMoveToTopic() }
                        }
                        if let onArchive {
                            Button(archiveActionTitle, role: nil) { onArchive() }
                        }
                        if let onDelete {
                            Button("删除", role: .destructive) { onDelete() }
                        }
                        Button("取消", role: .cancel) {}
                    }
            }
        }
    }

    /// 是否存在至少一个可用的更多操作
    private var hasAvailableActions: Bool {
        onMoveToTopic != nil || onArchive != nil || onDelete != nil
    }

    private var statusBadge: some View {
        let status = organizationDisplayStatus
        return HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(status.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.1))
        .clipShape(Capsule())
    }

    private var organizationDisplayStatus: (title: String, icon: String, color: Color) {
        if thought.hasActiveTopic {
            return ("已入主题", "folder.fill", .holoSuccess)
        }
        if thought.organizedStatus == "processing" || thought.organizedStatus == "pending" {
            return ("整理中", "sparkles", .holoPrimary)
        }
        // P0「等待确认」：含新标签或低置信主题，中性色不算失败（D-07′，规则集中在 Policy）
        if showsPendingConfirmation {
            return ("等待确认", "questionmark.circle", .holoTextSecondary)
        }
        if thought.organizedStatus == "failed" {
            return ("整理失败", "exclamationmark.circle.fill", .holoError)
        }
        if !thought.visibleAITagNames.isEmpty {
            return ("已整理", "checkmark.seal.fill", .holoPrimary)
        }
        if thought.organizedStatus == "organized" {
            return ("未归类", "circle.dashed", .holoTextSecondary)
        }
        return ("待整理", "circle.dotted", .holoTextSecondary)
    }

    /// 卡片层待确认判定：优先用精确认可集合（D-07′ 新标签语义），降级为「有 ai 标签」
    private var showsPendingConfirmation: Bool {
        guard thought.organizedStatus == "organized" else { return false }
        if let recognizedTagKeys {
            return ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: thought.organizedStatus,
                hasPendingTagConfirmation: ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                    hasAITagAssignments: !thought.visibleAITagNames.isEmpty,
                    aiTagNames: thought.visibleAITagNames,
                    recognizedTagKeys: recognizedTagKeys
                ) == .pendingConfirmation,
                topicConfidence: thought.topicConfidence
            )
        }
        // 降级：无认可集合时以「存在 ai 标签或低置信主题」近似
        let lowConfidenceTopic = thought.topicConfidence > 0
            && thought.topicConfidence < ThoughtRepository.topicConfirmationThreshold
        return !thought.visibleAITagNames.isEmpty || lowConfidenceTopic
    }

    // MARK: - 内容区域

    private var contentView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 所有卡片内容都走结构化阅读管线；没有 rich JSON 的存量纯文本也先转成 text/tag
            // 节点，避免列表外层重新走一套 Text/ExpandableText，导致 Markdown、空行和行距漂移。
            // 长文只在列表做预览，但通过同一套排版测量明确提示“点击查看全文”。
            ReadOnlyRichTextPreview(
                nodes: contentNodes,
                lineLimit: 7
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !thought.sortedAttachments.isEmpty {
                inlineAttachmentsView
            }
        }
        // 只读 UITextView 在卡片内不接管触摸，因此不能把“不可交互”泄漏成
        // VoiceOver 的 disabled 元素。卡片正文本身是进入想法的主入口，显式暴露
        // 同一份语义文本和按钮动作；底部标签仍保留各自的筛选操作。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("想法内容")
        .accessibilityValue(MarkdownTextView.accessibilityText(from: contentNodes))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("单击查看详情，双击直接编辑")
        // 正文区域自带双击声明：双击时 SwiftUI 会先等双击窗口、不再触发下面的单击进详情，
        // 保证「双击正文直接编辑」与「单击正文进详情」在同一区域共存。
        .onTapGesture(count: 2) { onEdit?() }
        .onTapGesture {
            onNavigate?()
        }
        .accessibilityAction {
            onNavigate?()
        }
        .accessibilityAction(named: "直接编辑") {
            onEdit?()
        }
    }

    /// 富文本结构化事实源；存量纯文本也通过同一入口转换，保证列表与详情/编辑器同源。
    private var contentNodes: [HoloContentNode] {
        RichContentSerializer.nodes(
            richJSON: thought.richContentJSON,
            fallbackPlainText: thought.content
        )
    }

    // MARK: - 底部区域

    private var footerView: some View {
        HStack(spacing: 0) {
            let tags = thought.tagArray
            let aiTagNames = thought.visibleAITagNames
            // PRD AC-05：卡片最多展示 3 个标签（手动 ≤2 + AI ≤1），超出以 +N 提示
            let presentation = ThoughtTagPresentation.card(
                manualNames: tags.map(\.name),
                aiNames: aiTagNames,
                manualLimit: 2,
                aiLimit: 1
            )

            if !presentation.isEmpty {
                // 用户标签与 AI 标签同时展示，同名标签只展示一次。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presentation.manualNames, id: \.self) { tagName in
                            if let tag = tags.first(where: {
                                ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key(tagName)
                            }) {
                                tagChip(tag)
                            }
                        }
                        ForEach(presentation.aiNames, id: \.self) { tagName in
                            aiTagChip(tagName)
                        }
                        if presentation.hiddenCount > 0 {
                            Text("+\(presentation.hiddenCount)")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            } else if thought.organizedStatus == "processing" {
                // 正在整理
                Text("AI 正在整理...")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            // 引用信息
            let refCount = thought.referenceCount + thought.referencedByCount
            if refCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                    Text("\(refCount)")
                        .font(.holoLabel)
                }
                .foregroundColor(.holoPrimary)
            }
        }
    }

    private var inlineAttachmentsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                ForEach(Array(thought.sortedAttachments.enumerated()), id: \.element.id) { _, attachment in
                    ThoughtAttachmentThumbnailView(
                        thumbnailData: attachment.thumbnailData,
                        fileName: attachment.thumbnailFileName,
                        thoughtId: thought.id
                    )
                    .frame(width: 80, height: 80)
                }
            }
        }
    }

    // MARK: - 标签 Chip

    private func tagChip(_ tag: ThoughtTag) -> some View {
        Button {
            onTagTap?(tag.name)
        } label: {
            // 展示叶段名（路径是存储结构，不进 UI 文案）；筛选仍用完整路径
            Text("#\(ThoughtTagNormalizer.lastSegment(tag.name))")
                .font(.holoLabel)
                .foregroundColor(tag.tagColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tag.tagColor.opacity(0.1))
                .cornerRadius(HoloRadius.sm)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("按标签 \(tag.name) 筛选")
    }

    // MARK: - AI 标签 Chip（灰色调 + AI 角标）

    private func aiTagChip(_ tagName: String) -> some View {
        Button {
            onTagTap?(tagName)
        } label: {
            HStack(spacing: 3) {
                // AI 归类展示完整主题路径（#碎碎念/加班），让「归到了哪」一眼可见；筛选仍用原始路径
                Text("#\(ThoughtTagNormalizer.displayPath(tagName))")
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
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("按 AI 标签 \(tagName) 筛选")
    }
}

// MARK: - Preview

#Preview("想法卡片") {
    VStack(spacing: 16) {
        Text("预览需要 Core Data context")
            .font(.holoBody)
            .foregroundColor(.holoTextSecondary)
    }
    .padding()
    .background(Color.holoBackground)
}
