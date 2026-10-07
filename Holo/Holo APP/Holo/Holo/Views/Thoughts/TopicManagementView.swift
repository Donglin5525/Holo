//
//  TopicManagementView.swift
//  Holo
//
//  主题管理：创建、改名、合并与删除。自动整理开关和补跑统一在想法设置。
//

import SwiftUI

struct TopicManagementView: View {
    private let topicRepository: TopicRepository
    private let thoughtRepository: ThoughtRepository

    @Environment(\.dismiss) private var dismiss
    @State private var topics: [Topic] = []
    @State private var newTitle = ""
    @State private var renameTitle = ""
    @State private var addPresented = false
    @State private var renameTarget: Topic?
    @State private var deleteTarget: Topic?
    @State private var mergeSource: Topic?
    @State private var mergePresented = false
    @State private var notice: String?
    /// 点行进入的主题详情（fullScreenCover，与知识树/列表页同一弹出方式）
    @State private var selectedTopicId: UUID?

    init(
        topicRepository: TopicRepository = TopicRepository(),
        thoughtRepository: ThoughtRepository = ThoughtRepository()
    ) {
        self.topicRepository = topicRepository
        self.thoughtRepository = thoughtRepository
    }

    var body: some View {
        List {
            Section {
                if topics.isEmpty {
                    Text("还没有主题，先创建一个长期关注方向。")
                        .foregroundColor(.holoTextSecondary)
                } else {
                    ForEach(topics, id: \.id) { topic in
                        topicRow(topic)
                    }
                }

                Button {
                    newTitle = ""
                    addPresented = true
                } label: {
                    Label("新建主题", systemImage: "plus.circle")
                        .foregroundColor(.holoPrimary)
                }
            } header: {
                Text("全部主题")
            } footer: {
                Text("智能整理开启时，Holo 会核对笔记与这些主题的关系。自动整理开关、处理进度和补跑统一在想法设置中。")
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .navigationTitle("主题管理")
        .navigationBarTitleDisplayMode(.inline)
        .holoSheetShell()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task { loadTopics() }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            loadTopics()
        }
        .fullScreenCover(item: $selectedTopicId, onDismiss: { loadTopics() }) { topicId in
            TopicDetailView(
                topicId: topicId,
                topicRepository: topicRepository,
                thoughtRepository: thoughtRepository,
                onTopicDeleted: { selectedTopicId = nil }
            )
            .holoContentColumn()
        }
        .alert("新建主题", isPresented: $addPresented) {
            TextField("主题名称", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("创建") { createTopic() }
        } message: {
            Text("主题应是长期关注方向，而不是一次性关键词。")
        }
        .alert("重命名主题", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("主题名称", text: $renameTitle)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") { renameTopic() }
        } message: {
            Text("主题名称会更新，笔记中的手动标签保留。")
        }
        .alert("删除主题", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) { deleteTopic() }
        } message: {
            Text("该主题下的想法会回到未归类，手动标签不会被删除。")
        }
        .confirmationDialog("合并到哪个主题？", isPresented: $mergePresented, titleVisibility: .visible) {
            ForEach(topics.filter { $0.id != mergeSource?.id }, id: \.id) { target in
                Button(target.title) { mergeTopic(into: target) }
            }
            Button("取消", role: .cancel) { mergeSource = nil }
        }
    }

    private func topicRow(_ topic: Topic) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Text(TopicIconProvider.icon(for: topic))
                .font(.system(size: 17))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .foregroundColor(.holoTextPrimary)
                Text("\(topicRepository.thoughtCount(of: topic)) 条想法")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedTopicId = topic.id }
        .contextMenu {
            Button {
                renameTarget = topic
                renameTitle = topic.title
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            if topics.count > 1 {
                Button {
                    mergeSource = topic
                    mergePresented = true
                } label: {
                    Label("合并到…", systemImage: "arrow.triangle.merge")
                }
            }
            Button(role: .destructive) {
                deleteTarget = topic
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func loadTopics() {
        topics = ((try? topicRepository.fetchVisibleTopics()) ?? []).sorted {
            return $0.title < $1.title
        }
    }

    private func createTopic() {
        let title = ThoughtTagNormalizer.displayName(newTitle)
        guard !title.isEmpty else { return }
        do {
            let topic = try topicRepository.getOrCreateTopic(title: title)
            topic.titleSource = "user"
            try topicRepository.activate(topic)
            notice = String(localized: "已创建「\(title)」；Holo 会核对已有和新记录的笔记")
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = String(localized: "创建失败，请换一个名称")
        }
    }

    private func renameTopic() {
        guard let topic = renameTarget else { return }
        defer { renameTarget = nil }
        do {
            try topicRepository.renameClassificationTopic(topic, to: renameTitle)
            notice = String(localized: "主题名称已更新")
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = String(localized: "重命名失败，请换一个名称")
        }
    }

    private func mergeTopic(into target: Topic) {
        guard let source = mergeSource else { return }
        mergeSource = nil
        do {
            try topicRepository.merge(into: target, from: source)
            notice = String(localized: "已合并到「\(target.title)」")
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = String(localized: "合并失败，请稍后重试")
        }
    }

    private func deleteTopic() {
        guard let topic = deleteTarget else { return }
        deleteTarget = nil
        do {
            try ConvergenceRejectionRepository().reject(topicTitle: topic.title, sourceTerms: [])
            let result = try topicRepository.deleteClassificationTopic(topic)
            notice = String(localized: "已删除「\(result.title)」，\(result.removedThoughtCount) 条想法回到未归类")
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = String(localized: "删除失败，请稍后重试")
        }
    }

}
