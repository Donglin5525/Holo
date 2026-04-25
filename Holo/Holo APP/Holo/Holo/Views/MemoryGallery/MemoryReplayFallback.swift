//
//  MemoryReplayFallback.swift
//  Holo
//
//  规则兜底回放文案生成
//  无 AI 配置或生成失败时使用，确保连续 3 周不重复
//

import Foundation

/// 趋势方向
enum Trend: Equatable {
    case up
    case stable
    case down
}

/// 规则兜底回放文案生成器
enum MemoryReplayFallback {

    // MARK: - Title Variants

    /// 标题变体池：按 (habitTrend, expenseTrend, hasThoughts) 条件组合提供变体
    /// 用 weekIndex（startOfWeek 的 hash 值）做确定性轮换
    static func weeklyTitle(
        habitTrend: Trend,
        expenseTrend: Trend,
        hasThoughts: Bool,
        weekIndex: Int
    ) -> String {
        let key = "\(habitTrend)_\(expenseTrend)_\(hasThoughts)"
        let variants = titleVariants[key] ?? titleVariants["stable_stable_false"]!
        return variants[abs(weekIndex) % variants.count]
    }

    /// 摘要模板
    static func weeklySummary(
        habitTrend: Trend,
        expenseTrend: Trend,
        hasThoughts: Bool,
        weekIndex: Int,
        habitCompletedCount: Int,
        totalExpense: String,
        thoughtCount: Int
    ) -> String {
        let templateIndex = abs(weekIndex) % summaryTemplates.count
        let template = summaryTemplates[templateIndex]

        let habitDesc = habitDescription(trend: habitTrend, count: habitCompletedCount)
        let expenseDesc = expenseDescription(trend: expenseTrend, amount: totalExpense)
        let thoughtDesc = hasThoughts ? "，观点中记录了 \(thoughtCount) 条想法" : ""

        return String(format: template, habitDesc, expenseDesc, thoughtDesc)
    }

    // MARK: - Private Data

    private static let titleVariants: [String: [String]] = [
        // 习惯上升
        "up_stable_true": [
            "生活在慢慢回到节奏里",
            "坚持让你看到了变化",
            "好习惯正在积累力量",
            "自律的痕迹越来越清晰",
            "这周的节奏感很棒"
        ],
        "up_stable_false": [
            "坚持的回报正在显现",
            "习惯的节奏越来越好",
            "每一天都在积累进步",
            "自律让你越来越自在",
            "这周的坚持值得被记住"
        ],
        "up_up_true": [
            "投入的这周，收获不少",
            "行动和思考都在加速",
            "忙碌中有值得记下的变化",
            "付出在习惯和消费中都能看到",
            "这周的投入不会白费"
        ],
        "up_up_false": [
            "精力充沛的一周",
            "在行动中找到节奏",
            "投入和坚持同时发生",
            "好习惯在忙碌中存活下来",
            "这周的效率不错"
        ],
        "up_down_true": [
            "习惯在回暖，钱包在喘口气",
            "节奏回来了，支出也温柔了",
            "好消息从两个方向传来",
            "习惯和钱包都在走对的方向",
            "这周的小胜利值得庆祝"
        ],
        "up_down_false": [
            "开支减少了，习惯还在坚持",
            "生活在往好的方向微调",
            "自律和节俭同时在发生",
            "这周过得清醒又自律",
            "小确幸正在悄悄积累"
        ],
        // 习惯稳定
        "stable_stable_true": [
            "平静的一周，也有值得留意的",
            "稳定之中有自己的思考",
            "日常里藏着你的关注点",
            "这周没什么大事，但也没闲着",
            "稳定运行的一周"
        ],
        "stable_stable_false": [
            "平稳的一周，按部就班",
            "日子在正常轨道上推进",
            "没有大波动，节奏刚刚好",
            "这周的状态可以复制",
            "日常的力量在积累"
        ],
        "stable_up_true": [
            "花了点钱，但也记录了想法",
            "消费和思考同时活跃",
            "这周的支出比较显眼",
            "钱花出去了，观点也留下了",
            "在消费中也有自己的判断"
        ],
        "stable_up_false": [
            "这周开销比平时多",
            "花钱比较集中的一周",
            "钱包忙碌的七天",
            "消费记录比习惯打卡多",
            "支出提醒你关注理财"
        ],
        "stable_down_true": [
            "省着花的一周，想法倒是不少",
            "支出不多，但思考很丰富",
            "钱包安静，大脑在运转",
            "这周的钱花得克制",
            "省钱和思考同时在线"
        ],
        "stable_down_false": [
            "支出减少了，日子照常",
            "钱包在休息的一周",
            "节俭的模式运行良好",
            "这周没有冲动消费",
            "日常开支控制在合理范围"
        ],
        // 习惯下降
        "down_stable_true": [
            "这周有点松懈，但也在反思",
            "习惯打卡少了，但想法还在",
            "偶尔停下来也是一种状态",
            "这周的节奏慢了下来",
            "休息是为了更好地出发"
        ],
        "down_stable_false": [
            "这周习惯打卡偏少",
            "节奏比上周慢了一些",
            "打卡频率下降了",
            "生活节奏在调整中",
            "这周过得比较随意"
        ],
        "down_up_true": [
            "花钱多了，习惯少了，但想法不少",
            "忙碌冲淡了节奏，思考还在",
            "消费和压力可能有关联",
            "这周在消费上比较活跃",
            "花钱代替了打卡，但有在记录"
        ],
        "down_up_false": [
            "花钱多了但习惯断了",
            "忙碌让节奏有些乱",
            "消费上升，打卡下降",
            "这周可能需要调整一下",
            "支出和习惯都在提醒你注意"
        ],
        "down_down_true": [
            "开支不多，但习惯也松了",
            "一切都在降档运行",
            "这周像在蓄力",
            "低能耗运行的一周",
            "安静下来之后更清楚想要什么"
        ],
        "down_down_false": [
            "这周很安静",
            "低开支低活跃的一周",
            "生活按下了减速键",
            "这周没什么动静",
            "或许是在为下周蓄能"
        ]
    ]

    private static let summaryTemplates: [String] = [
        "%@。%@%@。",
        "本周%@@%@@。",
        "这周的记录显示：%@，%@%@。"
    ]

    // MARK: - Description Helpers

    private static func habitDescription(trend: Trend, count: Int) -> String {
        switch trend {
        case .up:
            let variants = [
                "习惯完成 \(count) 次，比上周多了",
                "打卡次数回升到 \(count) 次",
                "本周完成了 \(count) 次习惯打卡"
            ]
            return variants[count % variants.count]
        case .stable:
            let variants = [
                "习惯完成 \(count) 次，和上周持平",
                "本周打卡 \(count) 次，节奏稳定",
                "习惯完成数和上周一致，\(count) 次"
            ]
            return variants[count % variants.count]
        case .down:
            let variants = [
                "习惯完成 \(count) 次，比上周少了一些",
                "本周打卡 \(count) 次，有所下降",
                "习惯完成率有所回落，\(count) 次"
            ]
            return variants[count % variants.count]
        }
    }

    private static func expenseDescription(trend: Trend, amount: String) -> String {
        switch trend {
        case .up:
            let variants = [
                "支出 \(amount)，比上周多",
                "本周花了 \(amount)，消费有所增加",
                "支出上升到 \(amount)"
            ]
            return variants[amount.count % variants.count]
        case .stable:
            let variants = [
                "支出 \(amount)，变化不大",
                "本周花费 \(amount)，和上周差不多",
                "支出保持在 \(amount)"
            ]
            return variants[amount.count % variants.count]
        case .down:
            let variants = [
                "支出 \(amount)，有所减少",
                "本周花了 \(amount)，比上周省了一些",
                "支出降到 \(amount)"
            ]
            return variants[amount.count % variants.count]
        }
    }
}
