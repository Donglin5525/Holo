//
//  TopicPickerView.swift
//  Holo
//
//  移入主题选择器（P1.5.6）
//  用户把观点移入已有主题，或新建主题并移入
//

import SwiftUI

struct TopicPickerView: View {

    let thoughtId: UUID
    let topicRepository: TopicRepository
    /// 移入完成回调（调用方刷新列表/抽屉）
    let onAssigned: () -> Void
    /// 允许「移出到未归类」（想法已有分类主题时显示 destructive 行）
    var allowsRemove: Bool = false

    @State private var topics: [Topic] = []
    @State private var newTopicTitle: String = ""
    @State private var showNewTopicInput: Bool = false
    /// 该想法当前的分类主题（决定是否显示「移出」）
    @State private var currentTopicId: UUID? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showNewTopicInput {
                    HStack(spacing: HoloSpacing.sm) {
                        TextField("主题名", text: $newTopicTitle)
                            .font(.holoCaption)
                            .padding(.horizontal, HoloSpacing.sm)
                            .padding(.vertical, 8)
                            .background(Color.holoCardBackground)
                            .cornerRadius(HoloRadius.md)

                        Button {
                            createAndAssign()
                        } label: {
                            Text("创建并移入")
                                .font(.holoCaption)
                                .foregroundColor(.white)
                                .padding(.horizontal, HoloSpacing.md)
                                .padding(.vertical, 8)
                                .background(newTopicTitle.isEmpty ? Color.gray : Color.holoPrimary)
                                .cornerRadius(HoloRadius.md)
                        }
                        .disabled(newTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)
                }

                if topics.isEmpty && !showNewTopicInput {
                    VStack(spacing: HoloSpacing.sm) {
                        Image(systemName: "folder")
                            .font(.system(size: 30))
                            .foregroundColor(.holoPrimary)
                        Text("暂无主题")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                        Text("点右上角「新建」创建第一个主题")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(topics, id: \.id) { topic in
                            Button {
                                assign(to: topic.id)
                            } label: {
                                HStack {
                                    Text(TopicIconProvider.icon(for: topic))
                                        .font(.system(size: 17))
                                        .frame(width: 26)
                                    Text(topic.title)
                                        .foregroundColor(.holoTextPrimary)
                                    Spacer()
                                    if topic.id == currentTopicId {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.holoPrimary)
                                    }
                                    Text("\(topicRepository.thoughtCount(of: topic))")
                                        .font(.holoLabel)
                                        .foregroundColor(.holoTextSecondary)
                                }
                            }
                        }

                        if allowsRemove, currentTopicId != nil {
                            Button(role: .destructive) {
                                removeFromCurrentTopic()
                            } label: {
                                Label("移出到未归类", systemImage: "square.dashed")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("移入主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(showNewTopicInput ? "列表" : "新建") {
                        showNewTopicInput.toggle()
                        if !showNewTopicInput { newTopicTitle = "" }
                    }
                }
            }
        }
        .task { await loadTopics() }
    }

    private func loadTopics() async {
        topics = (try? topicRepository.fetchClassificationTopics()) ?? []
        currentTopicId = (try? topicRepository.fetchThoughtClassificationTopicId(thoughtId)) ?? nil
    }

    private func assign(to topicId: UUID) {
        do {
            try topicRepository.assign(thoughtId: thoughtId, toTopic: topicId)
            onAssigned()
            dismiss()
        } catch {
            // 容错：保持当前界面
        }
    }

    /// 移出到未归类：摘除分类主题关系，置信度归零
    private func removeFromCurrentTopic() {
        guard let topicId = currentTopicId else { return }
        do {
            try topicRepository.remove(thoughtId: thoughtId, fromTopic: topicId)
            onAssigned()
            dismiss()
        } catch {
            // 容错：保持当前界面
        }
    }

    private func createAndAssign() {
        let title = newTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let topic = try topicRepository.createClassificationTopic(title: title)
            try topicRepository.assign(thoughtId: thoughtId, toTopic: topic.id)
            onAssigned()
            dismiss()
        } catch {
            // 容错
        }
    }
}
