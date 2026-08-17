//
//  ThoughtKnowledgeTreeView.swift
//  Holo
//
//  知识树 v1 · 主视图（主题卡片墙）
//  「时间流 | 知识树」的知识树形态：AI 状态条 + 主题卡片 + 未归类/发现/归档入口
//  方案：docs/thoughts/plans/2026-08-15-knowledge-tree-mainline-v1.md §4.2
//

import SwiftUI

struct ThoughtKnowledgeTreeView: View {

    let thoughtRepository: ThoughtRepository
    let topicRepository: TopicRepository
    /// 点未归类/已归档：切回时间流并应用筛选（复用抽屉筛选通道）
    let onNavigateToList: (DrawerNode) -> Void
    /// 点「发现新主题」：触发跨观点归并流程
    let onAIOrganize: () -> Void

    @ObservedObject private var orgQueue = ThoughtOrganizationQueue.shared

    @State private var topics: [Topic] = []
    /// 主题统计：想法数 / 最近想法时间（一次 fetch 避免逐主题重复查询）
    @State private var topicStats: [UUID: (count: Int, latestDate: Date?)] = [:]
    @State private var tagBuckets: [ThoughtRepository.AITagBucket] = []
    @State private var unclassifiedCount: Int = 0
    @State private var archivedCount: Int = 0
    @State private var pendingConfirmationCount: Int = 0

    @State private var topicDetailId: UUID? = nil
    @State private var showConfirmationQueue = false

    /// 数据刷新节流任务（批量整理时通知风暴，合并刷新避免主线程卡顿）
    @State private var refreshTask: Task<Void, Never>? = nil

    /// 按想法数降序排列的主题（同数按名称）
    private var sortedTopics: [Topic] {
        topics.sorted { lhs, rhs in
            let lc = topicStats[lhs.id]?.count ?? 0
            let rc = topicStats[rhs.id]?.count ?? 0
            if lc != rc { return lc > rc }
            return lhs.title < rhs.title
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                aiStatusBar

                sectionLabel("我的主题")

                if topics.isEmpty {
                    emptyTopicsView
                } else {
                    topicGrid
                }

                unclassifiedCard
                discoverRow
                archivedRow

                // P1：整理设置统一收口入口（东林拍板：后续想法 AI 设置都放这里）
                organizationSettingsRow
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, 100)
        }
        .task { await loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            // 节流：与列表刷新同策略，合并 500ms 内的通知统一刷新
            refreshTask?.cancel()
            refreshTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled {
                    await loadData()
                }
            }
        }
        .fullScreenCover(item: $topicDetailId) { topicId in
            TopicDetailView(
                topicId: topicId,
                topicRepository: topicRepository,
                thoughtRepository: thoughtRepository,
                onTopicDeleted: { topicDetailId = nil }
            )
        }
        .fullScreenCover(isPresented: $showConfirmationQueue) {
            TopicConfirmationQueueView(
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                onQueueDrained: { Task { await loadData() } }
            )
        }
    }

    // MARK: - 数据

    @MainActor
    private func loadData() async {
        do {
            let allTopics = try topicRepository.fetchClassificationTopics()
            topics = allTopics

            var stats: [UUID: (count: Int, latestDate: Date?)] = [:]
            for topic in allTopics {
                let thoughts = try topicRepository.fetchThoughts(byTopic: topic.id)
                stats[topic.id] = (count: thoughts.count, latestDate: thoughts.first?.createdAt)
            }
            topicStats = stats

            tagBuckets = try thoughtRepository.fetchAITagBuckets(excludeAbsorbed: false)
            unclassifiedCount = try thoughtRepository.fetchUnclassifiedThoughts().count
            archivedCount = try thoughtRepository.fetchArchived().count
            pendingConfirmationCount = try thoughtRepository.fetchThoughtsPendingTopicConfirmation().count
        } catch {
            // 保持既有数据，不打断浏览
        }
    }

    // MARK: - AI 状态条

    @ViewBuilder
    private var aiStatusBar: some View {
        if orgQueue.isBatchOrganizing, let total = orgQueue.batchTotal {
            aiStatusRow(
                icon: "sparkles",
                text: "AI 自动整理中（\(orgQueue.batchCompleted)/\(total)）",
                badge: nil,
                action: nil
            )
        } else if orgQueue.dailyLimitHit {
            aiStatusRow(
                icon: "moon.zzz.fill",
                text: "今日 AI 额度已用尽，剩余条目明天自动续做",
                badge: nil,
                action: nil
            )
        } else if pendingConfirmationCount > 0 {
            aiStatusRow(
                icon: "sparkles",
                text: "AI 已整理好你的想法，\(pendingConfirmationCount) 条主题归属想跟你确认",
                badge: "\(pendingConfirmationCount) 待确认",
                action: { showConfirmationQueue = true }
            )
        }
    }

    private func aiStatusRow(icon: String, text: String, badge: String?, action: (() -> Void)?) -> some View {
        Group {
            if let action {
                Button(action: action) {
                    aiStatusContent(icon: icon, text: text, badge: badge)
                }
                .buttonStyle(.plain)
            } else {
                aiStatusContent(icon: icon, text: text, badge: badge)
            }
        }
    }

    private func aiStatusContent(icon: String, text: String, badge: String?) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.holoAI)
            Text(text)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let badge {
                Text(badge)
                    .font(.holoTinyLabel)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.holoPrimary)
                    .clipShape(Capsule())
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoAI.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoAI.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - 主题卡片墙

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.holoLabel)
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, HoloSpacing.xs)
    }

    private var topicGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            ForEach(sortedTopics, id: \.id) { topic in
                topicCard(topic)
            }
        }
    }

    private func topicCard(_ topic: Topic) -> some View {
        let color = Color.topicPalette(for: topic.title)
        let count = topicStats[topic.id]?.count ?? 0
        return Button {
            topicDetailId = topic.id
        } label: {
            // 等高对齐：cell 高度取行内最大值，内容顶对齐填充
            VStack(alignment: .leading, spacing: 10) {
                // 图标：emoji 于主题色底
                Text(TopicIconProvider.icon(for: topic))
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .fill(color.opacity(0.16))
                    )

                // 标题 + 数量（基线对齐，单行截断）
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(topic.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(count)")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                // 关键词胶囊：固定高度单行，最多 2 个，超宽截断（不换行不挤压）
                keywordChipRow(topic)

                // 最近活跃（固定高度，无想法时占位保持等高）
                Text(recentLabel(for: topic))
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextSecondary.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .buttonStyle(.plain)
    }

    /// 关键词胶囊行：固定高度，最多 2 个，每个单行截断；不足时留白保持布局稳定
    private func keywordChipRow(_ topic: Topic) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(topicKeywords(topic).prefix(2)), id: \.self) { keyword in
                Text(keyword)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.holoTextSecondary.opacity(0.08))
                    .cornerRadius(HoloRadius.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 21)
    }

    /// 最近活跃文案；无想法时占位保持卡片结构一致
    private func recentLabel(for topic: Topic) -> String {
        guard let latest = topicStats[topic.id]?.latestDate else {
            return "还没有想法"
        }
        return "最近想法 · \(dayLabel(latest))"
    }

    /// 主题下的关键词叶段名（按命中数降序）
    private func topicKeywords(_ topic: Topic) -> [String] {
        tagBuckets
            .filter { ThoughtTagNormalizer.isPath($0.tagName, under: topic.title) }
            .map { ThoughtTagNormalizer.lastSegment($0.tagName) }
    }

    /// 相对日期（与想法卡片 formattedDate 的日期段一致）
    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private var emptyTopicsView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("还没有主题")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Text("右上角「管理」创建第一个主题，AI 会按主题整理新想法")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xxl)
    }

    // MARK: - 未归类 / 发现 / 归档

    private var unclassifiedCard: some View {
        Button {
            onNavigateToList(.unclassified)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 17))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 38, height: 38)
                    .background(Color.holoTextSecondary.opacity(0.1))
                    .cornerRadius(HoloRadius.md)

                VStack(alignment: .leading, spacing: 2) {
                    Text("未归类")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(unclassifiedCount > 0 ? "\(unclassifiedCount) 条想法还不知道该进哪个主题" : "没有待归类的想法")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(Color.holoTextSecondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
    }

    private var discoverRow: some View {
        Button {
            onAIOrganize()
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundColor(.holoAI)
                    .frame(width: 38, height: 38)
                    .background(Color.holoAI.opacity(0.12))
                    .cornerRadius(HoloRadius.md)

                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新主题")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text("AI 从未归类想法中归纳潜在新主题，经你确认后创建")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
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
        .buttonStyle(.plain)
    }

    private var archivedRow: some View {
        Button {
            onNavigateToList(.archived)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "archivebox")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
                Text("已归档")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                if archivedCount > 0 {
                    Text("\(archivedCount)")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.horizontal, HoloSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    /// P1：整理设置行（自动分类开关 / 标签治理 / 反馈 Debug 都收口在设置页内）
    @State private var showOrganizationSettings = false

    private var organizationSettingsRow: some View {
        Button {
            showOrganizationSettings = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
                Text("整理设置")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }
            .padding(.horizontal, HoloSpacing.xs)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showOrganizationSettings) {
            ThoughtOrganizationSettingsView()
        }
    }
}

#Preview {
    Text("ThoughtKnowledgeTreeView 需要 Core Data context")
}
