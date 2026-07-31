//
//  HoloMembershipCenterView.swift
//  Holo
//
//  会员状态、额度与升级入口。
//

import SwiftUI

struct HoloMembershipCenterView: View {
    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                statusCard
                quotaSection

                #if DEBUG
                developmentAcceptanceSection
                #endif

                primaryAction
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationTitle("Holo Plus")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await HoloSubscriptionService.shared.refreshStatus()
        }
    }

    private var statusCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#17131F"),
                            Color(hex: "#211329"),
                            Color(hex: "#2E1A22")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.holoPrimary.opacity(0.28))
                .frame(width: 140, height: 140)
                .blur(radius: 32)
                .offset(x: 42, y: -56)

            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                HStack(alignment: .top, spacing: HoloSpacing.md) {
                    HoloPlusEmblem(size: 60)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: HoloSpacing.xs) {
                            Text(entitlementState.isPlusActive ? "Holo Plus" : "免费版")
                                .font(.holoTitle)
                                .foregroundColor(Color(hex: "#FFF3D7"))

                            if entitlementState.isPlusActive {
                                Text("PLUS")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(hex: "#211329"))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: "#FFE4AE"))
                                    .clipShape(Capsule())
                            }
                        }

                        Text(
                            entitlementState.isPlusActive
                                ? "会员权益已生效"
                                : "升级后解锁更高每日额度"
                        )
                        .font(.holoBody)
                        .foregroundColor(Color(hex: "#F3DEC0").opacity(0.82))
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: HoloSpacing.sm) {
                    membershipMetric("HoloAI", entitlementState.isPlusActive ? "30/天" : "3/天")
                    membershipMetric("语音", entitlementState.isPlusActive ? "5分钟" : "60秒")
                    membershipMetric("任务", entitlementState.isPlusActive ? "50/天" : "10/天")
                }
            }
            .padding()
        }
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color(hex: "#FFE4AE").opacity(0.64), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func membershipMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(hex: "#F3DEC0").opacity(0.72))
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: "#FFF3D7"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("当前额度")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            ForEach(entitlementState.quotas.keys.sorted(), id: \.self) { key in
                if let quota = entitlementState.quotas[key] {
                    HStack {
                        Text(displayName(for: key))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                        Spacer()
                        Text("已用 \(quota.used) · 剩余 \(quota.remaining)")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var primaryAction: some View {
        Button {
            if entitlementState.isPlusActive {
                guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else {
                    return
                }
                openURL(url)
            } else {
                HoloPlusActionCoordinator.shared.requirePlus(context: .membershipCenter)
            }
        } label: {
            Text(entitlementState.isPlusActive ? "管理会员" : "升级 Holo Plus")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    #if DEBUG
    private var developmentAcceptanceSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("真机验收")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(entitlementState.source.acceptanceDescription)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            Text("这里会切换服务端真实权益与独立验收额度。“跟随购买”会恢复账号的真实购买状态，不会被验收数据覆盖。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: HoloSpacing.sm) {
                acceptanceButton("免费", mode: .free)
                acceptanceButton("Plus", mode: .plus)
                acceptanceButton("跟随购买", mode: .followPurchase)
            }

            if entitlementState.source == .acceptance {
                Button("重置当前验收额度") {
                    Task {
                        await HoloSubscriptionService.shared.resetDebugAcceptanceQuotas()
                    }
                }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
            }

            if let message = entitlementState.lastErrorMessage {
                Text(message)
                    .font(.holoCaption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func acceptanceButton(
        _ title: String,
        mode: HoloAcceptanceMode
    ) -> some View {
        Button(title) {
            Task {
                await HoloSubscriptionService.shared.setDebugAcceptanceMode(mode)
            }
        }
        .font(.holoCaption)
        .fontWeight(.semibold)
        .foregroundColor(mode == entitlementState.acceptanceMode ? .white : .holoPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(mode == entitlementState.acceptanceMode ? Color.holoPrimary : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .stroke(Color.holoPrimary.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        .disabled(entitlementState.isRefreshing)
    }
    #endif

    private func displayName(for key: String) -> String {
        switch key {
        case "chat": return "HoloAI"
        case "naturalLanguageFinance": return "智能记账"
        case "naturalLanguageTask": return "智能任务"
        case "asr": return "语音识别"
        case "memoryInsight": return "记忆洞察"
        default: return key
        }
    }
}
