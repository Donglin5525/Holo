//
//  HoloAgentFollowUpRouter.swift
//  Holo
//
//  连续追问关系路由。规则宁可漏判，也不把新问题错误锚到旧结果。
//

import Foundation

nonisolated struct HoloAgentFollowUpParentContext: Sendable {
    var parentDomains: [String]
    var hasRecommendations: Bool
}

nonisolated enum HoloAgentFollowUpRouter {
    static func classify(
        followUpText: String,
        parent: HoloAgentFollowUpParentContext
    ) -> HoloAgentFollowUpRelation {
        let text = normalized(followUpText)
        guard !text.isEmpty else { return .ambiguous }

        if parent.hasRecommendations && containsAny(text, [
            "第一条建议", "第二条建议", "第三条建议", "按这个建议", "就这个建议",
            "采纳", "按建议", "创建待办", "建个待办", "加个任务", "设为待办",
            "按这个做", "照这个做", "执行这个"
        ]) {
            return .executeFromResult
        }

        if containsAny(text, [
            "算错", "不对", "错了", "有误", "不准确", "应该是", "统计口径",
            "统计有问题", "数不对", "不是这个数"
        ]) {
            return .correct
        }

        if matchesScopeChange(text) {
            return .changeScope
        }

        let followUpDomains = identifyDomains(in: text)
        if !followUpDomains.isEmpty, !parent.parentDomains.isEmpty,
           Set(followUpDomains).isDisjoint(with: parent.parentDomains) {
            return hasFollowUpMarker(text) ? .crossDomain : .newTopic
        }

        if containsAny(text, [
            "具体", "详细", "展开", "深入", "细看", "细分", "第几条", "第一条",
            "第二条", "第三条", "哪一天", "哪几天", "分别是"
        ]) {
            return .drillDown
        }

        if containsAny(text, [
            "为什么", "怎么回事", "什么意思", "什么原因", "怎么会", "原因是",
            "因为什么", "怎么解释", "怎么看这个"
        ]) {
            return .explain
        }

        return hasFollowUpMarker(text) ? .explain : .ambiguous
    }

    /// 同一会话内的自然相邻追问。超出窗口或缺少承接词时不自动锚定。
    static func implicitRelation(
        text: String,
        parent: HoloAgentFollowUpParentContext,
        parentCompletedAt: Date,
        now: Date = Date(),
        confirmationWindow: TimeInterval = 4 * 3_600
    ) -> HoloAgentFollowUpRelation? {
        let text = normalized(text)
        guard now.timeIntervalSince(parentCompletedAt) >= 0,
              now.timeIntervalSince(parentCompletedAt) <= confirmationWindow,
              hasFollowUpMarker(text) else {
            return nil
        }
        let relation = classify(followUpText: text, parent: parent)
        // 执行建议也允许自然相邻承接，但下游只能生成待确认草案，不能直接写数据。
        return relation.isFollowUp ? relation : nil
    }

    static func identifyDomains(in text: String) -> [String] {
        let text = normalized(text)
        let domainKeywords: [(String, [String])] = [
            ("finance", ["财务", "消费", "花费", "支出", "收入", "账单", "金额", "预算", "餐饮", "购物"]),
            ("health", ["步数", "睡眠", "运动", "健康", "站立", "心率", "锻炼", "走路"]),
            ("habit", ["习惯", "打卡", "坚持", "早起", "读书", "冥想", "体重", "体脂"]),
            ("task", ["任务", "待办", "完成", "截止", "deadline"]),
            ("goal", ["目标", "达成", "目标进度"]),
            ("thought", ["笔记", "想法", "心情", "日记", "反思"]),
            ("memory", ["记忆", "长期规律"]),
            ("profile", ["档案", "偏好", "个人信息"])
        ]
        return domainKeywords.compactMap { domain, keywords in
            keywords.contains(where: text.contains) ? domain : nil
        }.sorted()
    }

    static func hasFollowUpMarker(_ text: String) -> Bool {
        let normalizedText = normalized(text)
        return containsAny(normalizedText, [
            "那", "另外", "还有", "继续", "接着", "然后", "换成", "改成", "呢",
            "它", "这个", "那个", "其中", "具体", "详细", "为什么", "第一条", "第二条", "第三条"
        ])
    }

    private static func matchesScopeChange(_ text: String) -> Bool {
        let timeWords = [
            "今天", "本周", "上周", "本月", "上月", "本年", "今年", "去年", "近一周",
            "近两周", "近一个月", "近三个月", "近半年", "7天", "14天", "30天",
            "三个月", "半年", "一年", "这周", "那个月", "那天",
            "近2周", "近3个月", "近6个月", "近1年", "近2年", "近3月", "近1月",
            "上个月", "这个月", "下个月"
        ]
        guard containsAny(text, timeWords) else { return false }
        return containsAny(text, ["换成", "改成", "对比", "比较"])
            || text.hasSuffix("呢")
            || text.hasSuffix("的情况")
            || text.hasSuffix("怎么样")
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains(where: text.contains)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
