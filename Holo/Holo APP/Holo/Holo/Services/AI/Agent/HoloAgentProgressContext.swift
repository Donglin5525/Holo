//
//  HoloAgentProgressContext.swift
//  Holo
//
//  深度分析进度文案的动态上下文：基于意图识别（LLM 结构化输出）返回的
//  领域/子领域/时间窗，让等待文案贴合本次分析内容，而非固定话术。
//

/// 从意图识别 extractedData 提取的分析上下文
nonisolated struct HoloAgentProgressContext: Equatable, Sendable {
    /// 用户关注的数据域中文名（「睡眠」「记账」「任务」…）；nil 表示未识别
    var domainLabel: String?
    /// 时间窗描述（「最近」「本周」「这个月」…）
    var periodLabel: String?
    /// 周计划生成
    var isWeeklyPlanning: Bool = false

    /// 从意图识别的结构化字段构建（query_analysis 的 analysisDomain/subDomain/periodLabel）
    init(extractedData: [String: String]?, isWeeklyPlanning: Bool = false) {
        self.isWeeklyPlanning = isWeeklyPlanning
        if isWeeklyPlanning { return }
        let domain = extractedData?["analysisDomain"] ?? ""
        let subDomain = extractedData?["subDomain"] ?? ""
        let period = extractedData?["periodLabel"] ?? ""
        periodLabel = period.isEmpty ? nil : period
        domainLabel = Self.domainLabel(domain: domain, subDomain: subDomain)
    }

    /// 域名映射（子领域优先，粒度更贴用户说法）
    nonisolated static func domainLabel(domain: String, subDomain: String) -> String? {
        switch (domain, subDomain) {
        case (_, "sleep"): return "睡眠"
        case (_, "steps"), (_, "activity"): return "活动"
        case (_, "weight"): return "体重"
        case (_, "heart"): return "心率"
        case (_, "mood"): return "心情"
        case (_, let sub) where ["expense", "income", "budget"].contains(sub): return "收支"
        case ("health", ""): return "健康"
        case ("finance", ""): return "记账"
        case ("task", ""), ("todo", ""): return "任务"
        case ("habit", ""): return "习惯"
        case ("goal", ""): return "目标"
        case ("thought", ""): return "想法"
        case ("cross_domain", ""), ("crossDomain", ""): return "多方面数据"
        case ("", ""): return nil
        case (let d, ""): return d
        default: return subDomain
        }
    }

    /// 组装「分析对象」短语：如「最近的睡眠」「多方面数据」；无上下文返回 nil
    var analysisTargetPhrase: String? {
        if isWeeklyPlanning { return "本周各域数据" }
        switch (domainLabel, periodLabel) {
        case let (d?, p?): return "\(p)的\(d)"
        case let (d?, nil): return d
        case let (nil, p?): return "\(p)的记录"
        default: return nil
        }
    }

    /// 预计时长的诚实提示（基于预算档上限）
    var expectedDurationHint: String {
        isWeeklyPlanning ? "预计 1–2 分钟" : "深度分析可能需要 1–3 分钟，可以离开页面"
    }
}
