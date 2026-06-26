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
    case aiTag(String)     // AI 标签池某标签（tagName）
    case topic(UUID)       // 某主题（topicId，P1.5）
    case aiOrganize        // AI 整理入口（非筛选，触发预告）
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

    /// AI 标签池聚合（P1.2 fetchAITagBuckets）
    @State private var aiTagBuckets: [ThoughtRepository.AITagBucket] = []

    /// 主题列表（P1.5.2）
    @State private var topics: [Topic] = []

    /// AI 整理「功能开发中」弹窗
    @State private var showOrganizeAlert: Bool = false

    /// 待整理数 = 所有 .ai/.confirmedAI assignment 总数
    private var pendingOrganizeCount: Int {
        aiTagBuckets.reduce(0) { $0 + $1.assignmentCount }
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
        .alert("AI 整理", isPresented: $showOrganizeAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("积累后可一键归类，功能开发中。")
        }
    }

    /// 加载 AI 标签池聚合
    private func loadAIBuckets() async {
        do {
            aiTagBuckets = try thoughtRepository.fetchAITagBuckets()
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

                sectionLabel(".ai 标签池")
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
            Text("暂无主题，AI 整理后生成")
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

    // MARK: - AI 标签池（fetchAITagBuckets 真实聚合）

    private var aiPoolSection: some View {
        Group {
            if aiTagBuckets.isEmpty {
                aiPoolEmpty
            } else {
                HStack {
                    Text("共 \(aiTagBuckets.count) 个 AI 标签")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xs)

                ForEach(aiTagBuckets) { bucket in
                    aiTagRow(bucket)
                }
            }
        }
    }

    private var aiPoolEmpty: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tag")
                .font(.system(size: 13))
                .foregroundColor(.holoAI)
            Text("暂无 AI 标签")
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

    // MARK: - AI 整理入口（预告，P1 不触发归并）

    private var aiOrganizeRow: some View {
        Button {
            showOrganizeAlert = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundColor(.holoAI)
                    .frame(width: 26)

                Text("AI 整理")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                if pendingOrganizeCount > 0 {
                    Text("待整理 \(pendingOrganizeCount) 条")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoAI)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 2)
                        .background(Color.holoAI.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text("功能开发中")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 2)
                        .background(Color.holoBackground)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }
}
