//
//  MacThoughtDetailView.swift
//  HoloMac
//
//  三栏工作台 · 右栏：选中想法的只读详情（Mac 专属）
//
//  正文走 ReadOnlyRichTextView（richContentJSON 优先 / content 纯文本回退，
//  与 ThoughtCardView 同一调用口径）；标签/心情/纸感样式/附件缩略图复用
//  想法模块既有组件与样式枚举；引用关系列「引用 / 被引用」对（点击联动跳转）。
//  头部操作区：编辑 + 归档/移出归档 + 删除（删除 destructive + 二次确认，
//  软删进 30 天回收站；写库与选中态联动由工作台统一承担，与 iOS 同口径）。
//  AI 整理（Phase E）：「AI 归类」单条确认区（ThoughtTagAssignment 的
//  confirmedAI/rejectedAI 状态流，交互对齐 iOS 编辑器 AI 归类确认区）+
//  「你之前也写过」语义召回（ThoughtRelatedSection，含「不相关」反馈）。
//

import SwiftUI
import CoreData

struct MacThoughtDetailView: View {

    /// 选中想法 id（nil = 引导位）
    let thoughtId: UUID?
    /// 中栏当前列表（先命中内存，未命中再查库——引用跳转可跨范围）
    let listThoughts: [Thought]
    /// 点引用对端想法：联动切右栏（由工作台接）
    let onOpenThought: (UUID) -> Void
    /// 点「编辑」：打开编辑器（由工作台接；Phase C）
    var onEditThought: (UUID) -> Void = { _ in }
    /// 点「归档/移出归档」：写库与选中态联动由工作台统一承担
    var onArchiveThought: (Thought) -> Void = { _ in }
    /// 点「删除」并经二次确认后：由工作台软删（与 iOS 同口径）
    var onDeleteThought: (Thought) -> Void = { _ in }
    /// 点标签 chip：切到该标签的浏览范围（由工作台接）
    let onTagTap: (String) -> Void

    private let thoughtRepository = ThoughtRepository()

    /// 解析后的当前想法（NSManagedObject 活对象，字段变更自动反映）
    @State private var thought: Thought?
    @State private var emojiDisplayTick = 0

    // AI 归类确认区（Phase E）：当前想法的可展示 AI 标签分配（只读回显 + 确认/拒绝）
    @State private var aiAssignments: [ThoughtTagAssignment] = []

    // 附件大图浏览（复用编辑器/卡片同一交互与组件）
    @State private var showAttachmentGallery = false
    @State private var galleryStartIndex = 0

    // 删除二次确认（文案与 iOS 编辑器/列表删除确认同一口径）
    @State private var showDeleteConfirm = false

    var body: some View {
        Group {
            if let thought {
                detailContent(thought)
            } else {
                placeholderView
            }
        }
        .background(Color.holoToolBackground)
        .task(id: thoughtId) {
            resolveThought()
            refreshAIAssignments()
        }
        .onReceive(NotificationCenter.default.publisher(for: ThoughtTagEmojiStore.didChangeNotification)) { _ in
            emojiDisplayTick &+= 1
        }
        // AI 整理结果落库 / 归并应用后刷新确认区（幂等）
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            refreshAIAssignments()
        }
        // 删除二次确认（标题/按钮/正文与 iOS 编辑器删除确认同一文案）
        .confirmationDialog(
            "删除这条想法？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let current = thought {
                    onDeleteThought(current)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 单条删除已建批次进回收站（2026-09-06 拍板），30 天内可在最近删除自助恢复
            Text(String(localized: "删除后将进入回收站并保留 30 天，可在「设置 → 数据管理 → 最近删除」中恢复。"))
        }
    }

    // MARK: - 解析

    /// 中栏列表优先；跨范围引用跳转查库（fetchById 过滤归档，
    /// 兜底 fetchByIdInternal 保证被引用的归档想法仍可读）
    private func resolveThought() {
        guard let thoughtId else {
            thought = nil
            return
        }
        if let cached = listThoughts.first(where: { $0.id == thoughtId }) {
            thought = cached
            return
        }
        thought = (try? thoughtRepository.fetchById(thoughtId))
            ?? (try? thoughtRepository.fetchByIdInternal(thoughtId))
    }

    // MARK: - 引导位

    private var placeholderView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 30))
                .foregroundColor(.holoTextPlaceholder)
            Text("选择一条想法")
                .holoText(.body)
                .foregroundColor(.holoToolTextSecondary)
            Text("在中间列表轻点卡片，在这里阅读全文、标签、附件与引用")
                .holoText(.supporting)
                .foregroundColor(.holoTextPlaceholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 详情

    private func detailContent(_ thought: Thought) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                headerSection(thought)
                bodySection(thought)
                aiClassificationSection(thought)
                tagSection(thought)
                attachmentSection(thought)
                referenceSection(thought)
                relatedSection(thought)
                metaSection(thought)
            }
            .padding(HoloSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAttachmentGallery) {
            ThoughtGalleryView(
                attachments: thought.sortedAttachments,
                startIndex: galleryStartIndex)
        }
    }

    /// 顶部：日期 + 纸感样式签名 + 样式名 + 心情
    private func headerSection(_ thought: Thought) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ThoughtStyleSignature(style: thought.appearanceStyle)

            VStack(alignment: .leading, spacing: 2) {
                Text(thought.formattedDate)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
                Text(thought.appearanceStyle.title)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer()

            // Phase C：右栏直达编辑（保存后本详情经托管对象自动刷新）
            Button {
                onEditThought(thought.id)
            } label: {
                Label(String(localized: "编辑"), systemImage: "pencil")
                    .font(.holoLabel)
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.holoToolSurface)
                    .cornerRadius(HoloRadius.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .stroke(Color.holoToolBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.thought.editButton")

            // 归档/移出归档（iOS 列表左滑的对位；文案按归档态切换）
            Button {
                onArchiveThought(thought)
            } label: {
                Label(
                    thought.isArchived
                        ? String(localized: "移出归档")
                        : String(localized: "归档"),
                    systemImage: "archivebox")
                    .font(.holoLabel)
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.holoToolSurface)
                    .cornerRadius(HoloRadius.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .stroke(Color.holoToolBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.thought.archiveButton")

            // 删除：destructive + 二次确认，软删进 30 天回收站（与 iOS 同口径）
            Button {
                showDeleteConfirm = true
            } label: {
                Label(String(localized: "删除"), systemImage: "trash")
                    .font(.holoLabel)
                    .foregroundColor(Color.holoError)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.holoToolSurface)
                    .cornerRadius(HoloRadius.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .stroke(Color.holoToolBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.thought.deleteButton")

            if thought.isArchived {
                Label(String(localized: "已归档"), systemImage: "archivebox")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.holoToolInset)
                    .cornerRadius(HoloRadius.sm)
            }

            if let mood = thought.moodType {
                HStack(spacing: 4) {
                    Text(mood.emoji)
                    Text(mood.displayName)
                }
                .holoText(.metadata)
                .foregroundColor(mood.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(mood.color.opacity(0.1))
                .clipShape(Capsule())
            }
        }
    }

    /// 正文：结构化阅读管线全文渲染（无行数上限）
    private func bodySection(_ thought: Thought) -> some View {
        ReadOnlyRichTextView(
            nodes: RichContentSerializer.nodes(
                richJSON: thought.richContentJSON,
                fallbackPlainText: thought.content),
            deletedReferenceIds: deletedNoteIds(thought),
            onTokenTap: { _ in },
            lineLimit: nil,
            presentationStyle: thought.appearanceStyle)
    }

    // MARK: - 标签

    /// 标签 chips（与卡片同口径：认可标签彩 chip + AI 标签灰 chip，点击切范围）
    @ViewBuilder
    private func tagSection(_ thought: Thought) -> some View {
        let recognizedTagNames = thought.recognizedTagNames
        let aiTagNames = ThoughtSemanticFeatureFlags.uiEnabled ? [] : thought.visibleAITagNames
        if !recognizedTagNames.isEmpty || !aiTagNames.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                sectionLabel(String(localized: "标签"), systemImage: "tag")
                FlowingChips {
                    ForEach(recognizedTagNames, id: \.self) { name in
                        // 颜色信息存在 ThoughtTag 上，按名称回查兼容镜像（同卡片）
                        let tag = thought.tagArray.first {
                            ThoughtTagNormalizer.sharesIdentity($0.name, name)
                        }
                        tagChip(
                            name: name,
                            color: tag?.tagColor ?? .holoPrimary,
                            isAI: false)
                    }
                    ForEach(aiTagNames, id: \.self) { name in
                        tagChip(name: name, color: .holoToolTextSecondary, isAI: true)
                    }
                }
            }
        }
    }

    private func tagChip(name: String, color: Color, isAI: Bool) -> some View {
        Button {
            onTagTap(name)
        } label: {
            HStack(spacing: 3) {
                if let emoji = ThoughtTagEmojiStore.emoji(forKey: name) {
                    Text(emoji)
                        .font(.system(size: 11))
                }
                Text("#\(ThoughtTagNormalizer.lastSegment(name))")
                if isAI {
                    Text("AI")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .holoText(.metadata)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.08))
            .cornerRadius(HoloRadius.sm)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "按标签 \(name) 浏览"))
    }

    // MARK: - AI 归类（单条确认，Phase E）

    /// AI 建议标签回显 + 保留/拒绝（数据通道与交互对齐 iOS 编辑器 AI 归类确认区：
    /// fetchVisibleAIAssignments 只读回显；确认走 confirmAssignment（ai→confirmedAI），
    /// 拒绝走 rejectAssignmentCurrentOnly（仅本条 → rejectedAI），全局抑制放右键菜单）
    @ViewBuilder
    private func aiClassificationSection(_ thought: Thought) -> some View {
        if !aiAssignments.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack(spacing: 4) {
                    sectionLabel(String(localized: "AI 归类"), systemImage: "sparkles")
                    Text(String(localized: "保留合适的，拒绝不合适的"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
                FlowingChips {
                    ForEach(aiAssignments, id: \.id) { assignment in
                        aiAssignmentChip(assignment, thoughtId: thought.id)
                    }
                }
            }
        }
    }

    /// AI 标签 chip：未确认时提供保留/拒绝操作（与 iOS 编辑器 aiTagChip 同交互）
    private func aiAssignmentChip(_ assignment: ThoughtTagAssignment, thoughtId: UUID) -> some View {
        let tagName = assignment.tag?.name ?? ""
        let isConfirmed = assignment.source == ThoughtTagAssignment.Source.confirmedAI.rawValue

        return HStack(spacing: 4) {
            // AI 归类展示归一化后的完整主题路径（#碎碎念/加班），与列表/编辑器口径一致
            Text("#\(ThoughtTagNormalizer.displayPath(tagName))")
                .holoText(.metadata)
                .foregroundColor(isConfirmed ? .holoPrimary : .holoToolTextSecondary)

            Text("AI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isConfirmed ? .holoToolWarning : .holoToolTextSecondary)

            if !isConfirmed {
                Button {
                    let service = ThoughtOrganizationService()
                    service.confirmAssignment(assignmentId: assignment.id)
                    ThoughtClassificationFeedbackStore.log(.confirm, thoughtId: thoughtId, tagName: tagName)
                    refreshAIAssignments()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.holoSuccessText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "保留 AI 标签 \(tagName)"))

                // 仅本条不适合（不写全局抑制偏好，不影响未来推荐）
                Button {
                    let service = ThoughtOrganizationService()
                    service.rejectAssignmentCurrentOnly(assignmentId: assignment.id)
                    ThoughtClassificationFeedbackStore.log(.rejectCurrent, thoughtId: thoughtId, tagName: tagName)
                    refreshAIAssignments()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.holoError)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "拒绝 AI 标签 \(tagName)"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isConfirmed
                ? Color.holoPrimary.opacity(0.08)
                : Color.holoToolTextSecondary.opacity(0.06))
        .cornerRadius(HoloRadius.sm)
        .fixedSize(horizontal: true, vertical: false)
        // 全局抑制放右键菜单（与 iOS 长按菜单对位）
        .contextMenu {
            if !isConfirmed {
                Button(role: .destructive) {
                    let service = ThoughtOrganizationService()
                    service.rejectAndRecord(assignmentId: assignment.id, tagName: tagName)
                    ThoughtClassificationFeedbackStore.log(.suppressGlobal, thoughtId: thoughtId, tagName: tagName)
                    refreshAIAssignments()
                } label: {
                    Label("以后不要推荐 #\(tagName)", systemImage: "hand.raised")
                }
            }
        }
    }

    /// 刷新 AI 归类标签（确认/拒绝后与整理结果落库后调用）
    private func refreshAIAssignments() {
        guard let thoughtId else {
            aiAssignments = []
            return
        }
        aiAssignments = (try? thoughtRepository.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []
    }

    // MARK: - 相关旧想法（语义召回，Phase E）

    /// 「你之前也写过」：本机向量召回相关旧想法（含「不相关」反馈写入）；
    /// 复用 iOS ThoughtRelatedSection，命中才渲染、未建索引安静留空
    @ViewBuilder
    private func relatedSection(_ thought: Thought) -> some View {
        if !ThoughtAIAudience.isExcluded(thought),
           ThoughtSemanticFeatureFlags.resurfacingEnabled {
            ThoughtRelatedSection(
                thoughtID: thought.id,
                content: thought.content,
                onOpenThought: { targetId in
                    onOpenThought(targetId)
                })
        }
    }

    // MARK: - 附件

    @ViewBuilder
    private func attachmentSection(_ thought: Thought) -> some View {
        let attachments = thought.sortedAttachments
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                sectionLabel(String(localized: "附件"), systemImage: "paperclip")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                        Button {
                            galleryStartIndex = index
                            showAttachmentGallery = true
                        } label: {
                            ThoughtAttachmentThumbnailView(
                                thumbnailData: attachment.thumbnailData,
                                fileName: attachment.thumbnailFileName,
                                thoughtId: thought.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 引用 / 被引用（思维链）

    /// 引用关系对。与 ThoughtRelatedSection（AI 语义召回，含「不相关」反馈写入）
    /// 是两个概念；Phase B 只读展示 ThoughtReference 关系事实。
    @ViewBuilder
    private func referenceSection(_ thought: Thought) -> some View {
        let outgoing = linkItems(from: thought.references, peer: \.targetThought)
        let incoming = linkItems(from: thought.referencedBy, peer: \.sourceThought)
        if !outgoing.isEmpty || !incoming.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                if !outgoing.isEmpty {
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        sectionLabel(String(localized: "引用"), systemImage: "quote.opening")
                        ForEach(outgoing) { item in
                            linkRow(item)
                        }
                    }
                }
                if !incoming.isEmpty {
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        sectionLabel(String(localized: "被引用"), systemImage: "link.circle")
                        ForEach(incoming) { item in
                            linkRow(item)
                        }
                    }
                }
            }
        }
    }

    /// 引用对端快照（displayText 优先，回退对端首行/正文；对端已删用快照）
    private func linkItems(from refs: NSSet?, peer: KeyPath<ThoughtReference, Thought?>) -> [MacThoughtLinkItem] {
        ((refs as? Set<ThoughtReference>) ?? [])
            .map { ref -> MacThoughtLinkItem in
                let peerThought = ref[keyPath: peer]
                let deleted = peerThought == nil || peerThought?.deletedAt != nil
                var title = ref.displayText ?? ""
                if title.isEmpty, let firstLine = peerThought?.firstLine, !firstLine.isEmpty {
                    title = firstLine
                }
                if title.isEmpty, let content = peerThought?.content, !content.isEmpty {
                    title = String(content.prefix(60))
                }
                if title.isEmpty, let snapshot = ref.snapshot, !snapshot.isEmpty {
                    title = String(snapshot.prefix(60))
                }
                return MacThoughtLinkItem(
                    id: ref.id,
                    peerThoughtId: peerThought?.id,
                    title: title.isEmpty ? String(localized: "已删除的想法") : title,
                    date: ref.createdAt,
                    deleted: deleted)
            }
            .sorted { $0.date > $1.date }
    }

    private func linkRow(_ item: MacThoughtLinkItem) -> some View {
        Button {
            if let peerId = item.peerThoughtId {
                onOpenThought(peerId)
            }
        } label: {
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .holoText(.supporting)
                        .foregroundColor(item.deleted ? .holoTextPlaceholder : .holoToolText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.date.formatted(.dateTime.year().month().day()))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
                Spacer(minLength: 0)
                if item.deleted {
                    Text(String(localized: "已删除"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            .padding(HoloSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoToolSurface))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoToolBorder, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
        .disabled(item.peerThoughtId == nil)
        .accessibilityLabel(String(localized: "打开引用的想法：\(item.title)"))
    }

    // MARK: - 元信息

    private func metaSection(_ thought: Thought) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionLabel(String(localized: "信息"), systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 6) {
                metaRow(String(localized: "创建于"),
                        thought.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                metaRow(String(localized: "更新于"),
                        thought.updatedAt.formatted(.dateTime.year().month().day().hour().minute()))
                if let deviceId = thought.createdDeviceId, !deviceId.isEmpty {
                    metaRow(String(localized: "来源设备"), deviceId)
                }
            }
            .font(.holoCaption)
            .foregroundColor(.holoToolTextSecondary)
        }
    }

    private func metaRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.holoTextPlaceholder)
            Spacer(minLength: 0)
            Text(value)
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.holoLabel)
            .foregroundColor(.holoToolTextSecondary)
    }

    /// 正文渲染的「目标已删除」引用集合（node.noteId = 目标想法主键）
    private func deletedNoteIds(_ thought: Thought) -> Set<UUID> {
        guard let refs = thought.references as? Set<ThoughtReference> else { return [] }
        var out = Set<UUID>()
        for ref in refs {
            guard let target = ref.targetThought, target.deletedAt == nil else {
                if let targetId = ref.targetThought?.id { out.insert(targetId) }
                continue
            }
        }
        return out
    }
}

// MARK: - 引用条目

private struct MacThoughtLinkItem: Identifiable {
    let id: UUID              // ThoughtReference 主键
    let peerThoughtId: UUID?  // 对端想法（引用→目标 / 被引用→来源）
    let title: String
    let date: Date
    let deleted: Bool
}

// MARK: - 标签 chip 换行容器

/// 简单换行排布的 chips 容器（右侧详情宽度固定，超出自动折行）
private struct FlowingChips<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        // macOS 14 无原生 Layout 之外的轻量流式排布；用 LazyVGrid 自适应列近似
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            content()
        }
    }
}
