//
//  ThoughtAIClassificationPolicy.swift
//  Holo
//
//  想法 AI 自动分类的统一开关与状态策略
//

import Foundation

enum ThoughtAIClassificationPolicy {
    static let isEnabledKey = "isThoughtAutoOrganizationEnabled"

    /// 自动整理默认值：显式设置永远优先；未设置时——V3 新 UI 生效的构建默认停止
    /// V2 自动整理（其标签在新 UI 不展示，继续自动跑只空耗配额），线上 Release
    /// （旧 UI 仍展示 V2 标签）保持默认开。回滚 = 设置页显式开启（2026-09-24 方案 §6.2 停算矩阵）。
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if let explicit = defaults.object(forKey: isEnabledKey) as? Bool { return explicit }
        return !ThoughtSemanticFeatureFlags.uiEnabled(in: defaults)
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
