//
//  HoloMemoryAnswerEligibility.swift
//  Holo
//
//  「可进入 AI 回答/规划上下文」的统一记录级判据（方案 §7.1 / §12.1 M06）
//
//  与 HoloMemoryQueryService 的授权过滤同口径（state == .active 且未被用户
//  拒绝/遗忘/排除）。所有绕过 QueryService 直连 repository.query(.all) 的
//  消费者必须再套本判据；修改口径时两处同步。
//

import Foundation

nonisolated enum HoloMemoryAnswerEligibility {
    /// 该记录是否可进入回答/规划/个人情境上下文。
    static func isEligible(_ record: HoloMemoryRecord) -> Bool {
        record.state == .active
            && record.userDecision != .rejected
            && record.userDecision != .forgotten
            && record.userDecision != .markedIrrelevant
    }

    /// 直连读者通用的二次过滤。
    static func filter(_ records: [HoloMemoryRecord]) -> [HoloMemoryRecord] {
        records.filter(isEligible)
    }
}
