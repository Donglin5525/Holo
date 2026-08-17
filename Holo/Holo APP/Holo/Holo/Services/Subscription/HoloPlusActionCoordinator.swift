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

    private init() {}

    func requirePlus(
        context: HoloPlusGateContext,
        resume: (() async -> Void)? = nil
    ) {
        self.context = context
        pendingAction = resume
        isPaywallPresented = true
    }

    func dismissPaywall() {
        isPaywallPresented = false
        pendingAction = nil
    }

    func resumeAfterSuccessfulPurchase() async {
        isPaywallPresented = false
        let action = pendingAction
        pendingAction = nil
        await action?()
    }
}

enum HoloPlusGateContext: Equatable {
    case membershipCenter
    case holoAI
    case memoryGallery
    case financeInstallment
    case billingCycle
    case budget
    case advancedStatistics
    case desktopWidget
    case asrQuota
    case asrDuration
    case naturalLanguageFinance
    case naturalLanguageTask
    case habitRetroactiveCheckIn
    case billImportAI

    var title: String {
        switch self {
        case .membershipCenter:
            return "升级 Holo Plus"
        case .holoAI:
            return "升级 Holo Plus，继续和 HoloAI 对话"
        case .memoryGallery:
            return "升级 Holo Plus，刷新记忆洞察"
        case .financeInstallment:
            return "升级 Holo Plus，使用财务分期"
        case .billingCycle:
            return "升级 Holo Plus，使用周期账单"
        case .budget:
            return "升级 Holo Plus，使用预算管理"
        case .advancedStatistics:
            return "升级 Holo Plus，解锁跨月类别对比"
        case .desktopWidget:
            return "升级 Holo Plus，解锁桌面小组件"
        case .asrQuota:
            return "升级 Holo Plus，继续使用语音识别"
        case .asrDuration:
            return "升级 Holo Plus，录制更长语音"
        case .naturalLanguageFinance:
            return "升级 Holo Plus，继续智能记账"
        case .naturalLanguageTask:
            return "升级 Holo Plus，继续智能任务"
        case .habitRetroactiveCheckIn:
            return "升级 Holo Plus，无限次补签找回断签"
        case .billImportAI:
            return "升级 Holo Plus，使用账单智能导入"
        }
    }
}
