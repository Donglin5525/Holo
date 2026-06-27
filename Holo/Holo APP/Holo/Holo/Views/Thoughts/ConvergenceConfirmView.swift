//
//  ConvergenceConfirmView.swift
//  Holo
//
//  跨观点归并建议确认页（P2.3）
//  展示 AI 收敛建议（主题名/关联观点数/来源词/理由），用户逐条操作：
//  确认归并（applyConvergence）/ 改名后确认 / 拒绝（写建议级拒绝）/ 暂不
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md §6.3
//

import SwiftUI

struct ConvergenceConfirmView: View {

    @ObservedObject var job: ThoughtTagConvergenceJob
    let topicRepository: TopicRepository
    let rejectionRepository: ConvergenceRejectionRepository

    @Environment(\.dismiss) private var dismiss
    @State private var processedIds: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            content
                .navigationTitle("AI 主题归并")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            job.reset()
                            dismiss()
                        }
                    }
                }
                .alert("操作失败", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("好", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    // MARK: - 状态分支

    @ViewBuilder
    private var content: some View {
        switch job.state {
        case .idle:
            idleView
        case .generating:
            generatingView
        case .failed(let message):
            failedView(message)
        case .ready(let suggestions):
            if suggestions.isEmpty {
                // AI 没给建议（数据不足或无主题）——不是"处理成功"，避免误导
                noSuggestionView
            } else {
                let pending = suggestions.filter { !processedIds.contains($0.id) }
                if pending.isEmpty {
                    doneView
                } else {
                    suggestionsList(pending)
                }
            }
        }
    }

    // MARK: - generating

    private var generatingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
                .scaleEffect(1.2)
            Text("AI 正在分析你的观点…")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - idle（输入不足或未触发）

    private var idleView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(.holoAI)
            Text("观点还不足够形成主题")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Text("继续记录，AI 会自动发现可归并的长期主题。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await job.run() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - done（全部处理完）

    private var doneView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.holoPrimary)
            Text("建议已处理完")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Button("完成") {
                job.reset()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 无建议（AI 未发现可归并主题，非"处理成功"）

    private var noSuggestionView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(.holoAI)
            Text("暂未发现可归并的主题")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Text("继续积累观点，AI 会自动发现长期主题。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
            Button("关闭") {
                job.reset()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 建议列表

    private func suggestionsList(_ suggestions: [ConvergenceSuggestion]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                ForEach(suggestions) { suggestion in
                    ConvergenceSuggestionCard(
                        suggestion: suggestion,
                        onConfirm: { renamedTitle in confirm(suggestion, renamedTitle: renamedTitle) },
                        onReject: { reject(suggestion) },
                        onSkip: { skip(suggestion) }
                    )
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    // MARK: - 操作

    private func confirm(_ suggestion: ConvergenceSuggestion, renamedTitle: String?) {
        do {
            _ = try topicRepository.applyConvergence(
                matchedTopicId: suggestion.matchedTopicId,
                topicTitle: renamedTitle ?? suggestion.topicTitle,
                thoughtIds: suggestion.thoughtIds,
                sourceTerms: suggestion.sourceTerms
            )
            processedIds.insert(suggestion.id)
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            errorMessage = "归并失败，请重试"
        }
    }

    private func reject(_ suggestion: ConvergenceSuggestion) {
        try? rejectionRepository.reject(topicTitle: suggestion.topicTitle, sourceTerms: suggestion.sourceTerms)
        processedIds.insert(suggestion.id)
    }

    private func skip(_ suggestion: ConvergenceSuggestion) {
        processedIds.insert(suggestion.id)
    }
}

// MARK: - 单条建议卡片

private struct ConvergenceSuggestionCard: View {
    let suggestion: ConvergenceSuggestion
    let onConfirm: (String?) -> Void
    let onReject: () -> Void
    let onSkip: () -> Void

    @State private var isRenaming = false
    @State private var renamedTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 主题名 / 改名输入
            if isRenaming {
                HStack(spacing: HoloSpacing.xs) {
                    TextField("主题名", text: $renamedTitle)
                        .font(.holoHeading)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let trimmed = renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onConfirm(trimmed)
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.holoPrimary)
                    }
                    Button {
                        isRenaming = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            } else {
                HStack(spacing: HoloSpacing.xs) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16))
                        .foregroundColor(.holoAI)
                    Text(suggestion.topicTitle)
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Button {
                        renamedTitle = suggestion.topicTitle
                        isRenaming = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            // 关联观点数
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                Text("关联 \(suggestion.thoughtIds.count) 条观点")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 来源词
            if !suggestion.sourceTerms.isEmpty {
                FlowingTagChips(tags: suggestion.sourceTerms)
            }

            // 理由
            if !suggestion.reason.isEmpty {
                Text(suggestion.reason)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(3)
            }

            // 操作按钮
            HStack(spacing: HoloSpacing.sm) {
                Button {
                    onConfirm(nil)
                } label: {
                    Text("确认归并")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.xs)
                        .background(Color.holoPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                }

                Button {
                    onSkip()
                } label: {
                    Text("暂不")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.xs)
                        .background(Color.holoBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                }

                Button {
                    onReject()
                } label: {
                    Text("拒绝")
                        .font(.holoBody)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.xs)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                }
            }
            .padding(.top, HoloSpacing.xs)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: Color.black.opacity(0.04), radius: 4, y: 2)
    }
}

// MARK: - 来源词标签流式布局

private struct FlowingTagChips: View {
    let tags: [String]

    var body: some View {
        WrappingHStack(items: tags)
    }
}

/// 简单换行的标签容器（来源词展示）
private struct WrappingHStack: View {
    let items: [String]

    var body: some View {
        // 用 LazyVGrid 近似流式（固定列宽自适应）
        let columns = [GridItem(.adaptive(minimum: 60), spacing: HoloSpacing.xs)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: HoloSpacing.xs) {
            ForEach(items, id: \.self) { tag in
                Text(tag)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoAI)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 3)
                    .background(Color.holoAI.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }
}
