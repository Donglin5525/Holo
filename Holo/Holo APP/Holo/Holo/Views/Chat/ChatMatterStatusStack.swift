//
//  ChatMatterStatusStack.swift
//  Holo
//
//  Matter「进行中的事」会话态提示五件套（2026-09-23 从 ChatContentColumn
//  内联 Group 拆出，随真机栈溢出三修）
//
//  2026-09-23 统一交互：与目标规划横幅同区，全部会话态提示收敛在输入框
//  上方，不再单独占顶部一条风格。五件共享同一单例 store，观察点合并到
//  本 struct，ChatContentColumn 不再直接观察 Matter store。
//

import SwiftUI

/// Matter 会话上下文状态件：上下文胶囊 / 反馈撤销 / 歧义选择 / 任务提案 / 可恢复上下文。
/// 同一时刻通常至多一件出现；各件独立动画。
struct ChatMatterStatusStack: View {
    @ObservedObject private var matterStore = MatterChatContextStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let matterContext = matterStore.active {
                    MatterContextPill(context: matterContext, onExit: { matterStore.exit() })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
            }
            .animation(HoloAnimation.enter, value: matterStore.active)

            Group {
                if let feedback = matterStore.lastFeedback {
                    MatterFeedbackToast(
                        feedback: feedback,
                        onRevert: { eventID in
                            Task {
                                try? await HoloMatterRepository.shared.revertEvent(eventID: eventID)
                                matterStore.lastFeedback = nil
                                // addTask 撤销会软删 TodoTask；任务模块与详情页观察者刷新
                                NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
                            }
                        },
                        onDismiss: { matterStore.lastFeedback = nil },
                        onAutoDismiss: {
                            withAnimation { matterStore.lastFeedback = nil }
                        }
                    )
                }
            }
            .animation(HoloAnimation.enter, value: matterStore.lastFeedback)

            Group {
                if let ambiguity = matterStore.pendingAmbiguity {
                    MatterAmbiguityBar(
                        ambiguity: ambiguity,
                        onResolve: { option in matterStore.resolveAmbiguity(ambiguity, option: option) }
                    )
                }
            }
            .animation(HoloAnimation.enter, value: matterStore.pendingAmbiguity)

            Group {
                if let proposal = matterStore.pendingTaskProposal {
                    MatterTaskProposalBar(
                        proposal: proposal,
                        onConfirm: { matterStore.confirmTaskProposal() },
                        onDismiss: { matterStore.dismissTaskProposal() }
                    )
                }
            }
            .animation(HoloAnimation.enter, value: matterStore.pendingTaskProposal)

            Group {
                if let recoverable = matterStore.recoverableContext {
                    MatterRecoverableBar(
                        recoverable: recoverable,
                        onRestore: { matterStore.restoreRecoverable() },
                        onDismiss: { matterStore.dismissRecoverable() }
                    )
                }
            }
            .animation(HoloAnimation.enter, value: matterStore.recoverableContext)
        }
        .task {
            // 重启后上下文不自动恢复，但读一次持久化记录给出「上次在聊」幽灵条
            matterStore.loadRecoverableIfAny()
        }
    }
}
