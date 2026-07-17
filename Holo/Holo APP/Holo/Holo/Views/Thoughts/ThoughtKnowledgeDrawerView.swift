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

    /// 标签管理操作对象（长按菜单触发）
    @State private var tagActionTarget: ThoughtRepository.AITagBucket?
    /// 重命名 alert 开关
    @State private var showRenameAlert = false
    /// 重命名输入
    @State private var renameInput = ""
    /// 删除确认 alert 开关
    @State private var showDeleteConfirm = false
    /// 主题管理操作对象（长按菜单触发）
    @State private var topicActionTarget: Topic?
    /// 主题重命名 alert 开关
    @State private var showTopicRenameAlert = false
    /// 主题重命名输入
    @State private var topicRenameInput = ""
    /// 主题删除确认 alert 开关
    @State private var showTopicDeleteConfirm = false
    /// 标签/主题管理操作反馈（toast，nil 不显示）
    @State private var actionNotice: String?

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
        .overlay(alignment: .top) { actionToast }
        .alert("重命名标签", isPresented: $showRenameAlert) {
            TextField("新标签名", text: $renameInput)
            Button("取消", role: .cancel) { renameInput = "" }
            Button("确定") { performRename() }
        } message: {
            Text("为「\(tagActionTarget?.tagName ?? "")」输入新名称；若与已有标签同名，将自动合并")
        }
        .alert("删除标签", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { performDelete() }
        } message: {
            Text("将从 \(tagActionTarget?.assignmentCount ?? 0) 条想法移除「\(tagActionTarget?.tagName ?? "")」，AI 以后不再推荐")
        }
        .alert("重命名主题", isPresented: $showTopicRenameAlert) {
            TextField("新主题名", text: $topicRenameInput)
            Button("取消", role: .cancel) { topicRenameInput = "" }
            Button("确定") { performRenameTopic() }
        } message: {
            Text("为「\(topicActionTarget?.title ?? "")」输入新名称")
        }
        .alert("删除主题", isPresented: $showTopicDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { performDeleteTopic() }
        } message: {
            let count = (topicActionTarget?.thoughts as? Set<Thought>)?.count ?? 0
            Text("「\(topicActionTarget?.title ?? "")」下的 \(count) 条想法将回到未归类；AI 90 天内不会再归纳出该主题")
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
        .contextMenu {
            Button {
                topicActionTarget = topic
                topicRenameInput = topic.title
                showTopicRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button(role: .destructive) {
                topicActionTarget = topic
                showTopicDeleteConfirm = true
            } label: {
                Label("删除主题", systemImage: "trash")
            }
        }
    }

    // MARK: - 主题管理操作

    /// 执行主题重命名（topic id 不变，筛选状态保持连续）
    private func performRenameTopic() {
        guard let topic = topicActionTarget else { return }
        let newTitle = topicRenameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        topicRenameInput = ""
        guard !newTitle.isEmpty, newTitle != topic.title else { return }

        do {
            try topicRepository.updateTitle(topic, title: newTitle)
            actionNotice = "已重命名为「\(newTitle)」"
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            actionNotice = "重命名失败"
        }
    }

    /// 执行主题删除：想法回未归类 + 写归并拒绝记录（AI 90 天内不再归纳同名主题）
    private func performDeleteTopic() {
        guard let topic = topicActionTarget else { return }
        let topicId = topic.id  // 删除后对象属性不可访问，先取出
        do {
            let result = try topicRepository.delete(topic)
            try ConvergenceRejectionRepository().reject(topicTitle: result.title, sourceTerms: result.sourceTerms)
            if case .topic(let selectedId) = selection, selectedId == topicId {
                selection = .allNotes
            }
            actionNotice = "已删除主题「\(result.title)」，\(result.removedThoughtCount) 条想法回到未归类"
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            actionNotice = "删除主题失败"
        }
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
        .contextMenu {
            Button {
                tagActionTarget = bucket
                renameInput = bucket.tagName
                showRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button(role: .destructive) {
                tagActionTarget = bucket
                showDeleteConfirm = true
            } label: {
                Label("删除标签", systemImage: "trash")
            }
        }
    }

    // MARK: - 标签管理操作

    /// 执行全局重命名（目标已存在时自动合并）
    private func performRename() {
        guard let target = tagActionTarget else { return }
        let newName = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        renameInput = ""
        guard !newName.isEmpty,
              ThoughtTagNormalizer.key(newName) != ThoughtTagNormalizer.key(target.tagName) else { return }

        let service = ThoughtOrganizationService()
        do {
            let outcome = try service.renameTagEverywhere(from: target.tagName, to: newName)
            resetSelectionIfNeeded(for: target.tagName)
            let displayName = ThoughtTagNormalizer.displayName(newName)
            actionNotice = outcome == .merged ? "已合并到 #\(displayName)" : "已重命名为 #\(displayName)"
            HapticManager.light()
            // 数据变更通知由调用方 post（与详情页 reject/confirm 同惯例）
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            actionNotice = (error as? ThoughtError)?.errorDescription ?? "重命名失败"
        }
    }

    /// 执行全局删除（写拒绝偏好防 AI 再生）
    private func performDelete() {
        guard let target = tagActionTarget else { return }
        let service = ThoughtOrganizationService()
        if let result = service.deleteTagEverywhere(name: target.tagName) {
            resetSelectionIfNeeded(for: target.tagName)
            actionNotice = "已从 \(result.removedAssignmentCount) 条想法移除 #\(target.tagName)"
            HapticManager.light()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } else {
            actionNotice = "删除失败"
        }
    }

    /// 删除/改名当前筛选中的标签时，重置为「全部笔记」避免空白筛选态
    private func resetSelectionIfNeeded(for tagName: String) {
        guard case .aiTag(let selectedName) = selection,
              ThoughtTagNormalizer.key(selectedName) == ThoughtTagNormalizer.key(tagName) else { return }
        selection = .allNotes
    }

    /// 操作反馈 toast（自动消失，id 绑定文案保证连续操作重置计时）
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
