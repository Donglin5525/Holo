//
//  ThoughtEditingSessionRegistry.swift
//  Holo
//
//  「想法正在被编辑」会话登记（2026-11-16 主题归类时机根治）
//
//  语义管线不消费编辑中的中间版本：编辑器 onAppear（既有想法）/首次落库
//  （新建草稿）登记，onDisappear 兜底落库后注销并调用
//  ThoughtSemanticChangeFeed.handleEditingEnded 用定稿正文补入队；
//  编辑中途被杀由启动对账 reconcileAllThoughts 兜底，不会漏。
//

import Foundation

@MainActor
final class ThoughtEditingSessionRegistry {

    static let shared = ThoughtEditingSessionRegistry()
    init() {}

    /// thoughtId → 在途编辑器实例数（同想法多编辑器并存时引用计数，最后一个退出才算编辑结束）
    private var editingCounts: [UUID: Int] = [:]

    func beginEditing(_ thoughtID: UUID) {
        editingCounts[thoughtID, default: 0] += 1
    }

    func endEditing(_ thoughtID: UUID) {
        guard let count = editingCounts[thoughtID] else { return }
        if count <= 1 {
            editingCounts.removeValue(forKey: thoughtID)
        } else {
            editingCounts[thoughtID] = count - 1
        }
    }

    func isEditing(_ thoughtID: UUID) -> Bool {
        editingCounts[thoughtID] != nil
    }

    /// 是否有任一编辑器会话在途（「已归入」回执 toast 的保险丝：写作中不打断）
    var hasActiveSession: Bool { !editingCounts.isEmpty }
}
