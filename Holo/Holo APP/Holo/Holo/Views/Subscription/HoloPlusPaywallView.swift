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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    header
                    benefits
                    productSection
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
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            benefitRow(icon: "message.badge.waveform", title: "HoloAI 30 次/天")
            benefitRow(icon: "waveform", title: "语音识别 50 次/天，单条最长 5 分钟")
            benefitRow(icon: "sparkles.rectangle.stack", title: "智能记账与任务解析 50 次/天")
            benefitRow(icon: "memories", title: "记忆长廊每日 AI 洞察刷新")
        }
        .padding()
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func benefitRow(icon: String, title: String) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .foregroundColor(.holoPrimary)
            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
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
                    HStack(spacing: HoloSpacing.xs) {
                        Text(product.displayName)
                            .font(.holoBody)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoTextPrimary)

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

                    Text(product.displayPrice)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
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
            Button("管理订阅") {
                guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else {
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
        }
        .font(.holoCaption)
        .foregroundColor(.holoTextSecondary)
        .frame(maxWidth: .infinity)
    }
}
