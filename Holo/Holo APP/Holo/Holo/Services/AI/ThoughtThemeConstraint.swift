//
//  ThoughtThemeConstraint.swift
//  Holo
//
//  想法 AI 主题约束的纯逻辑安全层。
//  不依赖 Core Data，便于 standalone 覆盖模型幻觉、路径污染和重复标签。
//

import Foundation

enum ThoughtThemeConstraint {

    /// “未归类”是虚拟节点和标签路径前缀，不创建对应 Topic 实体。
    static let unclassifiedTitle = "未分类"

    static let presetTopics = [
        "工作与事业", "个人成长", "灵感创意",
        "生活与健康", "财务与消费", "关系与家庭"
    ]

    static let defaultPresetTopics = Set(presetTopics.prefix(4))

    struct ValidatedResult: Equatable {
        /// 命中用户启用主题时返回其标准展示名；nil 表示未归类。
        let topicTitle: String?
        /// 已完成主题前缀注入的安全标签路径。
        let tagPaths: [String]
    }

    /// 把模型输出收敛为“合法主题或未归类 + 1~3 个安全路径标签”。
    static func validate(
        selectedTopic: String?,
        suggestedTags: [String],
        activeTopics: [String],
        maxTags: Int = 3
    ) -> ValidatedResult {
        let canonicalTopic = canonicalTopicTitle(selectedTopic, activeTopics: activeTopics)
        let prefix = canonicalTopic ?? unclassifiedTitle
        let prefixKey = ThoughtTagNormalizer.key(prefix)

        var seen: Set<String> = []
        let tagPaths = suggestedTags.compactMap { rawTag -> String? in
            var segments = ThoughtTagNormalizer.displayPath(rawTag)
                .components(separatedBy: "/")
                .filter { !$0.isEmpty }

            // 模型可能重复输出主题前缀，只保留叶子语义并由端侧统一拼接。
            if let first = segments.first {
                let firstKey = ThoughtTagNormalizer.key(first)
                let knownTopicKeys = Set(activeTopics.map(ThoughtTagNormalizer.key) + [ThoughtTagNormalizer.key(unclassifiedTitle)])
                if firstKey == prefixKey || knownTopicKeys.contains(firstKey) {
                    segments.removeFirst()
                }
            }

            guard let leaf = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !leaf.isEmpty else { return nil }
            let clippedLeaf = String(leaf.prefix(12))
            let path = "\(prefix)/\(clippedLeaf)"
            let key = ThoughtTagNormalizer.key(path)
            guard seen.insert(key).inserted else { return nil }
            return path
        }

        return ValidatedResult(
            topicTitle: canonicalTopic,
            tagPaths: Array(tagPaths.prefix(max(0, maxTags)))
        )
    }

    /// 仅接受约束池中的标准主题名；模型发明或返回“未分类”时统一视为 nil。
    static func canonicalTopicTitle(_ rawValue: String?, activeTopics: [String]) -> String? {
        guard let rawValue else { return nil }
        let key = ThoughtTagNormalizer.key(rawValue)
        guard !key.isEmpty, key != ThoughtTagNormalizer.key(unclassifiedTitle) else { return nil }
        return activeTopics.first { ThoughtTagNormalizer.key($0) == key }
    }

    static func isTag(_ tagName: String, underTopic topicTitle: String) -> Bool {
        let tagKey = ThoughtTagNormalizer.key(tagName)
        let topicKey = ThoughtTagNormalizer.key(topicTitle)
        return tagKey.hasPrefix(topicKey + "/")
    }
}
