//
//  ThoughtAIClassificationPolicy.swift
//  Holo
//
//  想法 AI 自动分类的统一开关与状态策略
//

import Foundation

enum ThoughtAIClassificationPolicy {
    static let isEnabledKey = "isThoughtAutoOrganizationEnabled"

    /// 未写入过设置时默认开启，保持现有用户体验。
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: isEnabledKey) as? Bool ?? true
    }

    /// 新想法保存后的初始整理状态。
    static func initialStatus(contentLength: Int, isEnabled: Bool) -> String {
        guard isEnabled else { return "disabled" }
        return contentLength < 10 ? "skipped" : "pending"
    }

    /// 手动“批量 AI 整理”只排除已经结束或正在执行的状态。
    /// disabled 仍可手动整理，避免关闭自动分类后失去补整理入口。
    static let manualBatchTerminalStatuses = [
        "organized", "pending", "processing", "skipped", "failed"
    ]
}
