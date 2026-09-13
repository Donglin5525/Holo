//
//  MatterChatContextStore.swift
//  Holo
//
//  Matter-scoped Chat 的类型化上下文通道（方案 §13.5）
//
//  详情页「和 Holo 讨论这件事」→ enter(matterID:)；聊天页顶部胶囊展示并允许退出；
//  退出后下一条消息不再自动关联，避免上下文泄漏。
//  显式 matterID 贯穿全链路，禁止靠标题关键词反猜当前 Matter（方案 §4.2-8）。
//

import Foundation
import Combine

@MainActor
final class MatterChatContextStore: ObservableObject {

    static let shared = MatterChatContextStore()

    /// 当前生效的 Matter 对话上下文；nil = 普通聊天。
    @Published var active: HoloMatterConversationContext?

    /// 最近一次对账回执（「已更新到…·撤销」轻提示），nil 表示无待展示内容。
    @Published var lastFeedback: MatterFeedback?

    /// 歧义追问（「东京还是京都？」），由聊天页展示选项。
    @Published var pendingAmbiguity: HoloMatterAmbiguity?

    nonisolated struct MatterFeedback: Identifiable, Equatable {
        let id = UUID()
        let matterTitle: String
        let summaries: [String]
        /// 可撤销的自动更新事件（最新 resolve）。
        let revertEventID: UUID?
    }

    private init() {}

    func enter(matterID: UUID, source: HoloMatterConversationEntrySource) {
        active = HoloMatterConversationContext(matterID: matterID, source: source)
        lastFeedback = nil
        pendingAmbiguity = nil
    }

    func exit() {
        active = nil
        lastFeedback = nil
        pendingAmbiguity = nil
    }
}
