//
//  HoloPlusPaywallView.swift
//  Holo
//
//  Holo Plus 统一付费墙（2026-11-26 编辑感重构）。
//
//  结构与原则：
//  - 纸底无卡 + 衬线主标题 + 一页一橙（主焦点仅留在底部主按钮与选中方案描边）
//  - 场景化动态置顶：按触发来源把用户刚被拦的能力放在第一条，其余从统一核心卖点池去重拼装
//  - 吸底决策区：左右并排双卡（年订默认选中 + 立省徽章）+ 主购买按钮，打开第一眼即可闭环
//  - 完整 App Store 3.1.2 自动续费披露置于滚动区底部，不挤占吸底高度且 100% 合规
//  - 无障碍大字体下自动取消吸底、改为整页滚动，避免小屏视口死锁
//  - 价格与试用资格一律实时取自 StoreKit 商品，不硬编码金额
//

import StoreKit
import SwiftUI

struct HoloPlusPaywallView: View {
    let context: HoloPlusGateContext

    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @ObservedObject private var subscriptionService = HoloSubscriptionService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedProductId: String?
    @State private var isComparisonPresented = false
    /// 各商品的免费试用资格（introductory offer），key 为 productId
    @State private var trialEligibility: [String: Bool] = [:]

    private var presentation: HoloPlusPaywallPresentation {
        HoloPlusPaywallPresentation.make(for: context)
    }

    var body: some View {
        NavigationStack {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // 无障碍大字体：取消固定吸底，整页随动滚动避免视口锁死
                    ScrollView {
                        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                            scrollableContent
                            HoloHairlineDivider()
                            decisionDockContent
                        }
                        .padding(.horizontal, HoloSpacing.page)
                        .padding(.top, HoloSpacing.sm)
                        .padding(.bottom, HoloSpacing.xl)
                    }
                } else {
                    VStack(spacing: 0) {
                        ScrollView(showsIndicators: false) {
                            scrollableContent
                                .padding(.horizontal, HoloSpacing.page)
                                .padding(.top, HoloSpacing.xs)
                                .padding(.bottom, HoloSpacing.lg)
                        }

                        decisionDock
                    }
                }
            }
            .background(Color.holoToolBackground.ignoresSafeArea())
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.holoToolAction)
                            .frame(width: 6, height: 6)
                        Text("HOLO PLUS")
                            .font(.system(size: 11.5, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
                ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button("关闭") {
                        HoloPlusActionCoordinator.shared.dismissPaywall()
                        dismiss()
                    }
                    .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
            .onAppear {
                HoloProductAnalytics.shared.track(.paywallViewed, ["context": String(describing: context)])
            }
            .task {
                await subscriptionService.loadProducts()
                if selectedProductId == nil {
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

    // MARK: - 上半区：场景化价值 + 4 条质变卖点 + 合规披露

    private var scrollableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presentation.kicker)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.holoToolAction)
                .padding(.bottom, 8)

            Text(presentation.headline)
                .font(.holoEditorialSerif(size: 24, bold: true))
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            HoloHairlineDivider()
                .padding(.vertical, 14)

            benefitList

            comparisonEntry
                .padding(.top, 8)

            Text("日常记账、待办、想法与习惯打卡永久免费，你的个人记录始终归你所有。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.holoToolTextSecondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            subscriptionDisclosure
                .padding(.top, 14)
        }
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.items.enumerated()), id: \.element.id) { index, item in
                benefitRow(index: index + 1, item: item)

                if !item.isFeatured && index < presentation.items.count - 1 {
                    HoloHairlineDivider()
                }
            }
        }
    }

    private func benefitRow(index: Int, item: HoloPlusPaywallBenefitItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(String(format: "%02d", index))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.isFeatured ? Color.holoToolAction : Color.holoToolTextSecondary.opacity(0.75))
                .padding(.top, 2)
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.holoToolAction)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.holoToolAction.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                Text(item.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, item.isFeatured ? 11 : 10)
        .padding(.horizontal, item.isFeatured ? 11 : 0)
        .background(
            item.isFeatured
                ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.holoToolAction.opacity(0.07))
                : nil
        )
        .padding(.bottom, item.isFeatured ? 4 : 0)
    }

    private var comparisonEntry: some View {
        Button {
            isComparisonPresented = true
        } label: {
            HStack {
                Text("查看全部 \(HoloPlusBenefits.all.count) 项权益对比")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .holoIconSize(.xs, weight: .semibold)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 完整自动续费披露（App Store 3.1.2 必备，放在滚动区末尾不占吸底高度）
    private var subscriptionDisclosure: some View {
        Text("订阅会自动续费，除非在当前订阅期结束前至少 24 小时关闭自动续订。续订将在到期前 24 小时内按对应方案扣款。可在「系统设置 › Apple ID › 订阅」中管理或取消。")
            .font(.system(size: 11))
            .foregroundStyle(Color.holoToolTextSecondary.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 吸底决策区

    private var decisionDock: some View {
        VStack(spacing: 0) {
            HoloHairlineDivider()
            decisionDockContent
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, 12)
                .padding(.bottom, 10)
        }
        .background(Color.holoToolBackground)
    }

    private var decisionDockContent: some View {
        VStack(spacing: 10) {
            planSection
            purchaseSection
            legalRow
        }
    }

    // MARK: - 方案选择（左右并排双卡）

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

    private var orderedProducts: [Product] {
        // 年订阅固定放左侧推荐位，月订阅放右侧
        var list: [Product] = []
        if let yearly = yearlyProduct { list.append(yearly) }
        if let monthly = monthlyProduct { list.append(monthly) }
        for product in subscriptionService.products where !list.contains(where: { $0.id == product.id }) {
            list.append(product)
        }
        return list
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
        let percent = Int(NSDecimalNumber(decimal: ratio * 100).doubleValue.rounded())
        return percent > 0 ? percent : nil
    }

    @ViewBuilder
    private var planSection: some View {
        if subscriptionService.isLoadingProducts {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在获取订阅方案…")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 82)
        } else if !orderedProducts.isEmpty {
            HStack(spacing: 10) {
                ForEach(orderedProducts, id: \.id) { product in
                    planCard(planData(from: product), isSelected: product.id == selectedProductId)
                }
            }
        } else if showsSamplePlans {
            HStack(spacing: 10) {
                ForEach(samplePlans, id: \.id) { plan in
                    let isSelected = (selectedProductId ?? samplePlans[0].id) == plan.id
                    planCard(plan, isSelected: isSelected)
                }
            }
        } else {
            // 最惨异常态：温和告知 + 重试，不暴露开发术语
            VStack(spacing: 8) {
                Text("暂时无法获取订阅方案")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)

                Text("请检查网络连接后重试，或直接恢复已有订阅")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .multilineTextAlignment(.center)

                Button("重新加载") {
                    Task { await subscriptionService.loadProducts() }
                }
                .buttonStyle(.holoSecondary)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 方案卡数据

    private struct PlanCardData {
        let id: String
        let name: String
        let priceText: String
        let periodText: String
        /// 单行副文（年卡固定放「折合 ¥X/月」，不与试用文字混排避免小屏截断）
        let metaText: String
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

    /// 样例价格对齐 B 方案（月 ¥12 / 年 ¥98，省 32%）
    private var samplePlans: [PlanCardData] {
        [
            PlanCardData(
                id: "sample.yearly",
                name: String(localized: "年订阅"),
                priceText: "¥98",
                periodText: String(localized: "/年"),
                metaText: String(localized: "折合 ¥8.2/月"),
                savingsBadgeText: String(localized: "省 32%")
            ),
            PlanCardData(
                id: "sample.monthly",
                name: String(localized: "月订阅"),
                priceText: "¥12",
                periodText: String(localized: "/月"),
                metaText: String(localized: "按月灵活续订"),
                savingsBadgeText: nil
            )
        ]
    }

    private func planData(from product: Product) -> PlanCardData {
        let isYearly = product.id == HoloSubscriptionProduct.plusYearly.rawValue
        let monthlyEquivalent = (product.price / 12).formatted(product.priceFormatStyle)

        return PlanCardData(
            id: product.id,
            name: isYearly ? String(localized: "年订阅") : String(localized: "月订阅"),
            priceText: product.displayPrice,
            periodText: isYearly ? String(localized: "/年") : String(localized: "/月"),
            metaText: isYearly
                ? String(localized: "折合 \(monthlyEquivalent)/月")
                : String(localized: "按月灵活续订"),
            savingsBadgeText: isYearly ? savingsPercent.map { String(localized: "省 \($0)%") } : nil
        )
    }

    private func planCard(_ plan: PlanCardData, isSelected: Bool) -> some View {
        Button {
            withAnimation(HoloAnimation.snappy) { selectedProductId = plan.id }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(plan.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    if let savings = plan.savingsBadgeText {
                        Text(savings)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.holoToolOnAction)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.holoToolAction, in: Capsule())
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(plan.priceText)
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(plan.periodText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                }

                Text(plan.metaText)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.holoToolAction : Color.holoToolTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.holoToolAction.opacity(0.07) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.holoToolAction : Color.holoToolBorder,
                        lineWidth: isSelected ? 1.5 : 0.9
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(subscriptionService.isPurchasing || subscriptionService.isRestoring)
        .accessibilityLabel("\(plan.name) \(plan.priceText)\(plan.periodText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 购买行动区

    @ViewBuilder
    private var purchaseSection: some View {
        if let product = selectedProduct {
            purchaseButton(
                title: ctaTitle(for: product),
                subline: ctaSubline(for: product),
                showsProgress: subscriptionService.isPurchasing
            ) {
                Task {
                    HoloProductAnalytics.shared.track(
                        .paywallPurchaseTapped,
                        ["context": String(describing: context), "plan": product.id]
                    )
                    await subscriptionService.purchase(product)
                }
            }

            if let message = entitlementState.lastErrorMessage {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }
        } else if showsSamplePlans {
            let isYearly = (selectedProductId ?? "sample.yearly") == "sample.yearly"
            purchaseButton(
                title: isYearly
                    ? String(localized: "开启 7 天免费试用")
                    : String(localized: "立即开通 · ¥12/月"),
                subline: isYearly
                    ? String(localized: "试用结束后按 ¥98/年 自动续订，随时可取消")
                    : String(localized: "自动续订，可随时在系统设置中取消")
            ) {}
        }
    }

    private func purchaseButton(
        title: String,
        subline: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: HoloSpacing.sm) {
                    if showsProgress {
                        ProgressView()
                            .tint(Color.holoToolOnAction)
                    }
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolOnAction)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.holoToolAction, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(subscriptionService.isPurchasing || subscriptionService.isRestoring)

            Text(subline)
                .font(.system(size: 11))
                .foregroundStyle(Color.holoToolTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ctaTitle(for product: Product) -> String {
        if isTrialEligible(product), let offer = product.subscription?.introductoryOffer {
            let trialLabel = trialDurationLabel(offer.period)
            return String(localized: "开启 \(trialLabel)免费试用")
        }
        return String(localized: "立即开通 · \(product.displayPrice)\(billingPeriodLabel(for: product))")
    }

    private func ctaSubline(for product: Product) -> String {
        if isTrialEligible(product) {
            return String(localized: "试用结束后按 \(product.displayPrice)\(billingPeriodLabel(for: product)) 自动续订，随时可取消")
        }
        return String(localized: "自动续订，可随时在系统设置中取消")
    }

    private func isTrialEligible(_ product: Product) -> Bool {
        product.subscription?.introductoryOffer != nil
            && trialEligibility[product.id] == true
    }

    private func trialDurationLabel(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day:
            return String(localized: "\(period.value) 天")
        case .week:
            return period.value == 1
                ? String(localized: "7 天")
                : String(localized: "\(period.value) 周")
        case .month:
            return String(localized: "\(period.value) 个月")
        case .year:
            return String(localized: "\(period.value) 年")
        @unknown default:
            return String(localized: "\(period.value) 天")
        }
    }

    /// 订阅周期标签（App Store 3.1.2：账单金额旁需清晰标注周期）
    private func billingPeriodLabel(for product: Product) -> String {
        switch product.id {
        case HoloSubscriptionProduct.plusYearly.rawValue: return String(localized: "/年")
        case HoloSubscriptionProduct.plusMonthly.rawValue: return String(localized: "/月")
        default: return ""
        }
    }

    private func refreshTrialEligibility() async {
        for product in subscriptionService.products {
            guard let subscription = product.subscription else { continue }
            trialEligibility[product.id] = await subscription.isEligibleForIntroOffer
        }
    }

    // MARK: - 底部轻链接（恢复购买 + 合规链接）

    private var legalRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await subscriptionService.restorePurchases() }
            } label: {
                if subscriptionService.isRestoring {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Text("恢复购买")
                }
            }
            .disabled(subscriptionService.isPurchasing || subscriptionService.isRestoring)

            Text("·")

            Button("隐私政策") {
                guard let url = URL(string: "https://www.holoapp.cn/privacy") else { return }
                openURL(url)
            }

            Text("·")

            Button("订阅条款") {
                guard let url = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") else { return }
                openURL(url)
            }

            Text("·")

            Button("管理订阅") {
                guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
                openURL(url)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

// MARK: - 场景化文案与单一核心卖点池

struct HoloPlusPaywallBenefitItem: Identifiable {
    enum BenefitAxis: Hashable {
        case discovery
        case deepAnalysis
        case voiceAndAI
        case finance
        case widgetsAndHabits
    }

    let id: String
    let axis: BenefitAxis
    let title: String
    let detail: String
    let badge: String?
    let isFeatured: Bool
}

struct HoloPlusPaywallPresentation {
    let kicker: String
    let headline: String
    let subtitle: String
    let items: [HoloPlusPaywallBenefitItem]

    /// 统一核心卖点池（单一真源，避免 18 个拦截场景各自硬编码漂移）
    private static let corePool: [HoloPlusPaywallBenefitItem] = [
        .init(
            id: "core.discovery",
            axis: .discovery,
            title: String(localized: "每周最多 5 件「一个发现」"),
            detail: String(localized: "免费每周 1 件；Plus 几乎每天帮你留意生活里值得说的变化"),
            badge: nil,
            isFeatured: false
        ),
        .init(
            id: "core.deepAnalysis",
            axis: .deepAnalysis,
            title: String(localized: "深度洞察 10 次/天 · 5 分钟长语音"),
            detail: String(localized: "跨模块深度复盘更从容，长段口述与记忆洞察刷新不设卡"),
            badge: nil,
            isFeatured: false
        ),
        .init(
            id: "core.finance",
            axis: .finance,
            title: String(localized: "财务进阶管理"),
            detail: String(localized: "解锁预算、分期、自定义账单周期与不限张数信用卡提醒"),
            badge: nil,
            isFeatured: false
        ),
        .init(
            id: "core.widgetsHabits",
            axis: .widgetsAndHabits,
            title: String(localized: "4 类桌面小组件与习惯保护"),
            detail: String(localized: "桌面一键记录与回看，支持习惯暂停与无限次补签"),
            badge: nil,
            isFeatured: false
        ),
    ]

    static func make(for context: HoloPlusGateContext) -> HoloPlusPaywallPresentation {
        if context == .membershipCenter {
            return HoloPlusPaywallPresentation(
                kicker: "HOLO PLUS",
                headline: context.title,
                subtitle: String(localized: "更主动的 AI 洞察、5 分钟长语音，以及财务与习惯的进阶工具。"),
                items: corePool
            )
        }

        let (kicker, subtitle, featured) = featuredSpec(for: context)
        let rest = corePool.filter { $0.axis != featured.axis }.prefix(3)
        return HoloPlusPaywallPresentation(
            kicker: kicker,
            headline: context.title,
            subtitle: subtitle,
            items: [featured] + rest
        )
    }

    private static func featuredSpec(
        for context: HoloPlusGateContext
    ) -> (kicker: String, subtitle: String, featured: HoloPlusPaywallBenefitItem) {
        let unlockTag = String(localized: "当前解锁")
        switch context {
        case .membershipCenter:
            return ("HOLO PLUS", "", corePool[0])

        case .deepAnalysis:
            return (
                String(localized: "深度洞察 · 今日 1 次已用完"),
                String(localized: "免费版每天可做 1 次深度洞察；升级 Plus 提升至 10 次/天，跨模块复盘与追问不再中断。"),
                .init(
                    id: "feat.deepAnalysis",
                    axis: .deepAnalysis,
                    title: String(localized: "深度洞察：每天 1 次 → 10 次"),
                    detail: String(localized: "支持多轮跨模块追问、消费与习惯归因分析，升级后立即解锁今日额度"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .holoAI:
            return (
                String(localized: "HOLOAI 对话 · 今日 15 次已用完"),
                String(localized: "免费版每天 15 次对话（含目标规划）已用完；升级后每日额度翻倍，随时接着聊。"),
                .init(
                    id: "feat.holoAI",
                    axis: .voiceAndAI,
                    title: String(localized: "HoloAI 对话：每天 15 次 → 30 次"),
                    detail: String(localized: "日常提问、回顾检索与目标规划额度翻倍，升级后立即恢复对话"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .lifePlan:
            return (
                String(localized: "每周生活计划 · 本周已用完"),
                String(localized: "免费版每周可生成 1 次生活计划；升级后每周 2 次，节奏有变随时重排。"),
                .init(
                    id: "feat.lifePlan",
                    axis: .deepAnalysis,
                    title: String(localized: "每周生活计划：每周 1 次 → 2 次"),
                    detail: String(localized: "结合本周待办、预算与习惯动态调整计划，同时解锁深度洞察 10 次/天"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .discoveryInsightWeekly:
            return (
                String(localized: "一个发现 · 周额度已用完"),
                String(localized: "本周免费 1 件发现已送达；升级后 Holo 几乎每天都会帮你留意值得说的事。"),
                .init(
                    id: "feat.discovery",
                    axis: .discovery,
                    title: String(localized: "一个发现：每周 1 件 → 最多 5 件"),
                    detail: String(localized: "有值得说的就及时告诉你；想先看某件事，点一下即可优先查看"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .memoryGallery:
            return (
                String(localized: "记忆洞察 · 本周已刷新"),
                String(localized: "免费版每周可刷新 1 次记忆洞察；升级后每天都能基于最新记录更新。"),
                .init(
                    id: "feat.memory",
                    axis: .deepAnalysis,
                    title: String(localized: "记忆洞察刷新：每周 1 次 → 每天 1 次"),
                    detail: String(localized: "同步提升深度洞察至 10 次/天，随时回看最新生活脉络"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .asrDuration:
            return (
                String(localized: "语音录制已达 60 秒上限"),
                String(localized: "升级后单条语音最长支持 5 分钟，适合睡前复盘、散步记录长想法。"),
                .init(
                    id: "feat.asrDuration",
                    axis: .voiceAndAI,
                    title: String(localized: "单条语音时长：60 秒 → 5 分钟"),
                    detail: String(localized: "识别次数同步提升至 50 次/天，长段口述自动整理成条理记录"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .asrQuota:
            return (
                String(localized: "语音识别 · 今日额度已用完"),
                String(localized: "免费版每天可识别 20 次语音；升级后提升至 50 次/天且单条最长 5 分钟。"),
                .init(
                    id: "feat.asrQuota",
                    axis: .voiceAndAI,
                    title: String(localized: "语音识别：20 次/天 → 50 次/天"),
                    detail: String(localized: "单条录音时长同步延长至 5 分钟，口述记账与写想法更顺手"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .billImportAI:
            return (
                String(localized: "账单智能导入"),
                String(localized: "一键导入并由 AI 自动分类历史账单，省去逐笔手动录入的麻烦。"),
                .init(
                    id: "feat.billImport",
                    axis: .finance,
                    title: String(localized: "账单智能导入 · 财务进阶全解锁"),
                    detail: String(localized: "支持 AI 解析导入账单，同时解锁预算、分期与自定义账单周期"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .taskSplit:
            return (
                String(localized: "AI 任务拆解 · 本月 5 次已用完"),
                String(localized: "免费版每月 5 次任务拆解已用完；升级后提升至 100 次/月，大任务轻松落地。"),
                .init(
                    id: "feat.taskSplit",
                    axis: .voiceAndAI,
                    title: String(localized: "AI 任务拆解：5 次/月 → 100 次/月"),
                    detail: String(localized: "复杂事项一键拆成清晰子步骤，智能任务解析同步升至 50 次/天"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .naturalLanguageFinance, .naturalLanguageTask:
            return (
                String(localized: "智能解析 · 今日额度已用完"),
                String(localized: "免费版每天 20 次自然语言解析已用完；升级后提升至 50 次/天。"),
                .init(
                    id: "feat.nlParse",
                    axis: .voiceAndAI,
                    title: String(localized: "智能记账与任务：20 次/天 → 50 次/天"),
                    detail: String(localized: "一句话记账、建待办额度大幅提升，开通后立即可用"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .budget, .financeInstallment, .billingCycle, .creditCardReminder, .subscriptionReminder:
            return (
                String(localized: "财务进阶管理"),
                String(localized: "日常记账永久免费；升级 Plus 解锁全套进阶财务管理，开通后直接回到刚才的设置。"),
                .init(
                    id: "feat.finance",
                    axis: .finance,
                    title: String(localized: "预算、分期、周期与不限张数信用卡提醒"),
                    detail: String(localized: "按月控预算、自动拆解分期、自定义统计周期，并突破免费 3 张卡提醒上限"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .desktopWidget:
            return (
                String(localized: "桌面小组件"),
                String(localized: "在手机桌面直接语音记录、查看财务概览与随手漫步历史想法。"),
                .init(
                    id: "feat.widget",
                    axis: .widgetsAndHabits,
                    title: String(localized: "解锁全部 4 类桌面小组件"),
                    detail: String(localized: "含语音启动、快捷控制台、财务概览与随机漫步，开通后立即生效"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )

        case .habitPause, .habitRetroactiveCheckIn:
            return (
                String(localized: "习惯连胜保护"),
                String(localized: "日常打卡永久免费；升级 Plus 解锁习惯暂停与无限次补签，护住长期积累。"),
                .init(
                    id: "feat.habit",
                    axis: .widgetsAndHabits,
                    title: String(localized: "习惯暂停 · 无限次补签"),
                    detail: String(localized: "生病或出行可安心暂停不断签，漏打随时补签，开通后自动续接刚才操作"),
                    badge: unlockTag,
                    isFeatured: true
                )
            )
        }
    }
}
