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

    /// V3 主题摘要（§4.5）：AI 派生只存本机语义库；失败静默隐藏，不影响列表
    @State private var summaryContent: ThoughtTopicSummaryContent? = nil
    @State private var summaryBasisRevision: Int64 = 0
    @State private var summaryRefreshing = false
    @State private var summaryFailedOnce = false

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

    /// V3 新 UI：主题持续时间（最早→最晚想法的自然日跨度，单日=1 天）
    private var topicDurationText: String {
        let dates = thoughts.compactMap(\.createdAt)
        guard let earliest = dates.min(), let latest = dates.max() else {
            return String(localized: "持续 1 天")
        }
        let calendar = Calendar.current
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest),
                                           to: calendar.startOfDay(for: latest)).day ?? 0) + 1
        return String(localized: "持续 \(max(1, days)) 天")
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if let topic {
                        topicContentSections(topic)
                    } else {
                        missingTopicView
                    }
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
            }
            .background(Color.holoBackground)
            .navigationTitle(topic?.title ?? String(localized: "主题"))
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
                ThoughtEditorView(
                    editingThoughtId: thoughtId
                )
                .holoContentColumn()
            }
            .overlay(alignment: .top) { actionToast }
        }
        .task { await loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            Task { await loadData() }
        }
        // 全屏阅读页：边缘右滑返回（fullScreenCover 无系统返回）
        .holoEdgeSwipeBack { dismiss() }
    }

    // MARK: - 数据

    @MainActor
    private func loadData() async {
        topic = try? topicRepository.fetchTopicById(topicId)
        guard topic != nil else { return }
        thoughts = (try? topicRepository.fetchThoughts(byTopic: topicId)) ?? []
        tagBuckets = (try? thoughtRepository.fetchAITagBuckets(excludeAbsorbed: false)) ?? []
        if ThoughtSemanticFeatureFlags.uiEnabled, let topic {
            await loadSummaryIfEligible(for: topic)
        }
    }

    // MARK: - V3 主题摘要（§4.5；AI 派生只存本机语义库）

    /// 缓存优先：有缓存先展示（成员变化=过期也先显示旧值+可重建，不自动烧配额）；
    /// 完全无缓存才自动生成一次；失败过则本会话静默（下次进页再试）。
    @MainActor
    private func loadSummaryIfEligible(for topic: Topic) async {
        guard thoughts.count >= 2, let store = await ThoughtSemanticPipeline.shared.store else { return }
        summaryFailedOnce = false
        if let cached = try? await store.loadTopicSummary(topicID: topicId) {
            summaryContent = Self.decodeSummary(cached)
            summaryBasisRevision = cached.basisRevision
            return
        }
        guard summaryContent == nil else { return }
        await refreshSummary(topic)
    }

    @MainActor
    private func refreshSummary(_ topic: Topic) async {
        guard !summaryRefreshing, let store = await ThoughtSemanticPipeline.shared.store else { return }
        summaryRefreshing = true
        defer { summaryRefreshing = false }
        do {
            let content = try await ThoughtTopicSummaryClient.refreshSummary(
                topicID: topicId,
                title: topic.title ?? "",
                thoughts: thoughts,
                basisRevision: topic.topicRevision,
                provider: HoloBackendAIProvider(),
                store: store)
            withAnimation {
                summaryContent = content
                summaryBasisRevision = topic.topicRevision
            }
        } catch {
            // 离线/503 隐私闸门/契约失败同口径：静默隐藏摘要区（§4.5 只隐藏不影响其他）
            summaryFailedOnce = true
        }
    }

    private static func decodeSummary(_ record: ThoughtSemanticStore.TopicSummaryRecord) -> ThoughtTopicSummaryContent? {
        guard let data = record.viewpointsJSON.data(using: .utf8),
              let viewpoints = try? JSONDecoder().decode([ThoughtTopicSummaryContent.Viewpoint].self, from: data)
        else { return nil }
        return .init(summary: record.summary, viewpoints: viewpoints)
    }

    // MARK: - 构成行与交集标签（P1 §3.3，2026-09-27）

    /// 主题页主体区块（body 过重抽出的子表达式；区块顺序=方案 §3.3 首屏顺序）
    @ViewBuilder
    private func topicContentSections(_ topic: Topic) -> some View {
        heroSection(topic)
        // 构成行：让 AI 自动归类的贡献可见（你加入 N · Holo 找到 M）
        if ThoughtSemanticFeatureFlags.uiEnabled, !thoughts.isEmpty {
            membershipSplitSection
        }
        // V3 新 UI：AI 摘要卡（生成失败/离线静默隐藏，§4.5）
        if ThoughtSemanticFeatureFlags.uiEnabled {
            topicSummarySection(topic)
        }
        // V3 新 UI：关键词是 AI 标签派生，退为内部索引（摘要/观点区随 Phase 5 摘要端点接入）
        if !ThoughtSemanticFeatureFlags.uiEnabled {
            keywordRow
        }
        if ThoughtSemanticFeatureFlags.uiEnabled, thoughts.count >= 2 {
            timelineEndpointsSection
        }
        // 交集标签：成员用过的 #标签（点按进入标签范围，双向桥）
        if ThoughtSemanticFeatureFlags.uiEnabled {
            memberTagChipsSection
        }
        thoughtListSection
    }

    /// 成员构成：你加入 N 条 · Holo 找到 M 条（历史归集单独一档，不冒充任何一类）。
    /// 让 AI 自动归类的贡献可见——这是「AI 显著生效」最直接的证据位。
    private var membershipSplitSection: some View {
        let split = membershipSplit
        return HStack(spacing: 8) {
            splitPill(title: String(localized: "你加入 \(split.userCount) 条"),
                      detail: String(localized: "手动放入或接受建议"),
                      color: .holoPrimary)
            splitPill(title: String(localized: "Holo 找到 \(split.aiCount) 条"),
                      detail: String(localized: "高可信自动归入"),
                      color: .holoSuccess)
            if split.legacyCount > 0 {
                splitPill(title: String(localized: "历史归集 \(split.legacyCount) 条"),
                          detail: String(localized: "早期整理"),
                          color: .holoTextSecondary)
            }
        }
    }

    private struct MembershipSplit { var userCount = 0; var aiCount = 0; var legacyCount = 0 }

    private var membershipSplit: MembershipSplit {
        var split = MembershipSplit()
        for thought in thoughts {
            guard let topic else { break }
            switch ThoughtTopicLinkProjection.membershipSource(of: thought, in: topic) {
            case .user: split.userCount += 1
            case .ai: split.aiCount += 1
            case .legacy: split.legacyCount += 1
            case nil: break
            }
        }
        return split
    }

    private func splitPill(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(detail)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md)
            .fill(color.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    /// 成员里你用过的 #标签（≤3，按条数）：点按进入标签范围——主题页对标签页的回桥。
    @ViewBuilder
    private var memberTagChipsSection: some View {
        let chips = memberTagChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("成员里你用过的 #标签")
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                HStack(spacing: 8) {
                    ForEach(chips, id: \.name) { item in
                        Button {
                            // 复用编辑器「查看标签」通道：ThoughtsView 接收后切标签范围
                            NotificationCenter.default.post(
                                name: .thoughtRequestTagFilter, object: item.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 3) {
                                Text("#\(ThoughtTagNormalizer.lastSegment(item.name))")
                                    .font(.holoCaption)
                                Text("×\(item.count)")
                                    .font(.holoTinyLabel)
                                    .foregroundColor(.holoTextPlaceholder)
                            }
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.holoPrimary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "标签\(item.name)，\(item.count) 条想法用过，点按查看"))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var memberTagChips: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for thought in thoughts {
            for name in thought.recognizedTagNames {
                counts[name, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (name: $0.key, count: $0.value) }
    }

    /// 摘要卡：摘要 + 可重建 + 反复提到的观点（点跳来源想法）
    @ViewBuilder
    private func topicSummarySection(_ topic: Topic) -> some View {
        if let content = summaryContent {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack(spacing: 6) {
                    Text("这段时间的变化")
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Button {
                        Task { await refreshSummary(topic) }
                    } label: {
                        HStack(spacing: 3) {
                            if summaryRefreshing {
                                ProgressView().scaleEffect(0.55)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            Text("AI 摘要 · 可重建")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoTextSecondary.opacity(0.08))
                        .cornerRadius(HoloRadius.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(summaryRefreshing)
                    .accessibilityLabel(String(localized: "重建 AI 摘要"))
                }

                Text(content.summary)
                    .font(.system(size: 14.5))
                    .foregroundColor(.holoTextPrimary.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                // 过期态（方案 §3 P1：成员变化后旧摘要不冒充最新——标「可更新」）
                if summaryBasisRevision < topic.topicRevision {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                        Text("主题有新内容，摘要可更新")
                            .font(.holoTinyLabel)
                    }
                    .foregroundColor(.holoTextSecondary)
                    .padding(.top, 2)
                }

                if !content.viewpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("你反复提到的")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                            .padding(.bottom, 4)
                        ForEach(content.viewpoints, id: \.thoughtID) { viewpoint in
                            Button {
                                selectedThoughtId = viewpoint.thoughtID
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.holoPrimary)
                                        .frame(width: 5, height: 5)
                                    Text(viewpoint.quote)
                                        .font(.system(size: 13.5))
                                        .foregroundColor(.holoTextPrimary)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "查看来源想法"))
                        }
                    }
                }
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground)
            )
        }
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
                // V3 新 UI：想法数 + 持续时间（§4.5）；旧 UI 保持「关键词」口径
                if ThoughtSemanticFeatureFlags.uiEnabled {
                    Text("\(thoughts.count) 条想法 · \(topicDurationText)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text("\(thoughts.count) 条想法 · \(topicBuckets.count) 个关键词")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
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

    /// 不依赖 AI 的主题价值：让用户立即看到同一方向最早与最近的记录。
    /// 数据按创建时间倒序读取，首尾两条可直接回到原文。
    private var timelineEndpointsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("从最初到现在")
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            if let first = thoughts.last, let latest = thoughts.first {
                timelineEndpointRow(first, label: "最早记录")
                timelineEndpointRow(latest, label: "最近记录")
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
            .fill(Color.holoCardBackground))
    }

    private func timelineEndpointRow(_ thought: Thought, label: String) -> some View {
        Button {
            selectedThoughtId = thought.id
        } label: {
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                Circle()
                    .fill(themeColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(label) · \(thought.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text(thought.content)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.top, 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(label)，查看来源想法"))
    }

    private var keywordRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HoloFilterChip(
                    title: String(localized: "全部 \(thoughts.count)"),
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
                    Text(selectedKeywordKey == nil ? String(localized: "这个主题下还没有想法") : String(localized: "这个关键词下暂无想法"))
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
                        // P1 校验补链：主题页是纠错的天然阵地——成员卡长按可「从这个主题移除」
                        //（卡片列表的主题行纠错是长按隐藏手势，这里给一个语境明确的可见兜底）
                        .contextMenu {
                            Button(role: .destructive) {
                                removeMember(thought)
                            } label: {
                                Label("从这个主题移除", systemImage: "leaf.slash")
                            }
                        }
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

    /// 成员纠错（P1 校验补链）：从当前主题移除一条想法（写拒绝墓碑，AI 不复活）
    private func removeMember(_ thought: Thought) {
        guard let topic else { return }
        do {
            try topicRepository.remove(thoughtId: thought.id, fromTopic: topic.id)
            HapticManager.light()
            actionNotice = String(localized: "已从「\(topic.title)」移除")
            Task { await loadData() }
        } catch {
            HoloToastCenter.shared.show(String(localized: "移除失败，请重试"), type: .error)
        }
    }

    private func applyIcon(_ emoji: String) {
        guard let topic else { return }
        do {
            topic.iconEmoji = emoji
            try topicRepository.saveTopicChanges(topic)
            HapticManager.light()
            Task { await loadData() }
        } catch {
            HoloToastCenter.shared.show(String(localized: "图标保存失败"), type: .error)
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
            HoloToastCenter.shared.show(String(localized: "重命名失败"), type: .error)
        }
    }

    private func performDelete() {
        guard let target = topic else { return }
        do {
            // 先清本地选中态再删库：硬删+落盘后对象即失效，弹窗关闭与
            // 退场动画期间的 body 重渲染不能再见到此对象（missingTopicView 兜底展示）
            topic = nil
            let result = try topicRepository.deleteClassificationTopic(target)
            try ConvergenceRejectionRepository().reject(topicTitle: result.title, sourceTerms: result.sourceTerms)
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            dismiss()
            onTopicDeleted?()
        } catch {
            topic = target
            HoloToastCenter.shared.show(String(localized: "删除主题失败"), type: .error)
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
            actionNotice = outcome == .merged ? String(localized: "已合并到 #\(ThoughtTagNormalizer.lastSegment(newName))") : String(localized: "已重命名")
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            Task { await loadData() }
        } catch {
            actionNotice = (error as? ThoughtError)?.errorDescription ?? String(localized: "重命名失败")
        }
    }

    private func performTagDelete() {
        guard let target = tagActionTarget else { return }
        let service = ThoughtOrganizationService()
        if let result = service.deleteTagEverywhere(name: target.tagName) {
            if ThoughtTagNormalizer.key(selectedKeywordKey ?? "") == ThoughtTagNormalizer.key(target.tagName) {
                selectedKeywordKey = nil
            }
            actionNotice = String(localized: "已从 \(result.removedAssignmentCount) 条想法移除")
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            Task { await loadData() }
        } else {
            actionNotice = String(localized: "删除失败")
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
