//
//  HoloTaskExecutionRolloutPolicy.swift
//  Holo
//
//  分步推进灰度开关（2026-09-25 实施规格 §9.4）
//
//  三开关分离：入口展示 / AI 新生成 / 既有计划执行读取。
//  数据语义由 TodoTask.executionSchemaVersion 固定，不随灰度 flag 改变：
//  - 关 AI：保留手动执行与原任务完成
//  - 关入口：保留 TaskDetail 中已有计划的只读/基本执行入口及统一完成策略
//  - 任何 flag 关闭后不得让清单又自动完成已管理的任务（级联策略跟 schema 走）
//

import Foundation

nonisolated enum HoloTaskExecutionRolloutPolicy {

    nonisolated enum Flag: String, CaseIterable {
        /// 入口展示（Matter 下一步「帮我拆开」按钮）
        case taskExecutionEntryEnabled
        /// AI 新生成（无 AI 时仍可手动建计划）
        case taskExecutionAIGenerationEnabled
        /// 既有计划执行读取（关掉=只读保留，完成语义仍由 schema 接管）
        case taskExecutionReadingEnabled
    }

    private static let defaults = UserDefaults.standard

    static func isEnabled(_ flag: Flag) -> Bool {
        if let explicit = defaults.object(forKey: flag.rawValue) as? Bool {
            return explicit
        }
        // 2026-09-26 东林拍板 P5：全量默认开启；显式设置过则尊重设置（回滚=诊断页关开关）
        return true
    }

    static func setEnabled(_ flag: Flag, enabled: Bool) {
        defaults.set(enabled, forKey: flag.rawValue)
    }

    // MARK: - 便捷门禁（调用点读这里）

    /// 是否展示「帮我拆开」入口（Matter 下一步 / TaskDetail）
    static var entryEnabled: Bool { isEnabled(.taskExecutionEntryEnabled) }

    /// 是否允许 AI 生成候选（关=手动建计划仍可用）
    static var aiGenerationEnabled: Bool { isEnabled(.taskExecutionAIGenerationEnabled) }

    /// 是否执行既有计划（关=已有计划只读展示）
    static var readingEnabled: Bool { isEnabled(.taskExecutionReadingEnabled) }
}
