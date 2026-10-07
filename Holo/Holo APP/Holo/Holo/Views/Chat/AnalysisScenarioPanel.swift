//
//  AnalysisScenarioPanel.swift
//  Holo
//
//  「深度分析」胶囊的场景面板（甲方案，2026-08-22 东林拍板）。
//  把 Holo 能做的深度分析在发起前显性摊开：8 个场景（跨域洞察置顶王牌 +
//  6 单域 + 长期模式画像问答）。选中只做一件事——预填问句到输入框，
//  发送确认权在用户（东林确立的原则，全 App 发起类交互统一遵守）。
//

import SwiftUI

/// 分析场景目录。问句是我们自己预填的，词表封闭——
/// 档案场景归类（关键词匹配）与此处同源，未来意图识别出场景字段可零成本切换。
enum AnalysisScenario: String, CaseIterable, Identifiable {
    case crossDomain
    case finance
    case habit
    case health
    case task
    case thought
    case goal
    case longTermPattern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossDomain: return String(localized: "跨域洞察")
        case .finance: return String(localized: "财务分析")
        case .habit: return String(localized: "习惯分析")
        case .health: return String(localized: "睡眠与健康")
        case .task: return String(localized: "任务效率")
        case .thought: return String(localized: "想法洞察")
        case .goal: return String(localized: "目标复盘")
        case .longTermPattern: return String(localized: "长期模式")
        }
    }

    var subtitle: String {
        switch self {
        case .crossDomain: return String(localized: "找出同一段时间一起变化的节奏")
        case .finance: return String(localized: "钱花在哪 / 大额还是小额 / 与上段相比")
        case .habit: return String(localized: "哪项在变 / 何时中断 / 怎么恢复")
        case .health: return String(localized: "睡眠与作息的变化和边界")
        case .task: return String(localized: "完成了什么 / 该先处理什么")
        case .thought: return String(localized: "反复出现的主题 / 想法的变化")
        case .goal: return String(localized: "走到哪一步 / 下一步怎么选")
        case .longTermPattern: return String(localized: "Holo 眼中的你（画像问答）")
        }
    }

    /// SF Symbol
    var icon: String {
        switch self {
        case .crossDomain: return "link"
        case .finance: return "banknote"
        case .habit: return "calendar.badge.checkmark"
        case .health: return "moon.zzz"
        case .task: return "checklist"
        case .thought: return "lightbulb"
        case .goal: return "target"
        case .longTermPattern: return "brain.head.profile"
        }
    }

    /// 预填问句（2026-09-19 深度分析提示词与证据链落地方案 §2 定稿）：
    /// 一个明确疑问 + 一种可核对的比较/定位 + 诚实的数据边界，内部分析
    /// 方法（工具/口径/维度）不塞给用户。句式三约束：
    /// 1. 疑问句式——问「想知道什么」，不说「分析一下 X 重点看 A/B」的功能说明；
    /// 2. 可核对——问句自带比较对象或定位方式，答案可被证据核对；
    /// 3. 边界诚实——「现有记录能说明到什么程度」「还有什么不能确定」让
    ///    缺数据的部分说不能判断，而不是装能答。
    var question: String {
        switch self {
        case .crossDomain: return "最近有哪些生活节奏是在同一段时间一起变化的？请先找最值得核对的一组，告诉我各自发生了什么、时间是否对得上，以及还有什么不能确定。"
        case .finance: return "最近的钱主要花在了哪里？是少数大额支出，还是多笔小额慢慢累积？如果与上一段可比时间不同，变化主要来自哪些分类？"
        case .habit: return "最近哪项习惯的记录出现了明显变化？我更容易在哪些时候中断，又通常怎样重新开始？"
        case .health: return "最近我的睡眠时长和作息节奏有变化吗？哪些天与平时不同，现有记录能说明到什么程度？"
        case .task: return "最近完成了哪些任务，还有哪些重要任务尚未推进？从已有的截止时间看，最值得我先处理的是哪一件？"
        case .thought: return "最近我反复记下了哪些主题？哪些想法在变化，哪些只是重复出现但还没有结论？"
        case .goal: return "我选的这个目标现在走到哪一步？哪些已完成的行动真的推动了它，下一步该继续、调整，还是先暂停？"
        case .longTermPattern: return "你了解我哪些长期偏好和模式？"
        }
    }

    /// 冻结回答任务的元数据（AnalysisAnswerTaskV1，随快照上云）：
    /// 场景选中即绑定——用户改写问句不丢场景，范围/类型/清单由客户端
    /// 与后端能力目录共同冻结，不靠问句词面猜意图。
    /// 问题类型：事实/比较/诊断/关联/决策（fact/comparison/diagnosis/correlation/decision）。
    var answerTaskKind: String {
        switch self {
        case .crossDomain: return "correlation"
        case .finance, .habit, .health, .goal: return "diagnosis"
        case .task: return "decision"
        case .thought: return "fact"
        case .longTermPattern: return "general"
        }
    }

    /// 回答清单：问句拆出的子问，逐项回答；缺证据的项由模型明确说不能判断。
    var answerChecklist: [String] {
        switch self {
        case .crossDomain: return ["同一段时间一起变化的一组节奏", "各自发生了什么、时间是否对得上", "仍不能确定的部分"]
        case .finance: return ["钱主要花在了哪里（大额还是小额累积）", "与上一段可比时间的变化", "变化主要来自哪些分类"]
        case .habit: return ["哪项习惯记录明显变化", "更容易在哪些时候中断", "通常怎样重新开始"]
        case .health: return ["睡眠时长与作息节奏的变化", "哪些天与平时不同", "现有记录能说明到什么程度"]
        case .task: return ["完成了哪些任务", "哪些重要任务尚未推进", "按截止时间最值得先处理的一件"]
        case .thought: return ["反复记下的主题", "哪些想法在变化", "哪些只是重复出现还没有结论"]
        case .goal: return ["目标当前走到哪一步", "已完成行动的实际推动", "继续/调整/暂停的判断"]
        case .longTermPattern: return []
        }
    }

    /// 主时间范围默认窗（天）。nil = 不冻结主范围（目标复盘看目标全程、
    /// 长期模式走普通对话），由快照窗口兜底；其余场景默认最近 30 天，
    /// 用户在问句中自己指定的时间始终优先。
    var defaultRangeDays: Int? {
        switch self {
        case .crossDomain, .finance, .habit, .health, .task, .thought: return 30
        case .goal, .longTermPattern: return nil
        }
    }

    /// 跨域洞察是 Holo 的差异化王牌，置顶 + 皇冠标识
    var isFeatured: Bool { self == .crossDomain }

    /// 长期模式走普通对话（画像问答），不占深度洞察额度
    var consumesAnalysisQuota: Bool { self != .longTermPattern }
}

/// 场景面板：标题 + 额度说明 + 两列场景卡。
struct AnalysisScenarioPanel: View {
    var onSelect: (AnalysisScenario) -> Void

    /// 额度随订阅状态实时刷新（选场景时也会触发一次 refreshStatus）
    @ObservedObject private var entitlement = HoloEntitlementState.shared

    /// 额度快照未就绪时不显示数字（不猜），只说明共用关系
    private var quotaSuffix: String {
        guard let snapshot = entitlement.quotas["deepAnalysis"] else {
            return ""
        }
        return String(localized: " · 今日剩余 \(snapshot.remaining)/\(snapshot.limit)")
    }

    /// 后端口径为按天（免费 2/天、Plus 10/天）；用尽当天置灰场景卡，长期模式不受影响
    private var dailyQuotaExhausted: Bool {
        guard let snapshot = entitlement.quotas["deepAnalysis"] else { return false }
        return snapshot.remaining <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("选一个分析场景")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: 8)

                Text("分析场景共用每日深度洞察额度\(quotaSuffix)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.holoStarTint)
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                // 长期模式移出分析额度目录（2026-09-19 方案 §2）：它是普通画像
                // 问答，与「消耗深度分析额度」的七个场景分开展示，避免误导。
                ForEach(AnalysisScenario.allCases.filter(\.consumesAnalysisQuota)) { scenario in
                    scenarioCard(scenario)
                        .disabled(dailyQuotaExhausted)
                        .opacity(dailyQuotaExhausted ? 0.45 : 1)
                }
            }

            if dailyQuotaExhausted {
                Text("今日分析额度已用完，明天重置；长期模式问答不受影响")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.holoStarTint)
            }

            Button {
                onSelect(.longTermPattern)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: AnalysisScenario.longTermPattern.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                    Text("不占额度：问问 Holo 眼中的你（长期模式画像问答）")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("选中场景只预填问句，可自由改写；改写后仍按该场景分析，发送由你确认")
                .font(.system(size: 9.5))
                .foregroundColor(.holoTextSecondary.opacity(0.85))
        }
        .padding(12)
        .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(Color.holoDivider.opacity(0.5), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 12, y: 5)
    }

    private func scenarioCard(_ scenario: AnalysisScenario) -> some View {
        Button {
            onSelect(scenario)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: scenario.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoPrimary)

                    Text(scenario.title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    if scenario.isFeatured {
                        Text("王牌")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.holoPrimary.opacity(0.1), in: Capsule())
                    }

                    Spacer(minLength: 0)
                }

                Text(scenario.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                    .stroke(
                        scenario.isFeatured ? Color.holoPrimary.opacity(0.35) : Color.holoDivider.opacity(0.6),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scenario.title)，\(scenario.subtitle)")
        .accessibilityHint(String(localized: "把该场景的问句填进输入框，由你确认发送"))
    }
}
