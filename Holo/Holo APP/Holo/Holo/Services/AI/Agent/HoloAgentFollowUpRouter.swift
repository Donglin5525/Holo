//
//  HoloAgentFollowUpRouter.swift
//  Holo
//
//  连续追问的关系路由器（§12 routing order）。
//
//  在用户发送追问文本时，用确定性规则判定这条追问与父分析的关系类型：
//  explain / drillDown / correct / changeScope / crossDomain / executeFromResult / newTopic / ambiguous。
//
//  设计原则：
//  - 纯确定性，不调用模型（Phase 3 只用关键词规则 + 闭集输出）。
//  - 按方案的确定性规则集逐条匹配，命中即返回；都不命中时按父域/文本特征兜底。
//  - 宁可 ambiguous（让用户重选）也不乱猜——错误的关系会污染继承的上下文。
//
//  判定顺序（§12）：
//  1. executeFromResult：追问指向某个具体建议/行动
//  2. correct：纠正口径（「算错了」「不对」「应该是」）
//  3. changeScope：换时间/范围（「换成今年」「改成上周」）
//  4. crossDomain：跨域补查（父是健康，追问提到消费）
//  5. drillDown：深挖（「具体看看」「详细」「第几条」）
//  6. explain：解释（「为什么」「什么意思」「怎么回事」）
//  7. newTopic：与父完全无关
//  8. ambiguous：兜底
//

import Foundation

/// 追问路由判定所需的最小父分析信息。
nonisolated struct HoloAgentFollowUpParentContext: Sendable {
    /// 父分析涉及的数据域（health/finance/habit…），用于判断是否跨域。
    var parentDomains: [String]
    /// 父分析是否含建议类 claim（影响 executeFromResult 判定）。
    var hasRecommendations: Bool
    /// 父问题原文，用于判断追问是否离题。
    var parentQuestion: String?

    init(parentDomains: [String], hasRecommendations: Bool, parentQuestion: String?) {
        self.parentDomains = parentDomains
        self.hasRecommendations = hasRecommendations
        self.parentQuestion = parentQuestion
    }
}

/// 追问关系路由器：纯值类型，无副作用。
nonisolated enum HoloAgentFollowUpRouter {

    /// 判定追问文本与父分析的关系。
    /// - Returns: 闭集 relation；无法确定时返回 .ambiguous。
    static func classify(
        followUpText: String,
        parent: HoloAgentFollowUpParentContext
    ) -> HoloAgentFollowUpRelation {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return .ambiguous }

        // 1. executeFromResult：指向具体建议/行动
        //    「第一条建议」「就按这个建议」「创建这个待办」
        if parent.hasRecommendations && matchesExecuteIntent(text) {
            return .executeFromResult
        }

        // 2. correct：纠正口径
        //    「算错了」「不对」「应该是」「口径」「统计有问题」
        if matchesCorrection(text) {
            return .correct
        }

        // 3. changeScope：换时间/范围
        //    「换成今年」「改成上周」「近三个月呢」「上周的呢」
        if matchesScopeChange(text) {
            return .changeScope
        }

        // 4. crossDomain：跨域补查
        //    追问提到的域与父域不重叠
        let followUpDomains = identifyDomains(in: text)
        if !followUpDomains.isEmpty && !parent.parentDomains.isEmpty {
            let overlap = Set(followUpDomains).intersection(parent.parentDomains)
            if overlap.isEmpty {
                return .crossDomain
            }
        }

        // 5. drillDown：深挖
        //    「具体」「详细」「第几条」「展开」「深入」
        if matchesDrillDown(text) {
            return .drillDown
        }

        // 6. explain：解释
        //    「为什么」「什么意思」「怎么回事」「原因是」
        if matchesExplain(text) {
            return .explain
        }

        // 7. newTopic：追问域与父域无关且像新问题
        //    有明确域但和父域不重叠、且不是纠正/换范围等，倾向新话题
        if !followUpDomains.isEmpty {
            let overlap = Set(followUpDomains).intersection(parent.parentDomains)
            if overlap.isEmpty && !matchesFollowUpMarkers(text) {
                return .newTopic
            }
        }

        // 8. 兜底：无法确定
        return .ambiguous
    }

    // MARK: - 规则集

    /// executeFromResult：指向具体建议
    private static func matchesExecuteIntent(_ text: String) -> Bool {
        let markers = [
            "第一条建议", "第二条建议", "第三条建议",
            "按这个建议", "就这个建议", "采纳", "按建议",
            "创建待办", "建个待办", "加个任务", "设为待办",
            "按这个做", "照这个做", "执行这个"
        ]
        return markers.contains { text.contains($0) }
    }

    /// correct：纠正口径
    private static func matchesCorrection(_ text: String) -> Bool {
        let markers = [
            "算错", "不对", "错了", "有误", "不准确",
            "应该是", "口径", "统计有", "数不对", "不是这个数"
        ]
        return markers.contains { text.contains($0) }
    }

    /// changeScope：换时间/范围
    private static func matchesScopeChange(_ text: String) -> Bool {
        // 明确的换范围动词 + 时间词
        let changeVerbs = ["换成", "改成", "换", "改", "对比", "比较", "上", "呢"]
        let timeWords = [
            "今天", "本周", "上周", "本月", "上月", "本年", "今年", "去年",
            "近一周", "近两周", "近一个月", "近三个月", "近半年",
            "7天", "14天", "30天", "三个月", "半年", "一年",
            "这周", "那个月", "那天"
        ]
        let hasChangeVerb = changeVerbs.contains { text.contains($0) }
        let hasTimeWord = timeWords.contains { text.contains($0) }
        // 「换成今年」「改成上周」这类明确换范围
        if hasChangeVerb && hasTimeWord { return true }
        // 「上周的呢」「上月的呢」这类尾问
        if hasTimeWord && (text.hasSuffix("呢") || text.hasSuffix("的情况") || text.hasSuffix("怎么样")) {
            return true
        }
        return false
    }

    /// drillDown：深挖
    private static func matchesDrillDown(_ text: String) -> Bool {
        let markers = [
            "具体", "详细", "展开", "深入", "细看", "细分",
            "第几条", "第一条", "第二条", "第三条",
            "哪一天", "哪几天", "分别是"
        ]
        return markers.contains { text.contains($0) }
    }

    /// explain：解释
    private static func matchesExplain(_ text: String) -> Bool {
        let markers = [
            "为什么", "怎么回事", "什么意思", "什么原因", "怎么会",
            "原因是", "因为什么", "怎么解释", "怎么看这个"
        ]
        return markers.contains { text.contains($0) }
    }

    /// 追问标记词：有这些词说明用户在承接上文（不是新话题）
    private static func matchesFollowUpMarkers(_ text: String) -> Bool {
        let markers = [
            "那", "另外", "还有", "继续", "接着", "然后",
            "它", "这个", "那个", "其", "其中"
        ]
        return markers.contains { text.contains($0) }
    }

    /// 域识别（与 SemanticFrameBuilder 对齐的精简版，用于跨域判断）。
    /// 不复用 SemanticFrameBuilder 的 private 方法，保持 Router 自洽。
    private static func identifyDomains(in text: String) -> [String] {
        let domainKeywords: [(domain: String, keywords: [String])] = [
            ("finance", ["财务", "消费", "花", "支出", "收入", "账", "钱", "餐饮", "购物", "预算"]),
            ("health", ["步数", "睡眠", "运动", "健康", "站立", "心率", "锻炼", "走路"]),
            ("habit", ["习惯", "打卡", "坚持", "早起", "读书", "冥想", "体重", "体脂"]),
            ("task", ["任务", "待办", "完成", "计划", "deadline"]),
            ("goal", ["目标", "达成", "进度"]),
            ("thought", ["笔记", "想法", "记录", "心情", "日记", "反思"]),
        ]
        var found = Set<String>()
        for entry in domainKeywords {
            if entry.keywords.contains(where: { text.contains($0) }) {
                found.insert(entry.domain)
            }
        }
        return found.sorted()
    }
}
