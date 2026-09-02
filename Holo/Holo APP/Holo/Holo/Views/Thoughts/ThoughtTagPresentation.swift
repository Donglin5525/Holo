//
//  ThoughtTagPresentation.swift
//  Holo
//
//  想法标签展示与筛选规则
//

import Foundation

/// 统一用户标签与 AI 标签的展示、去重和筛选语义。
nonisolated struct ThoughtTagPresentation: Equatable {
    let manualNames: [String]
    let aiNames: [String]
    let hiddenCount: Int

    var isEmpty: Bool {
        manualNames.isEmpty && aiNames.isEmpty
    }

    /// 卡片优先同时露出两类标签，避免新增用户标签后 AI 标签看起来被覆盖。
    static func card(
        manualNames: [String],
        aiNames: [String],
        manualLimit: Int = 2,
        aiLimit: Int = 2
    ) -> ThoughtTagPresentation {
        let uniqueManualNames = uniqueNames(manualNames)
        let uniqueAINames = uniqueNames(aiNames).filter { aiName in
            // 双形态身份去重：AI 按主题前缀拼出的「工作与事业/books」与用户 #books
            // 是同一概念，全路径 key 对不上时也要按叶子身份折叠，否则同一标签双显示
            !uniqueManualNames.contains { ThoughtTagNormalizer.sharesIdentity($0, aiName) }
        }

        let visibleManualNames = Array(uniqueManualNames.prefix(max(0, manualLimit)))
        let visibleAINames = Array(uniqueAINames.prefix(max(0, aiLimit)))
        let hiddenCount = uniqueManualNames.count + uniqueAINames.count
            - visibleManualNames.count - visibleAINames.count

        return ThoughtTagPresentation(
            manualNames: visibleManualNames,
            aiNames: visibleAINames,
            hiddenCount: max(0, hiddenCount)
        )
    }

    /// 标签筛选同时命中用户标签和 AI 标签，并复用统一的名称归一化规则。
    /// 双形态身份匹配：点 #books 能召回 AI 打了「工作与事业/books」的想法，反之亦然——
    /// 同一标签只有一个身份，筛选不能因为存储形态（叶子词 vs 主题路径）互相漏。
    static func matches(
        _ selectedName: String,
        manualNames: [String],
        aiNames: [String]
    ) -> Bool {
        let selectedKey = ThoughtTagNormalizer.key(selectedName)
        guard !selectedKey.isEmpty else { return false }

        return (manualNames + aiNames).contains {
            ThoughtTagNormalizer.sharesIdentity(selectedName, $0)
        }
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seenKeys: Set<String> = []
        return names.compactMap { rawName in
            let displayName = ThoughtTagNormalizer.displayName(rawName)
            let key = ThoughtTagNormalizer.key(displayName)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { return nil }
            return displayName
        }
    }
}
