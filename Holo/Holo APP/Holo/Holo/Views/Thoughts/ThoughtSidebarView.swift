//
//  ThoughtSidebarView.swift
//  Holo
//
//  想法模块抽屉式侧边栏（2026-09-24 方案 §5.5-5.10，参考 flomo 截图层级）
//
//  侧栏是内容流的导航层：全部想法 / 置顶 / 主题 / 我的 #标签 / 其他。
//  选中只改变右侧内容流范围（ThoughtBrowseScope），不建第二个内容首页；
//  主题不伪装成 #标签，候选主题未建立前不进正式列表。
//

import SwiftUI
import CoreData

struct ThoughtSidebarView: View {

    @Binding var scope: ThoughtBrowseScope
    /// 选中项后由父容器收起侧栏
    let onSelect: () -> Void

    private let thoughtRepository: ThoughtRepository
    private let topicRepository: TopicRepository

    @State private var topics: [Topic] = []
    @State private var tagTree: [ThoughtSidebarTagNode] = []
    @State private var pins: [ThoughtSidebarPin] = []
    @State private var expandedPaths: Set<String> = []
    @State private var activeSection: SidebarSection = .tags
    @State private var showTopicManagement = false
    @State private var showClearThoughtSheet = false
    /// 主题候选建议簇（方案 §5.3：达到门槛的轻量建议行，未建立前不进正式列表）
    @State private var suggestedCluster: ThoughtSemanticStore.ClusterRecord?

    /// 标签名 → 展示名缓存（置顶行显示用；按 key 查 display）
    @State private var tagDisplayByKey: [String: String] = [:]

    /// emoji 图标变更的显示刷新 tick（行内读 Store 内存字典，tick 驱动重算）
    @State private var emojiTick: Int = 0

    private enum SidebarSection {
        case tags, topics
    }

    init(scope: Binding<ThoughtBrowseScope>,
         onSelect: @escaping () -> Void,
         thoughtRepository: ThoughtRepository = ThoughtRepository(),
         topicRepository: TopicRepository = TopicRepository()) {
        self._scope = scope
        self.onSelect = onSelect
        self.thoughtRepository = thoughtRepository
        self.topicRepository = topicRepository
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题与范围入口固定，长列表滚动时不再穿过状态栏。
            topSection
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            sectionPicker
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.sm)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    if !pins.isEmpty { pinnedSection }
                    if activeSection == .tags {
                        tagsSection
                    } else {
                        topicsSection
                    }
                    bottomToolsSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xl)
            }
            .clipped()

            archivedSection
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.xs)
        }
        .background(Color.holoToolSurface)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { loadData() }
        // emoji 图标变更只刷显示层（不全量重查库）
        .onReceive(NotificationCenter.default.publisher(for: ThoughtTagEmojiStore.didChangeNotification)) { _ in
            emojiTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            // 节流（2026-09-26 掉帧修复）：AI 整理队列逐条完成都发通知，
            // 滚动期间每次全量 fetch+建树就是掉帧源；合并 400ms 内的重复通知
            scheduleRefresh()
        }
        .sheet(isPresented: $showTopicManagement, onDismiss: {
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        }) {
            NavigationStack {
                TopicManagementView(topicRepository: topicRepository, thoughtRepository: thoughtRepository)
            }
        }
        .sheet(isPresented: $showClearThoughtSheet) {
            ModuleClearSheet(module: .thought)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "想法导航侧栏"))
    }

    private var sectionPicker: some View {
        HStack(spacing: HoloSpacing.xs) {
            sectionButton("#标签", section: .tags)
            sectionButton("主题", section: .topics)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoToolBackground))
    }

    private func sectionButton(_ title: String, section: SidebarSection) -> some View {
        Button {
            activeSection = section
        } label: {
            Text(title)
                .holoText(.supporting)
                .fontWeight(activeSection == section ? .semibold : .regular)
                .foregroundColor(activeSection == section ? .holoPrimary : .holoToolTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if activeSection == section {
                        RoundedRectangle(cornerRadius: HoloRadius.sm)
                            .fill(Color.holoToolSurface)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(activeSection == section ? [.isSelected] : [])
    }

    // MARK: - 数据

    /// 通知刷新节流任务（2026-09-26 掉帧修复）
    @State private var refreshTask: Task<Void, Never>?

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            loadData()
        }
    }

    private func loadData() {
        guard CoreDataStack.shared.isReady else { return }
        // 侧栏是回看入口：空的预设主题留在管理页，不占据用户找回内容的空间。
        topics = ((try? topicRepository.fetchVisibleTopics()) ?? [])
            .filter { topicRepository.thoughtCount(of: $0) > 0 }
        let names = thoughtRepository.fetchUserRecognizedTagNames(limit: 400)
        tagTree = ThoughtSidebarTagTreeBuilder.build(from: names)
        var displayByKey: [String: String] = [:]
        for name in names {
            displayByKey[ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(name))] = ThoughtTagNormalizer.displayPath(name)
        }
        tagDisplayByKey = displayByKey
        pins = ThoughtSidebarPreference.loadPins().filter { pin in
            // 置顶指向的节点不存在时静默清理（主题已删/标签已改名）
            switch pin.kind {
            case .topic: return topics.contains { $0.id == pin.topicID }
            case .userTag:
                guard let key = pin.tagPathKey else { return false }
                return displayByKey[key] != nil
            }
        }
        expandedPaths = ThoughtSidebarPreference.loadExpandedTagPaths()
        // 主题候选建议（能力可用才出现；无名字时异步补名不阻塞侧栏）
        if ThoughtSemanticFeatureFlags.discoveryEnabled {
            Task {
                if let store = await ThoughtSemanticPipeline.shared.store,
                   var cluster = try? await store.loadSuggestedCluster() {
                    if cluster.name == nil || cluster.name?.isEmpty == true {
                        let members = cluster.memberIDs.compactMap { try? thoughtRepository.fetchById($0) }
                        if !members.isEmpty {
                            cluster.name = await ThoughtTopicSummaryClient.refreshClusterName(
                                fingerprint: cluster.fingerprint,
                                thoughts: members,
                                provider: HoloBackendAIProvider(),
                                store: store)
                        }
                    }
                    let final = cluster
                    await MainActor.run { suggestedCluster = final }
                } else {
                    await MainActor.run { suggestedCluster = nil }
                }
            }
        } else {
            suggestedCluster = nil
        }
    }

    // MARK: - 顶部固定区

    private var topSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("想法")
                .holoText(.pageTitle)
                .foregroundColor(.holoToolText)
                .padding(.horizontal, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.xs)
            sidebarRow(
                title: String(localized: "全部想法"),
                icon: "tray.full",
                isSelected: scope == .all,
                showIndentLine: false) {
                select(.all)
            }
        }
    }

    // MARK: - 置顶

    private var pinnedSection: some View {
        sidebarGroup(title: String(localized: "置顶")) {
            ForEach(pins) { pin in
                if let pinScope = pin.scope {
                    sidebarRow(
                        title: pinDisplayTitle(pin),
                        icon: pin.kind == .topic ? "leaf.fill" : "number",
                        isSelected: scope == pinScope,
                        showIndentLine: false,
                        onRemovePin: { togglePin(pin) }) {
                        select(pinScope)
                    }
                }
            }
        }
    }

    private func pinDisplayTitle(_ pin: ThoughtSidebarPin) -> String {
        switch pin.kind {
        case .topic:
            return topics.first { $0.id == pin.topicID }?.title ?? ""
        case .userTag:
            guard let key = pin.tagPathKey else { return "" }
            let display = tagDisplayByKey[key] ?? key
            // 置顶行同样显示 emoji 图标（与标签树一致）
            if let emoji = ThoughtTagEmojiStore.emoji(forKey: key) {
                return "\(emoji) \(display)"
            }
            return display
        }
    }

    // MARK: - 主题

    private var topicsSection: some View {
        sidebarGroup(
            title: String(localized: "主题"),
            subtitle: String(localized: "Holo 串起的长期方向"),
            emptyText: String(localized: "同类想法记多了会自动聚成主题，也可在「想法设置」里手动新建")) {
            ForEach(topics, id: \.id) { topic in
                sidebarRow(
                    title: topic.title,
                    icon: "leaf.fill",
                    tint: .holoSuccess,
                    isSelected: scope == .topic(topic.id),
                    showIndentLine: false,
                    subtitle: String(localized: "\(ThoughtTopicLinkProjection.effectiveActiveThoughtCount(of: topic)) 条想法"),
                    onRemovePin: { togglePin(.init(kind: .topic, topicID: topic.id, tagPathKey: nil)) }) {
                    select(.topic(topic.id))
                }
            }
            if let cluster = suggestedCluster {
                suggestedClusterRow(cluster)
            }

        }
    }

    /// 主题候选建议行（方案 §5.3：轻量建议 + 建立/忽略，不建待审核任务箱）
    private func suggestedClusterRow(_ cluster: ThoughtSemanticStore.ClusterRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(.holoToolAction)
            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.name?.isEmpty == false ? cluster.name! : "新的主题方向")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                Text("\(cluster.memberIDs.count) 条相关想法")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await establishSuggestedTopic(cluster) }
            } label: {
                Text("建立")
                    .font(.holoTinyLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.holoToolAction.opacity(0.75)))
            }
            .buttonStyle(.plain)
            Button {
                Task { await dismissSuggestedCluster(cluster, rejected: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "忽略这个主题建议"))
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md)
            .fill(Color.holoToolAction.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "主题建议：\(cluster.name ?? "")，\(cluster.memberIDs.count) 条想法"))
    }

    @MainActor
    private func establishSuggestedTopic(_ cluster: ThoughtSemanticStore.ClusterRecord) async {
        let title = (cluster.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try topicRepository.createTopicFromSuggestion(
                title: title, isUserNamed: false, thoughtIds: cluster.memberIDs)
            if let store = await ThoughtSemanticPipeline.shared.store {
                try? await store.upsertCluster(id: cluster.id, fingerprint: cluster.fingerprint,
                                               memberIDs: cluster.memberIDs, state: "converted",
                                               cohesion: cluster.cohesion, name: cluster.name,
                                               dismissedUntil: nil)
            }
            suggestedCluster = nil
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            loadData()
        } catch {
            HoloToastCenter.shared.show(String(localized: "创建失败，请稍后重试"), type: .error)
        }
    }

    @MainActor
    private func dismissSuggestedCluster(_ cluster: ThoughtSemanticStore.ClusterRecord, rejected: Bool) async {
        guard let store = await ThoughtSemanticPipeline.shared.store else { return }
        try? await store.upsertCluster(id: cluster.id, fingerprint: cluster.fingerprint,
                                       memberIDs: cluster.memberIDs, state: rejected ? "rejected" : "snoozed",
                                       cohesion: cluster.cohesion, name: cluster.name,
                                       dismissedUntil: rejected ? nil : Date().addingTimeInterval(Double(ThoughtTopicClusterEngine.snoozeDays) * 86_400))
        suggestedCluster = nil
    }

    // MARK: - 我的 #标签

    private var tagsSection: some View {
        sidebarGroup(
            title: String(localized: "我的 #标签"),
            subtitle: String(localized: "自己标记的找回词"),
            emptyText: String(localized: "在想法里输入 #标签 即可归集")) {
            if tagTree.isEmpty {
                Text("在想法里输入 #标签 即可归集")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 6)
            } else {
                ForEach(tagTree) { node in
                    tagTreeNode(node, depth: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func tagTreeNode(_ node: ThoughtSidebarTagNode, depth: Int) -> some View {
        TagTreeNodeView(
            node: node,
            depth: depth,
            scope: $scope,
            expandedPaths: $expandedPaths,
            onSelect: select,
            onToggleExpanded: toggleExpanded,
            isPinned: isPinned,
            onTogglePin: togglePin)
    }

    /// 标签树节点（独立 struct：func -> some View 直接递归会自引用 opaque 类型，须拆层）
    private struct TagTreeNodeView: View {
        let node: ThoughtSidebarTagNode
        let depth: Int
        @Binding var scope: ThoughtBrowseScope
        @Binding var expandedPaths: Set<String>
        let onSelect: (ThoughtBrowseScope) -> Void
        let onToggleExpanded: (String) -> Void
        let isPinned: (ThoughtSidebarPin) -> Bool
        let onTogglePin: (ThoughtSidebarPin) -> Void

        /// emoji 图标编辑器（flomo 同款：给标签配一个 emoji 前缀）
        @State private var showEmojiEditor = false
        @State private var emojiInput = ""

        private var currentEmoji: String? {
            ThoughtTagEmojiStore.emoji(forKey: node.fullPathKey)
        }

        var body: some View {
            let isExpanded = expandedPaths.contains(node.fullPathKey)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    // 每行只计算一次缩进；深层路径限幅，保留可点击的标签文字宽度。
                    if depth > 0 {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.holoDivider)
                                .frame(width: 1)
                            Spacer().frame(width: 15)
                        }
                        .frame(width: 16, height: 44)
                        .accessibilityHidden(true)
                    }

                    if !node.children.isEmpty {
                        Button {
                            onToggleExpanded(node.fullPathKey)
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? "收起 \(node.displayName)" : "展开 \(node.displayName)")
                    } else {
                        Color.clear.frame(width: 44, height: 1)
                    }

                    Button {
                        onSelect(.userTag(pathKey: node.fullPathKey))
                    } label: {
                        HStack(spacing: 12) {
                            let isSelected = scope == .userTag(pathKey: node.fullPathKey)
                            // 有 emoji 时以图标代替 # 前缀（flomo 同款表达）
                            if let currentEmoji {
                                Text(currentEmoji)
                                    .font(.system(size: 15))
                                Text(node.displayName)
                                    .holoText(.body)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundColor(isSelected ? .holoPrimary : .holoToolText)
                                    .lineLimit(1)
                            } else {
                                Text("#" + node.displayName)
                                    .holoText(.body)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundColor(isSelected ? .holoPrimary : .holoToolText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                        .padding(.trailing, HoloSpacing.sm)
                        .background {
                            if scope == .userTag(pathKey: node.fullPathKey) {
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .fill(Color.holoPrimary.opacity(0.1))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        let pin = ThoughtSidebarPin(kind: .userTag, topicID: nil, tagPathKey: node.fullPathKey)
                        Button {
                            onTogglePin(pin)
                        } label: {
                            if isPinned(pin) {
                                Label("取消置顶", systemImage: "pin.slash")
                            } else {
                                Label("置顶", systemImage: "pin")
                            }
                        }
                        Button {
                            emojiInput = currentEmoji ?? ""
                            showEmojiEditor = true
                        } label: {
                            Label(currentEmoji == nil ? "设置图标…" : "更换图标…", systemImage: "face.smiling")
                        }
                        if currentEmoji != nil {
                            Button(role: .destructive) {
                                ThoughtTagEmojiStore.removeEmoji(forKey: node.fullPathKey)
                            } label: {
                                Label("移除图标", systemImage: "trash")
                            }
                        }
                    }
                    .alert("标签图标", isPresented: $showEmojiEditor) {
                        TextField("粘贴或输入一个 Emoji", text: $emojiInput)
                        Button("保存") {
                            ThoughtTagEmojiStore.setEmoji(emojiInput, forKey: node.fullPathKey)
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("图标会显示在标签树和想法卡片的标签上")
                    }
                }
                .padding(.leading, CGFloat(min(depth, 3) * 16))
                if isExpanded {
                    ForEach(node.children) { child in
                        TagTreeNodeView(
                            node: child,
                            depth: depth + 1,
                            scope: $scope,
                            expandedPaths: $expandedPaths,
                            onSelect: onSelect,
                            onToggleExpanded: onToggleExpanded,
                            isPinned: isPinned,
                            onTogglePin: onTogglePin)
                    }
                }
            }
        }
    }

    // MARK: - 归档（2026-09-25 flomo 改版：升为正式分组，不再与低频工具混在「其他」）

    /// 归档是浏览范围之一（与全部/主题/标签同级），无组标题、单行直达
    private var archivedSection: some View {
        sidebarRow(
            title: String(localized: "已归档"),
            icon: "archivebox",
            isSelected: scope == .archived,
            showIndentLine: false) {
            select(.archived)
        }
    }

    // MARK: - 底部低频工具区

    /// 危险/低频操作不与「全部想法」同级争主导航位（flomo 改版批2：数据清理下沉）
    private var bottomToolsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Divider()
            Button {
                showClearThoughtSheet = true
            } label: {
                Label("数据清理…", systemImage: "trash")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .padding(.horizontal, HoloSpacing.sm)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 复用件

    private func sidebarGroup<Content: View>(title: String,
                                              subtitle: String? = nil,
                                              emptyText: String = "",
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                // P1 §3.1 身份说明：一句话讲清这组入口「是谁的」（标签=你写的 / 主题=Holo 串的）
                if let subtitle {
                    Text(subtitle)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HoloSpacing.sm)
            .padding(.bottom, 2)
            content()
        }
    }

    private func sidebarRow(title: String,
                            icon: String,
                            tint: Color = .holoToolText,
                            isSelected: Bool,
                            showIndentLine: Bool = true,
                            subtitle: String? = nil,
                            onRemovePin: (() -> Void)? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .holoPrimary : tint == .holoToolText ? .holoToolTextSecondary : tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .holoText(.body)
                        // 选中态不只靠颜色（深色模式/色觉友好），字重同步变化
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(isSelected ? .holoPrimary : .holoToolText)
                        .lineLimit(1)
                    // P1 §3.1 主题行副标题：成员数（与侧栏计数/详情同口径的投影计数）
                    if let subtitle {
                        Text(subtitle)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextPlaceholder)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HoloSpacing.sm)
            .frame(minHeight: 44, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(Color.holoPrimary.opacity(0.1))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRemovePin {
                pinMenuButton(for: nil, customAction: onRemovePin)
            }
        }
    }

    /// 置顶/取消置顶菜单项（原节点 contextMenu 入口，§5.6：不由 AI 自动置顶）
    @ViewBuilder
    private func pinMenuButton(for pin: ThoughtSidebarPin?, customAction: (() -> Void)? = nil) -> some View {
        Button {
            if let customAction {
                customAction()
            } else if let pin {
                togglePin(pin)
            }
        } label: {
            if let pin, isPinned(pin) {
                Label("取消置顶", systemImage: "pin.slash")
            } else {
                Label("置顶", systemImage: "pin")
            }
        }
    }

    private func isPinned(_ pin: ThoughtSidebarPin) -> Bool {
        pins.contains { $0.id == pin.id }
    }

    private func togglePin(_ pin: ThoughtSidebarPin) {
        if isPinned(pin) {
            pins.removeAll { $0.id == pin.id }
        } else {
            pins.append(pin)
        }
        ThoughtSidebarPreference.savePins(pins)
    }

    private func toggleExpanded(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
        ThoughtSidebarPreference.saveExpandedTagPaths(expandedPaths)
    }

    private func select(_ newScope: ThoughtBrowseScope) {
        scope = newScope
        HapticManager.light()
        onSelect()
    }
}
