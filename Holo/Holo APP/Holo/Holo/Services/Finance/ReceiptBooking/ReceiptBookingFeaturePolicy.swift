//
//  ReceiptBookingFeaturePolicy.swift
//  Holo
//
//  图片快捷指令自动记账 · 运行资格前置（2026-09-14 完整方案 §23.1/§30.2）
//  M1 版本：AI 数据处理授权 + 基础账本就绪检查。
//  M2 起补充 receiptShortcutEnabled / receiptShortcutAutoCommitEnabled 本地开关，
//  自动写还必须同时满足后端 automationPolicy.autoCommitAllowed（缺失一律 false）。
//

import Foundation

enum ReceiptBookingFeaturePolicy {

    /// 返回 nil 表示可以运行；否则给出对应的失败原因码
    static func readinessReason() -> ReceiptBookingReason? {
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            return .failureNotConfigured
        }
        guard !FinanceRepository.shared.getAccounts(includeArchived: false).isEmpty else {
            return .failureNotConfigured
        }
        return nil
    }
}
