//
//  MatterChatContextUI.swift
//  Holo
//
//  Matter 内对话的轻量 UI 件（方案 §13.5/§3.2）：
//  - 顶部胶囊：标识「正在聊这件事」，点 ✕ 退出（之后不再自动关联）
//  - 自动更新回执：「✓ 已更新到「…」· 撤销」，几秒后自动消失
//  - 歧义追问条：「你说的是东京还是京都？」，点选项即按用户语义更新
//
//  三个 UI 件为独立 struct（体积边界，2026-09-17 真机栈溢出二修）；
//  动作与落库逻辑经闭包回调 ChatView，禁止内联回计算属性。
//

import SwiftUI

// MARK: - 顶部胶囊

struct MatterContextPill: View {
    let context: HoloMatterConversationContext
    let onExit: () -> Void

    var body: some View {
        let title = HoloMatterRepository.shared.matter(id: context.matterID)?.title ?? ""
        // 与 GoalPlanningActiveBanner 同款行样式（2026-09-23 交互统一：
        // 会话态横幅一律品牌色浅底胶囊行，位于输入框上方）
        HStack(spacing: 8) {
            Image(systemName: "pin.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: title.isEmpty ? String(localized: "正在聊这件事") : String(localized: "正在聊：\(title)"))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "退出这件事的上下文"))
        }
        .foregroundColor(.holoPrimary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.holoPrimary.opacity(0.08), in: Capsule())
        .transition(.opacity)
    }
}

// MARK: - 自动更新回执

struct MatterFeedbackToast: View {
    let feedback: MatterChatContextStore.MatterFeedback
    let onRevert: (UUID) -> Void
    let onDismiss: () -> Void
    let onAutoDismiss: () -> Void

    var body: some View {
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
                    onRevert(eventID)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }
            Button(action: onDismiss) {
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
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            // 无操作 6 秒自动收起
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            onAutoDismiss()
        }
    }
}

// MARK: - 歧义追问

struct MatterAmbiguityBar: View {
    let ambiguity: HoloMatterAmbiguity
    let onResolve: (HoloMatterAmbiguityOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ambiguity.question)
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(ambiguity.options) { option in
                    Button {
                        onResolve(option)
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
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - 计划修订确认卡（2026-09-23：建议加入计划的新任务）

struct MatterTaskProposalBar: View {
    let proposal: MatterChatContextStore.PendingTaskProposal
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "建议加入计划：\(proposal.draft.title)")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onConfirm) {
                    Text(String(localized: "加入计划"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.holoPrimary))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Text(String(localized: "忽略"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().strokeBorder(Color.holoPrimary, lineWidth: 1.2))
                        .foregroundStyle(Color.holoPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - 上次上下文恢复幽灵条（2026-09-23：重启后无感掉队的提示）

struct MatterRecoverableBar: View {
    let recoverable: MatterChatContextStore.RecoverableContext
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: "上次在聊：\(recoverable.title)")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onRestore) {
                Text(String(localized: "恢复"))
                    .font(.system(size: 11.5, weight: .bold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Color.holoTextSecondary.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "恢复上次的对话上下文"))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "不再提示恢复"))
        }
        .foregroundColor(.holoTextSecondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.opacity)
    }
}

// MARK: - 歧义消解
// 2026-09-23 下沉至 MatterChatContextStore.resolveAmbiguity（三件套移入输入区后，
// 渲染方是消息面板子视图，不再能触达 ChatView 实例方法；store 是状态 owner）。
