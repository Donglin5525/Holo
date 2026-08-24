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
        case .crossDomain: return "跨域洞察"
        case .finance: return "财务分析"
        case .habit: return "习惯分析"
        case .health: return "睡眠与健康"
        case .task: return "任务效率"
        case .thought: return "想法洞察"
        case .goal: return "目标复盘"
        case .longTermPattern: return "长期模式"
        }
    }

    var subtitle: String {
        switch self {
        case .crossDomain: return "全域交叉，发现补偿回路类规律"
        case .finance: return "支出结构 / 超预算归因 / 异常消费"
        case .habit: return "掉档规律 / 断签恢复 / 数值走势"
        case .health: return "睡眠规律 / 运动量 / 活跃节奏"
        case .task: return "完成率 / 拖延模式 / 截止压力"
        case .thought: return "反复出现的念头 / 主题走向"
        case .goal: return "进度 / 量化走势 / 风险信号"
        case .longTermPattern: return "Holo 眼中的你（画像问答）"
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

    /// 预填问句的三条设计约束（2026-08-22 校验）：
    /// 1. 意图词面——每句必含「分析/复盘」之一，稳定命中后端 query_analysis
    ///    （意图注册表触发词：分析、复盘、趋势、结构、占比、总结），防被
    ///    查任务/打卡/周规划/普通问答等相邻意图抢走；长期模式例外，走普通对话。
    /// 2. 时间锚点——单域问句必含「最近」，给时间语义解析一个明确落点。
    /// 3. 开放式聚焦——跨域绝不点名具体域（数据在哪个域就分析哪个域，由
    ///    Agent 的动态工具发现决定）；单域用「重点看/比如/也」给方向不给封闭清单。
    var question: String {
        switch self {
        case .crossDomain: return "把我的各类生活数据放在一起做一次深度分析，重点找出单看一处发现不了的规律"
        case .finance: return "深度分析一下我最近的财务状况，重点看支出结构和预算执行，有异常消费也指出来"
        case .habit: return "深度分析一下我最近的习惯坚持情况，哪些天容易掉档、可能和什么有关"
        case .health: return "深度分析一下我最近的睡眠和健康数据，比如睡眠规律、运动日和不运动日的差别"
        case .task: return "分析一下我最近的任务完成情况和拖延模式"
        case .thought: return "分析一下我最近反复在想的主题，想法的走向和变化"
        case .goal: return "复盘一下我的目标进度，有风险信号也提醒我"
        case .longTermPattern: return "你了解我哪些长期偏好和模式？"
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

    /// 额度快照未就绪时不显示数字（不猜），只说明共用关系
    private var quotaSuffix: String {
        guard let snapshot = HoloEntitlementState.shared.quotas["deepAnalysis"] else {
            return ""
        }
        return " · 本月剩余 \(snapshot.remaining)/\(snapshot.limit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("选一个分析场景")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: 8)

                Text("分析场景共用每月深度洞察额度\(quotaSuffix)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.holoStarTint)
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AnalysisScenario.allCases) { scenario in
                    scenarioCard(scenario)
                }
            }

            Text("长期模式为画像问答，不占分析额度；选中场景只预填问句，发送由你确认")
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
        .accessibilityHint("把该场景的问句填进输入框，由你确认发送")
    }
}
