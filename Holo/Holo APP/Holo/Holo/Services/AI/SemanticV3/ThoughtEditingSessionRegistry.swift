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
//  回执时效门控（同日二修）：「已归入」回执 toast 只跟「你刚写完的那条」走——
//  只有该想法的编辑会话在 receiptWindow 内结束，归类落库才值得打断；
//  后台积压消化（启动对账/存量补跑/迟到重试）一律静默，结果由卡片徽章呈现。
//

import Foundation

@MainActor
final class ThoughtEditingSessionRegistry {

    static let shared = ThoughtEditingSessionRegistry()
    init() {}

    /// 回执时效窗口：编辑结束后 15 分钟内落库的归类才算「你刚写的这条」的回执。
    /// 定稿入队 5s 起跑、心跳 30s 一拍，正常几十秒内落库；窗口只兜慢网/重试拖尾。
    static let receiptWindow: TimeInterval = 15 * 60

    /// 测试注入时钟（时效判定）
    var nowProvider: () -> Date = { Date() }

    /// thoughtId → 在途编辑器实例数（同想法多编辑器并存时引用计数，最后一个退出才算编辑结束）
    private var editingCounts: [UUID: Int] = [:]
    /// thoughtId → 最后一次编辑会话结束时刻（回执时效门控）
    private var endedAt: [UUID: Date] = [:]

    func beginEditing(_ thoughtID: UUID) {
        editingCounts[thoughtID, default: 0] += 1
    }

    func endEditing(_ thoughtID: UUID) {
        guard let count = editingCounts[thoughtID] else { return }
        if count <= 1 {
            editingCounts.removeValue(forKey: thoughtID)
            endedAt[thoughtID] = nowProvider()
            pruneStaleEnds()
        } else {
            editingCounts[thoughtID] = count - 1
        }
    }

    func isEditing(_ thoughtID: UUID) -> Bool {
        editingCounts[thoughtID] != nil
    }

    /// 是否有任一编辑器会话在途（「已归入」回执 toast 的保险丝：写作中不打断）
    var hasActiveSession: Bool { !editingCounts.isEmpty }

    /// 该想法是否在回执时效窗口内刚结束编辑（回执 toast 的因果门控：
    /// 与用户动作无因果关系的后台落库不弹）
    func isWithinReceiptWindow(_ thoughtID: UUID) -> Bool {
        guard let ended = endedAt[thoughtID] else { return false }
        return nowProvider().timeIntervalSince(ended) <= Self.receiptWindow
    }

    /// 控内存：结束时刻只留时效窗口内的
    private func pruneStaleEnds() {
        let cutoff = nowProvider().addingTimeInterval(-Self.receiptWindow)
        endedAt = endedAt.filter { $0.value > cutoff }
    }
}
