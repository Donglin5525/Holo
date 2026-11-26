//
//  HoloPlusActionCoordinator.swift
//  Holo
//
//  统一管理付费墙及购买成功后的原操作恢复。
//

import Combine
import Foundation

@MainActor
final class HoloPlusActionCoordinator: ObservableObject {
    static let shared = HoloPlusActionCoordinator()

    @Published var isPaywallPresented = false
    @Published private(set) var context: HoloPlusGateContext = .membershipCenter

    private var pendingAction: (() async -> Void)?
    /// 购买成功、付费墙正在收起：收起动画落定（paywallDidDismiss）后才续接原操作
    private var isAwaitingDismissal = false

    /// 冷启动空窗期门禁最多等多久：覆盖一次状态请求的正常往返，弱网下到点按现有快照判
    private static let startupGraceSeconds: TimeInterval = 4

    private init() {}

    /// 非 Plus 用户触发 Plus 权益的统一入口：弹付费墙，购买成功后执行 `resume` 续接原操作。
    /// 未购买直接关闭 = 放弃原操作，回到原处（2026-11-24 东林拍板「所见即所得」：关掉
    /// 付费墙不再打开任何页面——旧设计的 onDismiss 续做会让小组件跳转、分期设置在关墙
    /// 之后才出现，分期更是关墙也能用的漏网口子）。
    func requirePlus(
        context: HoloPlusGateContext,
        resume: (() async -> Void)? = nil
    ) {
        // 冷启动空窗期：本进程还没完成过权益刷新时，内存里的「免费」可能只是磁盘上的旧快照
        // （续订空档落盘的免费态、不落盘的内部验收态），不能拿它拦会员——等刷新落定再判
        if !HoloEntitlementState.shared.hasSettledStatus {
            Task {
                await HoloEntitlementState.shared.waitForFirstStatus(timeout: Self.startupGraceSeconds)
                if HoloEntitlementState.shared.isPlusActive {
                    await resume?()
                } else {
                    presentPaywall(context: context, resume: resume)
                }
            }
            return
        }
        presentPaywall(context: context, resume: resume)
    }

    private func presentPaywall(context: HoloPlusGateContext, resume: (() async -> Void)?) {
        self.context = context
        pendingAction = resume
        isPaywallPresented = true
    }

    /// 用户未购买直接关闭：放弃原操作
    func dismissPaywall() {
        pendingAction = nil
        isPaywallPresented = false
    }

    /// 购买成功：先收付费墙，等收起动画落定再续接原操作——续接常要开新页面，
    /// 撞在收起转场上发起的呈现会被丢弃。
    func resumeAfterSuccessfulPurchase() async {
        guard isPaywallPresented else { return }
        isAwaitingDismissal = true
        isPaywallPresented = false
    }

    /// 置顶弹层收起动画落定后由 App 根视图回调
    func paywallDidDismiss() {
        guard isAwaitingDismissal else { return }
        isAwaitingDismissal = false
        let action = pendingAction
        pendingAction = nil
        Task { await action?() }
    }
}

/// 付费墙置顶呈现的 item（holoTopSheet 需要 Identifiable；协调器仍是唯一状态源）
struct HoloPlusPaywallRequest: Identifiable, Equatable {
    let context: HoloPlusGateContext
    var id: Int { 0 }
}

enum HoloPlusGateContext: Equatable {
    case membershipCenter
    case holoAI
    /// 深度洞察每日额度用完（免费 1 次/天，Plus 10 次/天）
    case deepAnalysis
    /// 每周生活计划额度用完（免费 1 次/周，Plus 2 次/周）
    case lifePlan
    case memoryGallery
    case financeInstallment
    case billingCycle
    /// 信用卡还款提醒超出免费 3 张
    case creditCardReminder
    /// 订阅到期提醒超出免费 3 个
    case subscriptionReminder
    case budget
    case desktopWidget
    case asrQuota
    case asrDuration
    case naturalLanguageFinance
    case naturalLanguageTask
    case habitRetroactiveCheckIn
    case habitPause
    case billImportAI
    case taskSplit
    /// 「一个发现」洞察每周额度用完（预算墙，2026-11-21）
    case discoveryInsightWeekly

    var title: String {
        switch self {
        case .membershipCenter:
            return String(localized: "把生活交给更懂你的 Holo")
        case .holoAI:
            return String(localized: "聊到一半不用停，继续问 Holo")
        case .deepAnalysis:
            return String(localized: "让 Holo 把这件事帮你挖透")
        case .lifePlan:
            return String(localized: "随时调整这一周的生活节奏")
        case .memoryGallery:
            return String(localized: "每天都能刷新你的记忆洞察")
        case .financeInstallment:
            return String(localized: "把每一笔分期账单理得清清楚楚")
        case .billingCycle:
            return String(localized: "按你的发薪日自定义账单周期")
        case .creditCardReminder:
            return String(localized: "多张信用卡还款不再漏提醒")
        case .subscriptionReminder:
            return String(localized: "每一笔订阅到期前都不再错过")
        case .budget:
            return String(localized: "把每月预算与消费节奏握在手里")
        case .desktopWidget:
            return String(localized: "在桌面一键记录与回看生活")
        case .asrQuota:
            return String(localized: "语音记录更从容，额度大幅提升")
        case .asrDuration:
            return String(localized: "一口气说完，不用被 60 秒打断")
        case .naturalLanguageFinance:
            return String(localized: "继续用自然语言快速记账")
        case .naturalLanguageTask:
            return String(localized: "继续用自然语言拆解与记录任务")
        case .habitRetroactiveCheckIn:
            return String(localized: "无限次补签，不让一次漏打断连胜")
        case .habitPause:
            return String(localized: "请假或生病时暂停习惯，守住连续记录")
        case .billImportAI:
            return String(localized: "一键智能导入历史账单")
        case .taskSplit:
            return String(localized: "把复杂任务拆成可执行的小步骤")
        case .discoveryInsightWeekly:
            return String(localized: "让 Holo 每周多帮你看几件事")
        }
    }
}
