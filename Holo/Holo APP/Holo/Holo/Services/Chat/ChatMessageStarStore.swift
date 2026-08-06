//
//  ChatMessageStarStore.swift
//  Holo
//
//  P1-11：消息收藏的轻量存储（UserDefaults 存 messageId 列表）。
//  当前不改 Core Data 模型（避免迁移风险），长期可迁移到 ChatMessage.isStarred 字段。
//

import Foundation
import Combine

/// 管理被收藏的聊天消息 id 集合。
/// 线程安全：所有方法在 MainActor 上调用（与 ChatViewModel/ChatView 一致）。
@MainActor
final class ChatMessageStarStore: ObservableObject {

    static let shared = ChatMessageStarStore()

    /// 变更通知：View 层订阅后刷新收藏态显示
    @Published private(set) var starredMessageIDs: Set<UUID> = []

    private let key = "holo_chat_starred_messages"

    private init() {
        load()
    }

    func isStarred(_ id: UUID) -> Bool {
        starredMessageIDs.contains(id)
    }

    func toggle(_ id: UUID) {
        if starredMessageIDs.contains(id) {
            starredMessageIDs.remove(id)
        } else {
            starredMessageIDs.insert(id)
        }
        save()
    }

    /// 移除单个收藏（即使当前未收藏也安全调用）。
    /// 用于清理「孤儿 ID」——被删除的聊天消息对应的 id 仍残留在收藏列表里。
    func remove(_ id: UUID) {
        guard starredMessageIDs.remove(id) != nil else { return }
        save()
    }

    /// 批量剔除一组 id（只触发一次变更通知，适合列表加载时清理多个孤儿 ID）。
    func prune(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = starredMessageIDs.count
        starredMessageIDs.subtract(ids)
        guard starredMessageIDs.count != before else { return }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return
        }
        starredMessageIDs = Set(ids)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(starredMessageIDs)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
