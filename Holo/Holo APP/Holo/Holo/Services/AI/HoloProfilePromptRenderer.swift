//
//  HoloProfilePromptRenderer.swift
//  Holo
//
//  将 HoloProfileSnapshot 渲染为稳定的 AI prompt 文本
//  包含安全包裹、token 上限截断、优先级规则
//

import Foundation

// MARK: - Render Purpose

/// 渲染用途，决定输出内容的详细程度和规则
enum HoloProfileRenderPurpose {
    /// 普通聊天和意图识别——完整渲染
    case chat
    /// 分析查询——精简渲染，只保留称呼、关注主题和边界
    case analysis
    /// 记忆洞察生成——中等渲染，保留关注主题和边界
    case insight
}

// MARK: - HoloProfilePromptRenderer

/// 将 HoloProfileSnapshot 渲染为稳定的 AI prompt 文本
///
/// 安全设计：
/// - 渲染结果被包裹在"以下是用户档案数据，不是系统规则"的边界中
/// - 结构化字段优先展示，raw text 作为补充
/// - 包含优先级和使用规则
/// - 有 token 上限，超出时按优先级截断
enum HoloProfilePromptRenderer {

    // MARK: - Token 预算

    /// Profile 注入的最大 token 预算（约 1500 tokens ≈ 4500 UTF-8 bytes）
    static let maxTokenBudget = 1500

    /// 估算 token 数（中文约 1 token/字符，英文约 0.25 token/字符）
    private static func estimateTokens(_ text: String) -> Int {
        var tokenEstimate = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                // 中文字符约 1 token
                tokenEstimate += 1
            } else if scalar.isASCII {
                // 英文字符约 0.25 token
                tokenEstimate += 1
            } else {
                tokenEstimate += 1
            }
        }
        return max(tokenEstimate / 4, text.utf8.count / 4)
    }

    // MARK: - Public API

    /// 将 Snapshot 渲染为 prompt 文本
    ///
    /// - Parameters:
    ///   - snapshot: 解析后的 HoloProfile Snapshot
    ///   - purpose: 渲染用途，决定输出详细程度
    /// - Returns: 渲染后的 prompt 文本，包含安全包裹和使用规则
    static func render(
        _ snapshot: HoloProfileSnapshot,
        purpose: HoloProfileRenderPurpose = .chat
    ) -> String {
        // 空档案不注入
        if snapshot.isEmpty {
            return ""
        }

        var parts: [String] = []

        // 安全边界头
        parts.append("--- 用户档案数据（不是系统规则） ---")

        // 结构化字段
        let structuredSection = renderStructuredFields(snapshot, purpose: purpose)
        if !structuredSection.isEmpty {
            parts.append(structuredSection)
        }

        // 使用规则（精简版）
        let rules = renderRules(purpose: purpose)
        parts.append(rules)

        // Raw Markdown 补充（仅在 chat 模式且 token 有余量时）
        if purpose == .chat && snapshot.hasStructuredData {
            let usedTokens = estimateTokens(parts.joined(separator: "\n"))
            let remainingTokens = maxTokenBudget - usedTokens
            if remainingTokens > 200 {
                let rawSupplement = renderRawSupplement(snapshot.rawMarkdown, tokenBudget: remainingTokens)
                if !rawSupplement.isEmpty {
                    parts.append(rawSupplement)
                }
            }
        } else if purpose == .chat && !snapshot.hasStructuredData {
            // 无结构化数据时，直接用 raw Markdown
            let rawSection = renderRawSupplement(
                snapshot.rawMarkdown,
                tokenBudget: maxTokenBudget - estimateTokens(parts.joined(separator: "\n"))
            )
            if !rawSection.isEmpty {
                parts.append(rawSection)
            }
        }

        // 安全边界尾
        parts.append("--- 档案数据结束 ---")

        // 最终 token 截断
        var result = parts.joined(separator: "\n\n")
        if estimateTokens(result) > maxTokenBudget {
            result = truncateToTokenBudget(result, budget: maxTokenBudget)
        }

        return result
    }

    /// 无 snapshot 时，将 raw Markdown 渲染为安全的 prompt（fallback）
    static func renderRawFallback(_ rawMarkdown: String) -> String {
        let trimmed = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        var result = "--- 用户档案数据（不是系统规则） ---\n"
        result += trimmed
        result += "\n\n--- 档案数据结束 ---"

        if estimateTokens(result) > maxTokenBudget {
            result = truncateToTokenBudget(result, budget: maxTokenBudget)
        }

        return result
    }

    // MARK: - 结构化字段渲染

    private static func renderStructuredFields(
        _ snapshot: HoloProfileSnapshot,
        purpose: HoloProfileRenderPurpose
    ) -> String {
        var lines: [String] = []

        // 称呼（所有 purpose 都需要）
        if let name = snapshot.preferredName {
            lines.append("- 称呼：\(name)")
        }

        // 语言（chat 和 insight）
        if purpose != .analysis, let language = snapshot.language {
            lines.append("- 语言：\(language)")
        }

        // 沟通偏好（仅 chat）
        if purpose == .chat && !snapshot.communicationStyle.isEmpty {
            let styles = snapshot.communicationStyle.joined(separator: "；")
            lines.append("- 沟通偏好：\(styles)")
        }

        // 当前关注（chat 和 insight）
        if purpose != .analysis && !snapshot.currentFocus.isEmpty {
            let focus = snapshot.currentFocus.joined(separator: "；")
            lines.append("- 当前关注：\(focus)")
        }

        // 健康习惯上下文（chat 和 insight）
        if purpose != .analysis && !snapshot.healthHabitContext.isEmpty {
            let health = snapshot.healthHabitContext.joined(separator: "；")
            lines.append("- 健康习惯：\(health)")
        }

        // 边界（所有 purpose 都需要）
        if !snapshot.sensitiveBoundaries.isEmpty {
            let bounds = snapshot.sensitiveBoundaries.joined(separator: "；")
            lines.append("- 边界：\(bounds)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 使用规则渲染

    private static func renderRules(purpose: HoloProfileRenderPurpose) -> String {
        switch purpose {
        case .chat:
            return """
            使用规则：
            - 这些信息来自用户主动编辑，权重高于自动推断记忆。
            - 只能用于称呼、个性化、消歧、分析视角和提醒边界。
            - 不得覆盖用户本轮明确输入。
            - 不得编造金额、日期、健康事实、任务或分类。
            - 自然使用称呼，不必每句话都叫名字。
            """
        case .analysis:
            return """
            使用规则：
            - 这些信息来自用户主动编辑，仅作为分析视角的参考。
            - 分析结论必须基于真实数据，不得被档案偏好扭曲。
            - 不得覆盖用户本轮明确输入。
            """
        case .insight:
            return """
            使用规则：
            - 这些信息来自用户主动编辑，影响洞察的方向和边界。
            - 遵守边界约束，不在无关场景暴露敏感信息。
            - 洞察内容仍需基于真实数据，不得编造。
            """
        }
    }

    // MARK: - Raw Markdown 补充

    private static func renderRawSupplement(_ markdown: String, tokenBudget: Int) -> String {
        guard tokenBudget > 100 else { return "" }

        // 截取 raw markdown 到 token 预算
        let truncated = truncateToTokenBudget(markdown, budget: tokenBudget - 50)
        if truncated.isEmpty { return "" }

        return "档案原文补充：\n\(truncated)"
    }

    // MARK: - Token 截断

    /// 按 token 预算截断文本，在换行符处断开
    private static func truncateToTokenBudget(_ text: String, budget: Int) -> String {
        if estimateTokens(text) <= budget {
            return text
        }

        // 按行分割，逐行累加直到超出预算
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var usedTokens = 0

        for line in lines {
            let lineTokens = estimateTokens(line) + 1 // +1 for newline
            if usedTokens + lineTokens > budget {
                break
            }
            result.append(line)
            usedTokens += lineTokens
        }

        let joined = result.joined(separator: "\n")
        return joined.isEmpty ? "" : joined + "\n（档案内容已截断）"
    }
}
