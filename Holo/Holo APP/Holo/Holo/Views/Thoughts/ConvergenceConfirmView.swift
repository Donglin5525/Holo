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
        NavigationStack {
            content
                .holoSheetShell()
                .navigationTitle("发现新主题")
                #if canImport(UIKit)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            job.reset()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.holoToolText)
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .accessibilityLabel(String(localized: "关闭"))
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

    /// 全屏状态页统一三区结构（§8.7 类型 6 修复）：内容居中，主操作贴底不再悬空。
    @ViewBuilder
    private func statusPage<Content: View, Action: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: HoloSpacing.xl)
            content()
            Spacer(minLength: HoloSpacing.xl)
            action()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.lg)
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
        case .unchanged:
            unchangedView
        case .failed(let message):
            failedView(message)
        case .ready(let suggestions):
            if suggestions.isEmpty {
                if processedIds.isEmpty {
                    // AI 没给建议（数据不足或无主题）——不是"处理成功"，避免误导
                    noSuggestionView
                } else {
                    doneView
                }
            } else {
                let pending = suggestions.filter { !processedIds.contains($0.id) }
                if pending.isEmpty {
                    doneView
                } else {
                    suggestionsList(pending)
                }
            }
        case .applied(let count):
            appliedView(count)
        }
    }

    // MARK: - generating

    private var generatingView: some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(Color.holoToolAction)
                Text("AI 正在分析你的想法…")
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
            }
        } action: {
            EmptyView()
        }
    }

    // MARK: - idle（输入不足或未触发）

    private var idleView: some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                statusIcon("sparkles")
                Text("想法还不足够形成主题")
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Text("继续记录，AI 会自动发现可归并的长期主题。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
        } action: {
            EmptyView()
        }
    }

    /// 状态页统一图标规格（原六处图标 36/40/44 三种尺寸）
    private func statusIcon(_ systemName: String, tint: Color = .holoToolAction) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 40))
            .foregroundColor(tint)
            .accessibilityHidden(true)
    }

    // MARK: - unchanged（输入未变化，省掉重复 AI 调用）

    private var unchangedView: some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                statusIcon("checkmark.seal.fill")
                Text("没有新的可归纳变化")
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Text("上次归纳后，想法、标签和主题没有变化，本次已跳过 AI 调用。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
        } action: {
            Button("关闭") {
                job.reset()
                dismiss()
            }
            .buttonStyle(HoloActionStyle(role: .primary))
        }
    }

    // MARK: - failed

    private func failedView(_ message: String) -> some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                statusIcon("exclamationmark.triangle", tint: .holoToolWarning)
                Text(message)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                    .multilineTextAlignment(.center)
            }
        } action: {
            Button("重试") {
                Task { await job.run() }
            }
            .buttonStyle(HoloActionStyle(role: .primary))
        }
    }

    // MARK: - done（全部处理完）

    private var doneView: some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                statusIcon("checkmark.circle.fill")
                Text("建议已处理完")
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
            }
        } action: {
            Button("完成") {
                job.completeReview()
                dismiss()
            }
            .buttonStyle(HoloActionStyle(role: .primary))
        }
    }

    // MARK: - 自动应用完成

    private func appliedView(_ count: Int) -> some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                statusIcon("folder.badge.plus")
                Text("已生成 \(count) 个主题")
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Text("这些主题已经出现在你的主题列表里。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
        } action: {
            Button("完成") {
                job.reset()
                dismiss()
            }
            .buttonStyle(HoloActionStyle(role: .primary))
        }
    }

    // MARK: - 无建议（AI 未发现可归并主题，非"处理成功"）

    private var noSuggestionView: some View {
        statusPage {
            VStack(spacing: HoloSpacing.md) {
                statusIcon("sparkles")
                Text("暂未发现可归并的主题")
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                Text("继续积累想法，AI 会自动发现长期主题。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
        } action: {
            Button("关闭") {
                job.reset()
                dismiss()
            }
            .buttonStyle(HoloActionStyle(role: .primary))
        }
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
            job.markSuggestionReviewed(suggestion.id)
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            errorMessage = String(localized: "归并失败，请重试")
        }
    }

    private func reject(_ suggestion: ConvergenceSuggestion) {
        try? rejectionRepository.reject(topicTitle: suggestion.topicTitle, sourceTerms: suggestion.sourceTerms)
        processedIds.insert(suggestion.id)
        job.markSuggestionReviewed(suggestion.id)
    }

    private func skip(_ suggestion: ConvergenceSuggestion) {
        processedIds.insert(suggestion.id)
        job.markSuggestionReviewed(suggestion.id)
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
                        .foregroundColor(.holoPrimary)
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
                Text("关联 \(suggestion.thoughtIds.count) 条想法")
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
                        .foregroundColor(.holoToolError)
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
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 3)
                    .background(Color.holoBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.holoDivider, lineWidth: 1)
                    )
            }
        }
    }
}
