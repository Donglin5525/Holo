//
//  HoloAgentAnswerMetricCounter.swift
//  Holo
//
//  HoloAI Agent 统一结果语义契约 P4 — 答案语义/展示链路本地聚合指标
//
//  沿用 `HoloAgentContractViolationCounter` 的轻量桥接模式：Renderer 是同步静态管线，
//  无法直接访问 async telemetry，由本计数器在决策点打计数，上层按需读取快照。
//  只记录指标名与稳定技术上下文（domain rawValue / answer mode / 失败短码），
//  禁止记录用户原始问题、分类名称、具体数字（方案 §11）。
//

import Foundation

final class HoloAgentAnswerMetricCounter: @unchecked Sendable {

    static let shared = HoloAgentAnswerMetricCounter()

    /// 方案 §11 定义的 6 个本地聚合指标。
    enum Metric: String, CaseIterable, Sendable {
        /// 证据无 semantic 且走了兼容目录。
        case semanticMissing = "agent.semantic.missing"
        /// 语义缺失但旧目录可识别并兼容适配。
        case semanticLegacyFallback = "agent.semantic.legacy_fallback"
        /// 确定性合成器产出 directAnswer。
        case composerUsed = "agent.answer.composer_used"
        /// 模型事实文案被丢弃/替换。
        case modelTextDiscarded = "agent.answer.model_text_discarded"
        /// 覆盖验证 failed 走了边界说明。
        case coverageFailed = "agent.answer.coverage_failed"
        /// 内部 token 被拦截。
        case internalTokenBlocked = "agent.answer.internal_token_blocked"
    }

    private let lock = NSLock()
    private var counts: [Metric: Int] = [:]
    /// 每个指标下的稳定技术上下文计数（如 "finance" / "comparison" / "NO_EVIDENCE"）。
    private var contexts: [Metric: [String: Int]] = [:]

    private init() {}

    /// 在决策点打一次计数；context 只允许稳定技术码，不得携带用户原文/分类名/数字。
    func increment(_ metric: Metric, context: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        counts[metric, default: 0] += 1
        if let context {
            contexts[metric, default: [:]][context, default: 0] += 1
        }
    }

    func count(for metric: Metric) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[metric] ?? 0
    }

    /// 本地聚合快照：指标名 → 计数；附稳定上下文分布（技术码 → 计数）。
    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: Int] = [:]
        for metric in Metric.allCases {
            result[metric.rawValue] = counts[metric] ?? 0
            for (context, count) in (contexts[metric] ?? [:]).sorted(by: { $0.key < $1.key }) {
                result["\(metric.rawValue)|\(context)"] = count
            }
        }
        return result
    }

    /// 测试与灰度窗口边界用：清零全部计数。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
        contexts.removeAll()
    }
}
