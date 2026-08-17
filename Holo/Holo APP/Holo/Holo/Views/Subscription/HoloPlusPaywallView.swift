//
//  HoloPlusPaywallView.swift
//  Holo
//
//  Holo Plus 统一付费墙。
//

import StoreKit
import SwiftUI

struct HoloPlusPaywallView: View {
    let context: HoloPlusGateContext

    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @ObservedObject private var subscriptionService = HoloSubscriptionService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isComparisonPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    header
                    benefits
                    comparisonEntry
                    productSection
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
            }
            .sheet(isPresented: $isComparisonPresented) {
                HoloPlusComparisonView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HoloPlusEmblem(size: 64)

            Text(context.title)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            Text("更高的 HoloAI、语音和记忆洞察额度，适合每天持续记录和整理生活。")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

    @ViewBuilder
    private var productSection: some View {
        if subscriptionService.isLoadingProducts {
            ProgressView("正在读取会员方案…")
                .frame(maxWidth: .infinity, minHeight: 88)
        } else if subscriptionService.products.isEmpty {
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
        } else {
            VStack(spacing: HoloSpacing.sm) {
                ForEach(subscriptionService.products, id: \.id) { product in
                    productButton(product)
                }
            }
        }
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            Task { await subscriptionService.purchase(product) }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    HStack(spacing: HoloSpacing.xs) {
                        Text(product.displayPrice)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.holoTextPrimary)

                        Text(billingPeriodLabel(for: product))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        if product.id == HoloSubscriptionProduct.plusYearly.rawValue {
                            Text("推荐")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.holoPrimary)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding()
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
        .disabled(subscriptionService.isPurchasing)
    }

    /// 订阅周期标签（App Store 3.1.2：账单金额旁需清晰标注周期）
    private func billingPeriodLabel(for product: Product) -> String {
        switch product.id {
        case HoloSubscriptionProduct.plusYearly.rawValue: return "/年"
        case HoloSubscriptionProduct.plusMonthly.rawValue: return "/月"
        default: return ""
        }
    }

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
