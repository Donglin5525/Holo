//
//  ThoughtTagPresentation.swift
//  Holo
//
//  想法标签展示与筛选规则
//

import Foundation

/// 统一用户标签与 AI 标签的展示、去重和筛选语义。
struct ThoughtTagPresentation: Equatable {
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
        let manualKeys = Set(uniqueManualNames.map(ThoughtTagNormalizer.key))
        let uniqueAINames = uniqueNames(aiNames).filter {
            !manualKeys.contains(ThoughtTagNormalizer.key($0))
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
    static func matches(
        _ selectedName: String,
        manualNames: [String],
        aiNames: [String]
    ) -> Bool {
        let selectedKey = ThoughtTagNormalizer.key(selectedName)
        guard !selectedKey.isEmpty else { return false }

        return (manualNames + aiNames).contains {
            ThoughtTagNormalizer.key($0) == selectedKey
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
