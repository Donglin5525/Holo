//
//  MatterChatContextUI.swift
//  Holo
//
//  Matter 内对话的轻量 UI 件（方案 §13.5/§3.2）：
//  - 顶部胶囊：标识「正在聊这件事」，点 ✕ 退出（之后不再自动关联）
//  - 自动更新回执：「✓ 已更新到「…」· 撤销」，几秒后自动消失
//  - 歧义追问条：「你说的是东京还是京都？」，点选项即按用户语义更新
//

import SwiftUI

extension ChatView {

    // MARK: - 顶部胶囊

    @MainActor
    func matterContextPill(_ context: HoloMatterConversationContext) -> some View {
        let title = HoloMatterRepository.shared.matter(id: context.matterID)?.title ?? ""
        return HStack(spacing: 6) {
            Image(systemName: "pin.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.holoPrimary)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Button {
                matterChatStore.exit()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "退出这件事的上下文"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
        .padding(.top, 6)
        .transition(.opacity)
    }

    // MARK: - 自动更新回执

    @MainActor
    func matterFeedbackToast(_ feedback: MatterChatContextStore.MatterFeedback) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "已更新到「\(feedback.matterTitle)」"))
                    .font(.caption.weight(.semibold))
                ForEach(feedback.summaries, id: \.self) { summary in
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let eventID = feedback.revertEventID {
                Button(String(localized: "撤销")) {
                    Task {
                        try? await HoloMatterRepository.shared.revertEvent(eventID: eventID)
                        matterChatStore.lastFeedback = nil
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }
            Button {
                matterChatStore.lastFeedback = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.09))
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task {
            // 无操作 6 秒自动收起
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation { matterChatStore.lastFeedback = nil }
        }
    }

    // MARK: - 歧义追问

    @MainActor
    func matterAmbiguityBar(_ ambiguity: HoloMatterAmbiguity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ambiguity.question)
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(ambiguity.options) { option in
                    Button {
                        resolveAmbiguity(ambiguity, option: option)
                    } label: {
                        Text(option.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().strokeBorder(Color.holoPrimary, lineWidth: 1.2))
                            .foregroundStyle(Color.holoPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @MainActor
    private func resolveAmbiguity(_ ambiguity: HoloMatterAmbiguity, option: HoloMatterAmbiguityOption) {
        guard let matterContext = matterChatStore.active else { return }
        matterChatStore.pendingAmbiguity = nil
        guard let loopID = option.openLoopID else { return }
        Task { @MainActor in
            // 用户亲手点选 = 用户显式语义（§6.2 一次确认），按 resolved 落盘并给回执
            try? await HoloMatterRepository.shared.setOpenLoopState(
                id: loopID, state: .resolved, actor: .user,
                sourceRevision: ambiguity.id, sourceType: "chatMessage"
            )
            let matterTitle = HoloMatterRepository.shared.matter(id: matterContext.matterID)?.title ?? ""
            let coordinator = HoloMatterReconciliationCoordinator()
            await coordinator.refreshProjection(matterID: matterContext.matterID)
            matterChatStore.lastFeedback = MatterChatContextStore.MatterFeedback(
                matterTitle: matterTitle,
                summaries: [String(localized: "已解决「\(option.title)」")],
                revertEventID: nil
            )
        }
    }
}
