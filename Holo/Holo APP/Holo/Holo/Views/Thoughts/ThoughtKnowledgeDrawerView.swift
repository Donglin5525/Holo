//
//  ThoughtKnowledgeDrawerView.swift
//  Holo
//
//  观点模块 - 左侧知识树抽屉
//  顶部菜单按钮唤出，点击遮罩关闭（P1）；右边缘左滑关闭（P1.5）
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md
//

import SwiftUI

// MARK: - DrawerNode 抽屉节点

/// 抽屉节点类型（右侧列表的筛选意图载体）
/// 实施方案 §4.6
enum DrawerNode: Hashable {
    case allNotes          // 全部笔记
    case unclassified      // 未归类（未进入任何 Topic）
    case aiTag(String)     // 标签池某标签（tagName，手动/正文/AI 同名统一）
    case topic(UUID)       // 某主题（topicId，P1.5）
    case aiOrganize        // 归纳主题入口（非筛选，触发跨观点收敛）
}

// MARK: - ThoughtKnowledgeDrawerView

/// 观点左侧知识树抽屉
struct ThoughtKnowledgeDrawerView: View {

    /// 当前选中节点
    @Binding var selection: DrawerNode?

    /// 数据源（查 AI 标签池聚合）
    let thoughtRepository: ThoughtRepository

    /// 数据源（查主题列表）
    let topicRepository: TopicRepository

    /// 点击节点回调（选中节点；不关闭抽屉，关闭由遮罩/右边缘负责）
    let onSelect: (DrawerNode) -> Void

    /// 点击「归纳主题」回调（P2 触发跨观点收敛 Job + 弹确认页）
    let onAIOrganize: () -> Void

    /// 标签池聚合（手动 / 正文 / AI 同名统一）
    @State private var aiTagBuckets: [ThoughtRepository.AITagBucket] = []

    /// 主题列表（P1.5.2）
    @State private var topics: [Topic] = []

    /// AI 标签池过长时默认折叠，避免抽屉需要滑很久。
    @State private var isAIPoolExpanded: Bool = false

    private let collapsedAIPoolLimit = 3

    /// 待归纳线索数 = 尚未被 Topic 收纳的 .ai/.confirmedAI assignment 总数
    private var pendingThemeClueCount: Int {
        aiTagBuckets.reduce(0) { $0 + $1.assignmentCount }
    }

    private var visibleAIBuckets: [ThoughtRepository.AITagBucket] {
        isAIPoolExpanded ? aiTagBuckets : Array(aiTagBuckets.prefix(collapsedAIPoolLimit))
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(320, geo.size.width * 0.82)
            HStack(spacing: 0) {
                content
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color.holoCardBackground)
                // 右侧留白（遮罩盖住，提示可关闭）
                Spacer(minLength: 0)
            }
        }
        .task {
            await loadAIBuckets()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            // 归并确认后观点数据变更，刷新 AI 标签池 + 主题列表（P2.3 收纳降权实时反映）
            Task { await loadAIBuckets() }
        }
    }

    /// 加载 AI 标签池聚合
    private func loadAIBuckets() async {
        do {
            aiTagBuckets = try thoughtRepository.fetchAITagBuckets(excludeAbsorbed: true)
            topics = try topicRepository.fetchVisibleTopics()
        } catch {
            // 容错：保持空数组，不影响抽屉其他功能
            aiTagBuckets = []
            topics = []
        }
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                nodeRow(.allNotes, icon: "tray.full", title: "全部笔记")
                nodeRow(.unclassified, icon: "square.dashed", title: "未归类")

                sectionLabel("主题")
                topicSection

                sectionLabel("AI 标签池")
                aiPoolSection

                Divider()
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)

                aiOrganizeRow
            }
            .padding(.vertical, HoloSpacing.md)
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("观点")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            Text("知识树")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.md)
    }

    // MARK: - 通用节点行

    private func nodeRow(_ node: DrawerNode, icon: String, title: String) -> some View {
        let isSelected = selection == node
        return Button {
            onSelect(node)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                    .frame(width: 26)

                Text(title)
                    .font(.holoBody)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .opacity(isSelected ? 1 : 0.3)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(isSelected ? Color.holoPrimary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组标题

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.holoLabel)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.xs)
    }

    // MARK: - 主题区空态（无 Topic 时）

    private var topicEmpty: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundColor(.holoAI)
            Text("暂无主题，归纳后生成")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - 主题区（P1.5.2 真实 Topic 列表）

    private var topicSection: some View {
        Group {
            if topics.isEmpty {
                topicEmpty
            } else {
                ForEach(topics, id: \.id) { topic in
                    topicRow(topic)
                }
            }
        }
    }

    private func topicRow(_ topic: Topic) -> some View {
        let isSelected = selection == .topic(topic.id)
        let count = (topic.thoughts as? Set<Thought>)?.count ?? 0
        return Button {
            onSelect(.topic(topic.id))
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .holoPrimary : .holoAI)
                    .frame(width: 26)

                Text(topic.title)
                    .font(.holoBody)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(count)")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 2)
                    .background(Color.holoBackground)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(isSelected ? Color.holoPrimary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 标签池（fetchAITagBuckets 真实聚合）

    private var aiPoolSection: some View {
        Group {
            if aiTagBuckets.isEmpty {
                aiPoolEmpty
            } else {
                HStack(spacing: HoloSpacing.sm) {
                    Text("共 \(aiTagBuckets.count) 个标签")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    if aiTagBuckets.count > collapsedAIPoolLimit {
                        aiPoolToggle
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xs)

                ForEach(visibleAIBuckets) { bucket in
                    aiTagRow(bucket)
                }
            }
        }
    }

    private var aiPoolToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isAIPoolExpanded.toggle()
            }
        } label: {
            HStack(spacing: HoloSpacing.xs) {
                Text(isAIPoolExpanded ? "收起" : "展开")
                    .font(.holoTinyLabel)
                Image(systemName: isAIPoolExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.holoAI)
            .padding(.horizontal, HoloSpacing.sm)
            .padding(.vertical, 4)
            .background(Color.holoAI.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var aiPoolEmpty: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tag")
                .font(.system(size: 13))
                .foregroundColor(.holoAI)
            Text("暂无标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    private func aiTagRow(_ bucket: ThoughtRepository.AITagBucket) -> some View {
        let isSelected = selection == .aiTag(bucket.tagName)
        let confirmedCount = bucket.sourceBreakdown[ThoughtTagAssignment.Source.confirmedAI.rawValue] ?? 0
        return Button {
            onSelect(.aiTag(bucket.tagName))
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "tag")
                    .font(.system(size: 13))
                    .foregroundColor(.holoAI)
                    .frame(width: 26)

                Text(bucket.tagName)
                    .font(.holoBody)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextPrimary)
                    .lineLimit(1)

                // 含已确认标记（用户单条确认过的 AI 标签）
                if confirmedCount > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.holoAI)
                }

                Spacer()

                Text("\(bucket.assignmentCount)")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 2)
                    .background(Color.holoBackground)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(isSelected ? Color.holoPrimary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 归纳主题入口（P2 触发跨观点收敛）

    private var aiOrganizeRow: some View {
        Button {
            onAIOrganize()
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundColor(.holoAI)
                    .frame(width: 26)

                Text("归纳主题")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                if pendingThemeClueCount > 0 {
                    Text("\(pendingThemeClueCount) 条线索")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoAI)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 2)
                        .background(Color.holoAI.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }
}
