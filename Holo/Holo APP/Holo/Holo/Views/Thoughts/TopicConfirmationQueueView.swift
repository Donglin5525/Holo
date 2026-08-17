//
//  TopicConfirmationQueueView.swift
//  Holo
//
//  知识树 v1 · 待确认池
//  AI 低置信度（<0.75）的主题归属集中轻确认：「放这里」或「换一个」
//  方案：docs/thoughts/plans/2026-08-15-knowledge-tree-mainline-v1.md §4.4
//

import SwiftUI

struct TopicConfirmationQueueView: View {

    let thoughtRepository: ThoughtRepository
    let topicRepository: TopicRepository
    /// 全部处理完的回调（调用方刷新待确认计数）
    var onQueueDrained: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var thoughts: [Thought] = []
    @State private var hasLoaded = false
    @State private var pickerThoughtId: UUID? = nil
    @State private var notice: String? = nil

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if !hasLoaded {
                        // 首帧占位，避免空态闪现
                        Color.clear.frame(height: 200)
                    } else if thoughts.isEmpty {
                        emptyState
                    } else {
                        Text("AI 对下面 \(thoughts.count) 条想法的主题归属不太有把握，选一下它们该去的书架。确认后类似内容会更准。")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .padding(.horizontal, HoloSpacing.xs)

                        ForEach(thoughts) { thought in
                            confirmCard(thought)
                        }
                    }
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
            }
            .background(Color.holoBackground)
            .navigationTitle("待确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") { dismiss() }
                        .foregroundColor(.holoPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !thoughts.isEmpty {
                        Button("全部跳过") { dismiss() }
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .overlay(alignment: .top) { noticeToast }
            .sheet(item: $pickerThoughtId) { thoughtId in
                TopicPickerView(
                    thoughtId: thoughtId,
                    topicRepository: topicRepository,
                    onAssigned: { handleReassigned(thoughtId) },
                    allowsRemove: true
                )
            }
        }
        .task { await loadThoughts() }
    }

    // MARK: - 数据

    @MainActor
    private func loadThoughts() async {
        thoughts = (try? thoughtRepository.fetchThoughtsPendingTopicConfirmation()) ?? []
        hasLoaded = true
    }

    /// 处理完一条：移出队列；清空后通知调用方
    private func settle(_ thoughtId: UUID, confirmed: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) {
            thoughts.removeAll { $0.id == thoughtId }
        }
        if confirmed {
            notice = "已确认，AI 会记住你的判断"
        }
        if thoughts.isEmpty {
            onQueueDrained?()
        }
    }

    /// TopicPickerView 里换主题/移出到未归类都视为已处理
    private func handleReassigned(_ thoughtId: UUID) {
        settle(thoughtId, confirmed: false)
    }

    // MARK: - 确认卡片

    private func confirmCard(_ thought: Thought) -> some View {
        let confidence = min(max(thought.topicConfidence, 0), 1)
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ReadOnlyRichTextPreview(
                nodes: RichContentSerializer.nodes(
                    richJSON: thought.richContentJSON,
                    fallbackPlainText: thought.content
                ),
                lineLimit: 5
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            suggestBox(thought: thought, confidence: confidence)

            HStack(spacing: HoloSpacing.sm) {
                Button {
                    pickerThoughtId = thought.id
                } label: {
                    Text("换一个")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.holoNestedCardBackground)
                        .cornerRadius(HoloRadius.md)
                }
                .buttonStyle(.plain)

                Button {
                    confirmPlacement(thought)
                } label: {
                    Text("放这里")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.holoSuccess)
                        .cornerRadius(HoloRadius.md)
                }
                .buttonStyle(.plain)
            }
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

    /// AI 建议区：当前主题 + 一句话理由 + 置信度
    private func suggestBox(thought: Thought, confidence: Double) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Text(thought.classificationTopic.map { TopicIconProvider.icon(for: $0) } ?? "📥")
                    .font(.system(size: 15))
                Text(thought.classificationTopic?.title ?? "未归类")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundColor(.holoAI)
                    Text("AI 建议")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoAI)
                }
            }

            if let reason = thought.topicAssignmentReason, !reason.isEmpty {
                Text(reason)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: HoloSpacing.sm) {
                ConfidenceBar(value: confidence)
                Text("把握 \(Int(confidence * 100))%")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoAI.opacity(0.08))
        )
    }

    // MARK: - 动作

    private func confirmPlacement(_ thought: Thought) {
        do {
            try thoughtRepository.confirmTopicAssignment(thoughtId: thought.id)
            ThoughtClassificationFeedbackStore.log(
                .topicConfirm, thoughtId: thought.id, tagName: "",
                topicConfidence: thought.topicConfidence
            )
            HapticManager.light()
            settle(thought.id, confirmed: true)
        } catch {
            HoloToastCenter.shared.show("操作失败，请重试", type: .error)
        }
    }

    // MARK: - 空态 / toast

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundColor(.holoSuccess.opacity(0.8))
            Text("都确认完了")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            Text("AI 把握不足的想法都已处理，\n你的确认会持续让分类越来越准。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HoloSpacing.xxl)
    }

    private var noticeToast: some View {
        Group {
            if let notice {
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
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation(.easeInOut) { self.notice = nil }
                    }
            }
        }
    }
}

// MARK: - 置信度条

/// AI 把握度可视化（紫色进度条）
struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoTextSecondary.opacity(0.15))
                Capsule()
                    .fill(Color.holoAI)
                    .frame(width: geo.size.width * value)
            }
        }
        .frame(width: 88, height: 5)
    }
}

// MARK: - Preview

#Preview {
    Text("TopicConfirmationQueueView 需要 Core Data context")
}
