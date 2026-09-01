//
//  HoloPlusPaywallView.swift
//  Holo
//
//  Holo Plus 统一付费墙。
//
//  转化结构（对标主流订阅页）：
//  价值主张 → 权益速览 → 方案选择（年订默认选中 + 立省徽章）→ 主购买按钮 → 合规披露。
//  价格一律取自 StoreKit 商品，不硬编码金额。
//

import StoreKit
import SwiftUI

struct HoloPlusPaywallView: View {
    let context: HoloPlusGateContext

    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @ObservedObject private var subscriptionService = HoloSubscriptionService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selectedProductId: String?
    @State private var isComparisonPresented = false
    /// 各商品的免费试用资格（introductory offer），key 为 productId
    @State private var trialEligibility: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    hero
                    benefits
                    comparisonEntry
                    planSection
                    purchaseSection
                    subscriptionDisclosure
                    restoreButton
                    legalLinks
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("Holo Plus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        HoloPlusActionCoordinator.shared.dismissPaywall()
                        dismiss()
                    }
                }
            }
            .task {
                await subscriptionService.loadProducts()
                if selectedProductId == nil {
                    // 年订阅默认选中（转化最优的档位放默认位）
                    selectedProductId = yearlyProduct?.id
                        ?? subscriptionService.products.first?.id
                }
                await refreshTrialEligibility()
            }
            .sheet(isPresented: $isComparisonPresented) {
                HoloPlusComparisonView()
            }
        }
    }

    // MARK: - 顶部价值主张

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(HoloPlusTheme.darkGradient)

            Circle()
                .fill(HoloPlusTheme.glowColor)
                .frame(width: 150, height: 150)
                .blur(radius: 36)
                .offset(x: 48, y: -60)

            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                HStack(spacing: HoloSpacing.md) {
                    HoloPlusEmblem(size: 54, showsShine: true)

                    Text("Holo Plus")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(HoloPlusTheme.wordmarkGradient)

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        context == .membershipCenter
                            ? "解锁全部 AI 能力，把生活记录得更完整"
                            : context.title
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(HoloPlusTheme.accentText)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("2 倍 AI 额度 · 5 分钟语音 · 全部小组件")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(HoloPlusTheme.subtleText)
                }
            }
            .padding(20)
        }
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(HoloPlusTheme.strokeColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .shadow(color: Color.black.opacity(0.1), radius: 14, x: 0, y: 8)
    }

    // MARK: - 权益速览

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 0) {
            benefitComparisonRow(icon: "message.badge.waveform", name: "HoloAI", free: "15/天", plus: "30/天")
            CardDivider()
            benefitComparisonRow(icon: "brain.head.profile", name: "深度洞察", free: "2/天", plus: "10/天")
            CardDivider()
            benefitComparisonRow(icon: "waveform", name: "语音识别", free: "20/天", plus: "50/天")
            CardDivider()
            benefitComparisonRow(icon: "timer", name: "语音时长", free: "60 秒", plus: "5 分钟")
            CardDivider()
            benefitComparisonRow(icon: "sparkles.rectangle.stack", name: "智能记账+任务", free: "20/天", plus: "50/天")
            CardDivider()
            benefitComparisonRow(icon: "rectangle.stack.badge.plus", name: "4 类桌面小组件", free: nil, plus: "解锁")
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    /// 付费墙简版对比行：免费值 → Plus 值，Plus 高亮。
    private func benefitComparisonRow(
        icon: String,
        name: String,
        free: String?,
        plus: String
    ) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            // 裸线条图标，无圆形底
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary.opacity(0.8))
                .frame(width: 20)

            Text(name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let free {
                Text(free)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .strikethrough(true, color: .holoTextSecondary.opacity(0.35))
            } else {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary.opacity(0.35))
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.holoTextSecondary.opacity(0.4))

            Text(plus)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.holoPrimary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 13)
    }

    private var comparisonEntry: some View {
        Button {
            isComparisonPresented = true
        } label: {
            HStack(spacing: HoloSpacing.xs) {
                Text("查看完整权益对比")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HoloSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 方案选择

    private var yearlyProduct: Product? {
        subscriptionService.products.first {
            $0.id == HoloSubscriptionProduct.plusYearly.rawValue
        }
    }

    private var monthlyProduct: Product? {
        subscriptionService.products.first {
            $0.id == HoloSubscriptionProduct.plusMonthly.rawValue
        }
    }

    private var selectedProduct: Product? {
        subscriptionService.products.first { $0.id == selectedProductId }
    }

    /// 年订相对月订的省钱百分比（由真实商品价格推导，算不出则不展示）
    private var savingsPercent: Int? {
        guard let yearly = yearlyProduct,
              let monthly = monthlyProduct,
              monthly.price > 0,
              yearly.price > 0 else { return nil }

        let ratio = 1 - (yearly.price / 12) / monthly.price
        let percent = Int(NSDecimalNumber(
            decimal: ratio * 100
        ).doubleValue.rounded())
        return percent > 0 ? percent : nil
    }

    @ViewBuilder
    private var planSection: some View {
        if subscriptionService.isLoadingProducts {
            ProgressView("正在读取会员方案…")
                .frame(maxWidth: .infinity, minHeight: 88)
        } else if !subscriptionService.products.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("选择订阅方案")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                ForEach(subscriptionService.products, id: \.id) { product in
                    planCard(planData(from: product), isSelected: product.id == selectedProductId)
                }
            }
        } else if showsSamplePlans {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("选择订阅方案")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                ForEach(samplePlans, id: \.id) { plan in
                    planCard(plan, isSelected: plan.id == samplePlans[0].id)
                }
            }
        } else {
            VStack(spacing: HoloSpacing.sm) {
                Text(entitlementState.lastErrorMessage ?? "暂时无法读取会员方案")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Button("重新加载") {
                    Task { await subscriptionService.loadProducts() }
                }
                .font(.holoBody)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        }
    }

    // MARK: - 方案卡数据

    /// 方案卡的展示数据。与 StoreKit 商品解耦：线上从 Product 映射；
    /// DEBUG 样例模式用 HoloPlus.storekit 配置的真实价格本地渲染（模拟器独立启动读不到商品）。
    private struct PlanCardData {
        let id: String
        let name: String
        let priceText: String
        let periodText: String
        let monthlyEquivalentText: String?
        let savingsBadgeText: String?
    }

    /// 仅 DEBUG 构建可通过启动环境变量开启，Release 恒为 false
    private var showsSamplePlans: Bool {
        #if DEBUG
        subscriptionService.products.isEmpty
            && ProcessInfo.processInfo.environment["HOLO_DEBUG_SAMPLE_PLANS"] == "1"
        #else
        false
        #endif
    }

    /// 价格与 App Store Connect 当前配置一致（月 ¥12 / 年 ¥128）
    private var samplePlans: [PlanCardData] {
        [
            PlanCardData(
                id: "sample.yearly",
                name: "年订阅",
                priceText: "¥128.00",
                periodText: "/年",
                monthlyEquivalentText: "折合 ¥10.67/月",
                savingsBadgeText: "立省 11%"
            ),
            PlanCardData(
                id: "sample.monthly",
                name: "月订阅",
                priceText: "¥12.00",
                periodText: "/月",
                monthlyEquivalentText: nil,
                savingsBadgeText: nil
            )
        ]
    }

    private func planData(from product: Product) -> PlanCardData {
        let isYearly = product.id == HoloSubscriptionProduct.plusYearly.rawValue

        return PlanCardData(
            id: product.id,
            name: isYearly ? "年订阅" : "月订阅",
            priceText: product.displayPrice,
            periodText: isYearly ? "/年" : "/月",
            monthlyEquivalentText: isYearly
                ? "折合 \((product.price / 12).formatted(product.priceFormatStyle))/月"
                : nil,
            savingsBadgeText: isYearly ? savingsPercent.map { "立省 \($0)%" } : nil
        )
    }

    private func planCard(_ plan: PlanCardData, isSelected: Bool) -> some View {
        Button {
            withAnimation(HoloAnimation.snappy) { selectedProductId = plan.id }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: HoloSpacing.sm) {
                        Text(plan.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)

                        if let savings = plan.savingsBadgeText {
                            Text(savings)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(HoloPlusTheme.ctaGradient)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(plan.priceText)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.holoTextPrimary)

                        Text(plan.periodText)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }

                    if let monthly = plan.monthlyEquivalentText {
                        Text(monthly)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary.opacity(0.4))
            }
            .padding(16)
            .background(isSelected ? HoloPlusTheme.planSelectedTint : Color.holoCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .stroke(
                        isSelected ? Color.holoPrimary : Color.holoBorder.opacity(0.6),
                        lineWidth: isSelected ? 1.8 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(subscriptionService.isPurchasing)
        .accessibilityLabel("\(plan.name) \(plan.priceText)\(plan.periodText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 购买行动区

    @ViewBuilder
    private var purchaseSection: some View {
        if let product = selectedProduct {
            purchaseButton(
                title: ctaTitle(for: product),
                subline: isTrialEligible(product)
                    ? "试用结束后自动按所选方案续订，可随时取消"
                    : "订阅自动续订，可随时在系统设置中关闭",
                showsProgress: subscriptionService.isPurchasing
            ) {
                Task { await subscriptionService.purchase(product) }
            }

            // 购买流程的状态反馈（等待家长审批/已扣款同步中/同步失败）在此透出：
            // 此前 lastErrorMessage 只在商品列表为空时渲染，付费用户点了购买没有任何可见回音
            if let message = entitlementState.lastErrorMessage {
                Text(message)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
            }
        } else if showsSamplePlans {
            purchaseButton(
                title: "立即开通 · ¥128.00/年",
                subline: "订阅自动续订，可随时在系统设置中关闭"
            ) {}
        }
    }

    private func purchaseButton(
        title: String,
        subline: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            Button(action: action) {
                HStack(spacing: HoloSpacing.sm) {
                    if showsProgress {
                        ProgressView()
                            .tint(.white)
                    }

                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(HoloPlusTheme.ctaGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.holoPrimary.opacity(0.32), radius: 14, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(subscriptionService.isPurchasing)

            Text(subline)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func ctaTitle(for product: Product) -> String {
        if isTrialEligible(product), let offer = product.subscription?.introductoryOffer {
            return "开始 \(offer.period.value) \(periodUnitLabel(offer.period.unit))免费试用"
        }
        return "立即开通 · \(product.displayPrice)\(billingPeriodLabel(for: product))"
    }

    private func isTrialEligible(_ product: Product) -> Bool {
        product.subscription?.introductoryOffer != nil
            && trialEligibility[product.id] == true
    }

    private func periodUnitLabel(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day: return "天"
        case .week: return "周"
        case .month: return "个月"
        case .year: return "年"
        @unknown default: return "天"
        }
    }

    /// 订阅周期标签（App Store 3.1.2：账单金额旁需清晰标注周期）
    private func billingPeriodLabel(for product: Product) -> String {
        switch product.id {
        case HoloSubscriptionProduct.plusYearly.rawValue: return "/年"
        case HoloSubscriptionProduct.plusMonthly.rawValue: return "/月"
        default: return ""
        }
    }

    /// 拉取各商品的 introductory offer 资格，避免对无资格用户误报「免费试用」
    private func refreshTrialEligibility() async {
        for product in subscriptionService.products {
            guard let subscription = product.subscription else { continue }
            trialEligibility[product.id] = await subscription.isEligibleForIntroOffer
        }
    }

    // MARK: - 合规披露

    /// 订阅自动续费说明（App Store 3.1.2 订阅页必备披露）
    private var subscriptionDisclosure: some View {
        Text("订阅会自动续费，除非在当前订阅期结束前至少 24 小时关闭自动续订。续订将在到期前 24 小时内按对应方案扣款。可在「系统设置 › Apple ID › 订阅」中管理或取消。")
            .font(.system(size: 11))
            .foregroundColor(.holoTextSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restoreButton: some View {
        Button("恢复购买") {
            Task { await subscriptionService.restorePurchases() }
        }
        .font(.holoCaption)
        .foregroundColor(.holoTextSecondary)
        .frame(maxWidth: .infinity)
    }

    private var legalLinks: some View {
        HStack(spacing: HoloSpacing.sm) {
            Button("隐私政策") {
                guard let url = URL(string: "https://www.holoapp.cn/privacy") else {
                    return
                }
                openURL(url)
            }

            Text("·")

            Button("订阅条款") {
                guard let url = URL(
                    string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
                ) else {
                    return
                }
                openURL(url)
            }

            Text("·")

            Button("管理订阅") {
                guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else {
                    return
                }
                openURL(url)
            }
        }
        .font(.holoCaption)
        .foregroundColor(.holoTextSecondary)
        .frame(maxWidth: .infinity)
    }
}
