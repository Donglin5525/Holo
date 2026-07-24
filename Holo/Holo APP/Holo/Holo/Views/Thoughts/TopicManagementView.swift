//
//  TopicManagementView.swift
//  Holo
//
//  用户分类主题管理：启用、创建、改名、合并、删除和未归类重跑。
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
                    Label("新建分类主题", systemImage: "plus.circle")
                        .foregroundColor(.holoPrimary)
                }
            } header: {
                Text("分类主题")
            } footer: {
                Text("只有开启的主题会进入 HoloAI 的分类约束；历史主题默认关闭。")
            }

            Section {
                Button {
                    reorganizeUnclassified()
                } label: {
                    Label("重新整理未归类想法", systemImage: "sparkles")
                        .foregroundColor(.holoPrimary)
                }
                .disabled(!topics.contains(where: \.isClassificationTopic))
            } footer: {
                Text("会消耗 AI 配额，并在后台重新选择已启用主题。")
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .navigationTitle("管理分类主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task { loadTopics() }
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
            Text("相关 AI 标签路径会同步更新。")
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
            Image(systemName: topic.isClassificationTopic ? "folder.fill" : "folder")
                .foregroundColor(topic.isClassificationTopic ? .holoPrimary : .holoTextSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .foregroundColor(.holoTextPrimary)
                Text("\(topicRepository.thoughtCount(of: topic)) 条想法")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { topic.isClassificationTopic },
                set: { setEnabled(topic, $0) }
            ))
            .labelsHidden()
            .tint(.holoPrimary)
        }
        .contentShape(Rectangle())
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
            if $0.isClassificationTopic != $1.isClassificationTopic { return $0.isClassificationTopic }
            return $0.title < $1.title
        }
    }

    private func setEnabled(_ topic: Topic, _ isEnabled: Bool) {
        do {
            try topicRepository.setClassificationEnabled(topic, isEnabled: isEnabled)
            notice = isEnabled ? "已启用「\(topic.title)」" : "已停用「\(topic.title)」"
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "更新失败，请稍后重试"
        }
    }

    private func createTopic() {
        let title = ThoughtTagNormalizer.displayName(newTitle)
        guard !title.isEmpty else { return }
        do {
            _ = try topicRepository.createClassificationTopic(title: title)
            notice = "已创建并启用「\(title)」"
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "创建失败，请换一个名称"
        }
    }

    private func renameTopic() {
        guard let topic = renameTarget else { return }
        defer { renameTarget = nil }
        do {
            try topicRepository.renameClassificationTopic(topic, to: renameTitle)
            notice = "主题和标签路径已同步更新"
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "重命名失败，请换一个名称"
        }
    }

    private func mergeTopic(into target: Topic) {
        guard let source = mergeSource else { return }
        mergeSource = nil
        do {
            try topicRepository.mergeClassificationTopics(into: target, from: source)
            notice = "已合并到「\(target.title)」"
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "合并失败，请稍后重试"
        }
    }

    private func deleteTopic() {
        guard let topic = deleteTarget else { return }
        deleteTarget = nil
        do {
            let result = try topicRepository.deleteClassificationTopic(topic)
            notice = "已删除「\(result.title)」，\(result.removedThoughtCount) 条想法回到未归类"
            loadTopics()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            notice = "删除失败，请稍后重试"
        }
    }

    private func reorganizeUnclassified() {
        do {
            let ids = try thoughtRepository.fetchUnclassifiedThoughts().map(\.id)
            guard !ids.isEmpty else {
                notice = "当前没有未归类想法"
                return
            }
            try thoughtRepository.markBatchPending(thoughtIds: ids)
            ThoughtOrganizationQueue.shared.enqueueBatch(thoughtIds: ids)
            notice = "已开始重新整理 \(ids.count) 条想法"
        } catch {
            notice = "启动整理失败，请稍后重试"
        }
    }
}

