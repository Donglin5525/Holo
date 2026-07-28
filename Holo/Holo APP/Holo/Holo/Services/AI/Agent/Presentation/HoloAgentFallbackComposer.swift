//
//  HoloAgentFallbackComposer.swift
//  Holo
//
//  Agent 兜底文案生成器（有人味儿的离线兜底）
//
//  作用：当 Agent 结论未通过核验、或 LLM 不可用时，基于已有的 evidence（数据点）
//  生成带温度的兜底文案，而不是干巴巴的"暂无数据"或冷冰冰的模板事实句。
//
//  设计复用周期回放 MemoryReplayFallback 的"条件键 → 变体池 → 确定性轮换"三段式：
//  按数据域（健康/财务/习惯…）× 趋势方向（上升/平稳/下降）选变体，用 hash 轮换防重复。
//  文案本身带人情味，读起来像一个懂你的朋友在说"数据我都翻过了，但目前还看不太出明确趋势"。
//

import Foundation

/// Agent 兜底文案生成器（纯规则，零 LLM，离线可用）
nonisolated enum HoloAgentFallbackComposer {

    /// 数据域：决定兜底文案谈的是哪个生活侧面
    enum Domain: String, Sendable {
        case health      // 睡眠/步数/站立/活动/运动
        case finance     // 支出/预算/账单
        case habit       // 习惯打卡
        case task        // 任务/待办
        case thought     // 想法/心情
        case mixed       // 多域混合或无法归类

        /// 从 evidence 的 sourceModule 推断主域
        static func dominant(from evidence: [HoloEvidenceRecord]) -> Domain {
            var counts: [Domain: Int] = [:]
            for record in evidence {
                let domain: Domain
                switch record.sourceModule {
                case .health: domain = .health
                case .finance: domain = .finance
                case .habit: domain = .habit
                case .task: domain = .task
                case .thought: domain = .thought
                default: domain = .mixed
                }
                counts[domain, default: 0] += 1
            }
            // 取出现次数最多的域；无明确主域则归 mixed
            if let top = counts.max(by: { $0.value < $1.value }),
               top.key != .mixed, top.value > 0 {
                return top.key
            }
            return .mixed
        }
    }

    /// 生成兜底标题：承认结论未成形，但表明数据已被翻阅
    /// - Parameters:
    ///   - domain: 主数据域
    ///   - trend: 整体趋势方向（无法判断时传 .stable）
    ///   - seed: 确定性轮换种子（用 jobID 或时间范围的 hash，保证同次结果稳定、不同次轮换）
    static func title(domain: Domain, trend: Trend, seed: Int) -> String {
        let key = "\(domain.rawValue)_\(trend)"
        let variants = titleVariants[key] ?? titleVariants["mixed_stable"] ?? ["先把数据整理出来了"]
        return variants[abs(seed) % variants.count]
    }

    /// 生成兜底正文：把"结论不完整"转成有人味儿的解释 + 引导用户关注数据明细
    /// - Parameters:
    ///   - domain: 主数据域
    ///   - trend: 整体趋势方向
    ///   - dataPointCount: 已核对的数据点数量（用于让文案具体）
    ///   - seed: 确定性轮换种子
    static func body(domain: Domain, trend: Trend, dataPointCount: Int, seed: Int) -> String {
        let templateIndex = abs(seed) % bodyTemplates.count
        let template = bodyTemplates[templateIndex]
        let domainHint = domainHintText(domain)
        let trendHint = trendHintText(domain: domain, trend: trend, count: dataPointCount)
        return String(format: template, domainHint, trendHint)
    }

    // MARK: - 变体池

    /// 标题变体：按 domain_trend 组合，每个组合多条，hash 轮换防重复
    /// 语气基调：诚实（不假装看出了趋势）+ 温度（像一个朋友翻完数据后说的大白话）
    private static let titleVariants: [String: [String]] = [
        // 健康
        "health_up": [
            "这段时间的状态在往好的方向走",
            "身体记录里有回暖的迹象",
            "几个指标都在慢慢变好"
        ],
        "health_stable": [
            "身体数据翻过了，暂时没有明显波动",
            "健康记录比较平稳",
            "这段时间的节奏还算稳定"
        ],
        "health_down": [
            "身体数据有点往下走",
            "这段时间的健康记录偏弱一些",
            "几个指标出现了回落"
        ],
        // 财务
        "finance_up": [
            "这段时间的花销涨上来了",
            "钱包比之前忙了一些",
            "支出在往上走"
        ],
        "finance_stable": [
            "花销整体还算稳",
            "钱包没什么大起大落",
            "支出保持在熟悉的区间"
        ],
        "finance_down": [
            "这段时间花钱克制了不少",
            "支出降下来了",
            "钱包喘了口气"
        ],
        // 习惯
        "habit_up": [
            "打卡在回暖",
            "坚持的痕迹越来越清晰",
            "好习惯正在找回节奏"
        ],
        "habit_stable": [
            "打卡节奏比较稳",
            "习惯在按部就班地推进",
            "坚持的状态没怎么变"
        ],
        "habit_down": [
            "这段时间打卡少了一些",
            "习惯的节奏慢了下来",
            "坚持出现了中断"
        ],
        // 任务（任务无明确趋势语义，统一用中性）
        "task_stable": [
            "待办都翻过了",
            "任务情况整理出来了",
            "这段时间的事都过了一遍"
        ],
        // 想法
        "thought_stable": [
            "你写下的想法都读过了",
            "记录里的思考整理出来了",
            "这段时间的念头都被翻到了"
        ],
        // 混合 / 无法归类
        "mixed_stable": [
            "先把这段时间的数据整理出来了",
            "记录都翻过了，目前还看不出明确结论",
            "数据明细都在，但趋势还不够清晰"
        ]
    ]

    /// 正文模板：%@ = 域提示，%@ = 趋势/数据提示
    private static let bodyTemplates: [String] = [
        "%@%@。完整结论还需要再多几天数据才能稳，下面是已经核对过的明细，你可以先看看。",
        "%@%@。这次没能形成特别确定的判断，但数据我都逐条核对过了，放在下面供你参考。",
        "%@%@。趋势还不够清晰到能下结论，不过原始记录都在，先从你觉得最重要的那条开始看。"
    ]

    // MARK: - 描述 Helpers

    private static func domainHintText(_ domain: Domain) -> String {
        switch domain {
        case .health: return "这段时间的健康数据"
        case .finance: return "这段时间的消费记录"
        case .habit: return "这段时间的习惯打卡"
        case .task: return "这段时间的待办"
        case .thought: return "这段时间的想法"
        case .mixed: return "这段时间的各项记录"
        }
    }

    private static func trendHintText(domain: Domain, trend: Trend, count: Int) -> String {
        // 没有足够数据点时不强行谈趋势，只报数据量
        guard count >= 2 else {
            return "（已核对 \(count) 条）"
        }
        switch trend {
        case .up:
            switch domain {
            case .health: return "整体在往好的方向走（已核对 \(count) 条）"
            case .finance: return "支出有所上升（已核对 \(count) 条）"
            case .habit: return "打卡在回暖（已核对 \(count) 条）"
            default: return "数值整体在上升（已核对 \(count) 条）"
            }
        case .down:
            switch domain {
            case .health: return "有点偏弱（已核对 \(count) 条）"
            case .finance: return "花销降下来了（已核对 \(count) 条）"
            case .habit: return "打卡少了一些（已核对 \(count) 条）"
            default: return "数值整体在下降（已核对 \(count) 条）"
            }
        case .stable:
            return "比较平稳（已核对 \(count) 条）"
        }
    }
}
