//
//  TopicDetailView.swift
//  Holo
//
//  知识树 v1 · 主题详情页
//  主题 hero + 关键词筛选 + 想法列表；编辑入口（图标/重命名/删除；关键词长按管理）
//  方案：docs/thoughts/plans/2026-08-15-knowledge-tree-mainline-v1.md §4.3
//

import SwiftUI

struct TopicDetailView: View {

    let topicId: UUID
    let topicRepository: TopicRepository
    let thoughtRepository: ThoughtRepository
    /// 主题被删除后回调（调用方刷新知识树并关闭本页）
    var onTopicDeleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var topic: Topic? = nil
    @State private var thoughts: [Thought] = []
    @State private var tagBuckets: [ThoughtRepository.AITagBucket] = []
    @State private var selectedKeywordKey: String? = nil
    @State private var selectedThoughtId: UUID? = nil

    @State private var showRenameAlert = false
    @State private var renameInput = ""
    @State private var showDeleteConfirm = false
    @State private var showIconPicker = false

    /// 关键词管理（长按：全局重命名/删除，承接原抽屉能力）
    @State private var tagActionTarget: ThoughtRepository.AITagBucket?
    @State private var showTagRenameAlert = false
    @State private var tagRenameInput = ""
    @State private var showTagDeleteConfirm = false
    @State private var actionNotice: String? = nil

    /// 主题色（按主题在知识树中的稳定标识取色板色）
    private var themeColor: Color {
        Color.topicPalette(for: topic?.title ?? "")
    }

    /// 关键词筛选：按标签 key 匹配（可见 assignment 命中即算）
    private var filteredThoughts: [Thought] {
        guard let key = selectedKeywordKey else { return thoughts }
        return thoughts.filter { thought in
            ThoughtTagPresentation.matches(
                key,
                manualNames: thought.tagArray.map(\.name),
                aiNames: thought.visibleAITagNames
            )
        }
    }

    /// 该主题下的关键词桶（叶段名展示，key 筛选）
    private var topicBuckets: [ThoughtRepository.AITagBucket] {
        guard let title = topic?.title else { return [] }
        return tagBuckets.filter {
            ThoughtTagNormalizer.isPath($0.tagName, under: title)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if let topic {
                        heroSection(topic)
                        keywordRow
                        thoughtListSection
                    } else {
                        missingTopicView
                    }
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
            }
            .background(Color.holoBackground)
            .navigationTitle(topic?.title ?? "主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") { dismiss() }
                        .foregroundColor(.holoPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showIconPicker = true
                        } label: {
                            Label("更换图标", systemImage: "face.smiling")
                        }
                        Button {
                            renameInput = topic?.title ?? ""
                            showRenameAlert = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除主题", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
            }
            .alert("重命名主题", isPresented: $showRenameAlert) {
                TextField("新主题名", text: $renameInput)
                Button("取消", role: .cancel) { renameInput = "" }
                Button("确定") { performRename() }
            } message: {
                Text("主题下关键词会一并迁移到新路径")
            }
            .alert("删除主题", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { performDelete() }
            } message: {
                Text("「\(topic?.title ?? "")」下的 \(thoughts.count) 条想法将回到未归类；AI 90 天内不会再归纳出该主题")
            }
            .alert("重命名关键词", isPresented: $showTagRenameAlert) {
                TextField("新关键词名", text: $tagRenameInput)
                Button("取消", role: .cancel) { tagRenameInput = "" }
                Button("确定") { performTagRename() }
            } message: {
                Text("将全局重命名「\(tagActionTarget?.tagName ?? "")」；若与已有标签同名会自动合并")
            }
            .alert("删除关键词", isPresented: $showTagDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { performTagDelete() }
            } message: {
                Text("将从 \(tagActionTarget?.assignmentCount ?? 0) 条想法移除「\(ThoughtTagNormalizer.lastSegment(tagActionTarget?.tagName ?? ""))」，AI 以后不再推荐")
            }
            .sheet(isPresented: $showIconPicker) {
                EmojiIconPickerSheet(currentIcon: topic.map { TopicIconProvider.icon(for: $0) }) { emoji in
                    applyIcon(emoji)
                }
            }
            .fullScreenCover(item: $selectedThoughtId) { thoughtId in
                ThoughtDetailView(
                    thoughtId: thoughtId,
                    thoughtRepository: ThoughtRepository(),
                    showsDismissButton: true
                )
                .holoContentColumn()
            }
            .overlay(alignment: .top) { actionToast }
        }
        .task { await loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            Task { await loadData() }
        }
    }

    // MARK: - 数据

    @MainActor
    private func loadData() async {
        topic = try? topicRepository.fetchTopicById(topicId)
        guard topic != nil else { return }
        thoughts = (try? topicRepository.fetchThoughts(byTopic: topicId)) ?? []
        tagBuckets = (try? thoughtRepository.fetchAITagBuckets(excludeAbsorbed: false)) ?? []
    }

    // MARK: - Hero

    private func heroSection(_ topic: Topic) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Text(TopicIconProvider.icon(for: topic))
                .font(.system(size: 26))
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .fill(themeColor.opacity(0.16))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Text("\(thoughts.count) 条想法 · \(topicBuckets.count) 个关键词")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
    }

    // MARK: - 关键词筛选行（长按管理）

    private var keywordRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HoloFilterChip(
                    title: "全部 \(thoughts.count)",
                    isSelected: selectedKeywordKey == nil
                ) {
                    selectedKeywordKey = nil
                }

                ForEach(topicBuckets) { bucket in
                    HoloFilterChip(
                        title: "\(ThoughtTagNormalizer.lastSegment(bucket.tagName)) \(bucket.assignmentCount)",
                        isSelected: selectedKeywordKey == ThoughtTagNormalizer.key(bucket.tagName)
                    ) {
                        selectedKeywordKey = ThoughtTagNormalizer.key(bucket.tagName)
                    }
                    .contextMenu {
                        Button {
                            tagActionTarget = bucket
                            tagRenameInput = bucket.tagName
                            showTagRenameAlert = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            tagActionTarget = bucket
                            showTagDeleteConfirm = true
                        } label: {
                            Label("删除关键词", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.vertical, HoloSpacing.xs)
        }
    }

    // MARK: - 想法列表

    private var thoughtListSection: some View {
        Group {
            if filteredThoughts.isEmpty {
                VStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(.holoTextSecondary.opacity(0.4))
                    Text(selectedKeywordKey == nil ? "这个主题下还没有想法" : "这个关键词下暂无想法")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, HoloSpacing.xxl)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredThoughts) { thought in
                        ThoughtCardView(
                            thought: thought,
                            onNavigate: { selectedThoughtId = thought.id },
                            onTagTap: { tagName in
                                // 标签点选映射到本页关键词筛选
                                selectedKeywordKey = ThoughtTagNormalizer.key(tagName)
                            },
                            onRetryOrganize: thought.organizedStatus == "failed" ? {
                                ThoughtOrganizationQueue.shared.enqueueManual(thoughtId: thought.id)
                            } : nil
                        )
                    }
                }
            }
        }
    }

    /// 主题已被删除（多设备同步等场景）
    private var missingTopicView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 40))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("主题不存在或已被删除")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HoloSpacing.xxl)
    }

    // MARK: - 编辑操作

    private func applyIcon(_ emoji: String) {
        guard let topic else { return }
        do {
            topic.iconEmoji = emoji
            try topicRepository.saveTopicChanges(topic)
            HapticManager.light()
            Task { await loadData() }
        } catch {
            HoloToastCenter.shared.show("图标保存失败", type: .error)
        }
    }

    private func performRename() {
        guard let topic else { return }
        let newTitle = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        renameInput = ""
        guard !newTitle.isEmpty, newTitle != topic.title else { return }
        do {
            try topicRepository.renameClassificationTopic(topic, to: newTitle)
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            Task { await loadData() }
        } catch {
            HoloToastCenter.shared.show("重命名失败", type: .error)
        }
    }

    private func performDelete() {
        guard let topic else { return }
        do {
            let result = try topicRepository.deleteClassificationTopic(topic)
            try ConvergenceRejectionRepository().reject(topicTitle: result.title, sourceTerms: result.sourceTerms)
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            dismiss()
            onTopicDeleted?()
        } catch {
            HoloToastCenter.shared.show("删除主题失败", type: .error)
        }
    }

    // MARK: - 关键词全局管理（承接原抽屉能力）

    private func performTagRename() {
        guard let target = tagActionTarget else { return }
        let newName = tagRenameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        tagRenameInput = ""
        guard !newName.isEmpty,
              ThoughtTagNormalizer.key(newName) != ThoughtTagNormalizer.key(target.tagName) else { return }

        let service = ThoughtOrganizationService()
        do {
            let outcome = try service.renameTagEverywhere(from: target.tagName, to: newName)
            if ThoughtTagNormalizer.key(selectedKeywordKey ?? "") == ThoughtTagNormalizer.key(target.tagName) {
                selectedKeywordKey = nil
            }
            actionNotice = outcome == .merged ? "已合并到 #\(ThoughtTagNormalizer.lastSegment(newName))" : "已重命名"
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            Task { await loadData() }
        } catch {
            actionNotice = (error as? ThoughtError)?.errorDescription ?? "重命名失败"
        }
    }

    private func performTagDelete() {
        guard let target = tagActionTarget else { return }
        let service = ThoughtOrganizationService()
        if let result = service.deleteTagEverywhere(name: target.tagName) {
            if ThoughtTagNormalizer.key(selectedKeywordKey ?? "") == ThoughtTagNormalizer.key(target.tagName) {
                selectedKeywordKey = nil
            }
            actionNotice = "已从 \(result.removedAssignmentCount) 条想法移除"
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            Task { await loadData() }
        } else {
            actionNotice = "删除失败"
        }
    }

    // MARK: - toast

    private var actionToast: some View {
        Group {
            if let notice = actionNotice {
                Text(notice)
                    .font(.holoCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(HoloRadius.md)
                    .padding(.top, HoloSpacing.xl)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation(.easeInOut) { actionNotice = nil }
                    }
            }
        }
    }
}

// MARK: - 主题色板

extension Color {
    /// 主题稳定取色：按标题归一化 key 哈希落到固定色板，重命名不跳色（按标题取则轻微变化可接受）
    static func topicPalette(for title: String) -> Color {
        let palette: [Color] = [
            .holoChart1, .holoChart2, .holoChart3, .holoChart5,
            .holoChart6, .holoChart7, .holoChart9, .holoChart10
        ]
        var hash = 5381
        for scalar in ThoughtTagNormalizer.key(title).unicodeScalars {
            hash = (hash << 5) &+ hash &+ Int(scalar.value)
        }
        let index = abs(hash) % palette.count
        return palette[index]
    }
}

// MARK: - Preview

#Preview {
    Text("TopicDetailView 需要 Core Data context")
}
