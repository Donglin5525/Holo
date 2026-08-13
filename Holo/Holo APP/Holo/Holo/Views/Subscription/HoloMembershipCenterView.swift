//
//  HoloMembershipCenterView.swift
//  Holo
//
//  会员状态、权益对比、额度与升级入口。
//  配色统一到品牌橙系（HoloPlusTheme）。
//

import SwiftUI

struct HoloMembershipCenterView: View {
    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @Environment(\.openURL) private var openURL

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                statusCard
                benefitComparisonSection
                footnote

                primaryAction
                quotaSection

                #if DEBUG
                developmentAcceptanceSection
                #endif
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

    // MARK: - 状态卡

    private var statusCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(HoloPlusTheme.darkGradient)

            Circle()
                .fill(HoloPlusTheme.glowColor)
                .frame(width: 140, height: 140)
                .blur(radius: 32)
                .offset(x: 42, y: -56)

            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                HStack(alignment: .top, spacing: HoloSpacing.md) {
                    HoloPlusEmblem(size: 56)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: HoloSpacing.xs) {
                            Text(entitlementState.isPlusActive ? "Holo Plus" : "免费版")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(HoloPlusTheme.accentText)

                            if entitlementState.isPlusActive {
                                Text("PLUS")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(HoloPlusTheme.badgeText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(HoloPlusTheme.badgeBg)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(
                            entitlementState.isPlusActive
                                ? "会员权益已生效"
                                : "升级后解锁更高每日额度"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(HoloPlusTheme.subtleText)

                        if entitlementState.isPlusActive, let expiresAt = entitlementState.expiresAt {
                            Text("到期/续费日期：\(Self.dateFormatter.string(from: expiresAt))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(HoloPlusTheme.subtleText)
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: HoloSpacing.sm) {
                    membershipMetric("HoloAI", entitlementState.isPlusActive ? "30/天" : "3/天")
                    membershipMetric("语音识别", entitlementState.isPlusActive ? "50/天" : "20/天")
                    membershipMetric("任务", entitlementState.isPlusActive ? "50/天" : "10/天")
                }
            }
            .padding(18)
        }
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(HoloPlusTheme.strokeColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
    }

    private func membershipMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(HoloPlusTheme.subtleText)

            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(HoloPlusTheme.accentText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.holoPrimary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - 权益对比

    private var benefitComparisonSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("完整权益对比")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            HoloPlusBenefitComparisonTable(
                currentTierHighlight: entitlementState.isPlusActive ? .plus : .free
            )
        }
    }

    // MARK: - 当前额度

    @ViewBuilder
    private var quotaSection: some View {
        if !entitlementState.quotas.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("当前使用情况")
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
                        .frame(minHeight: 28)
                    }
                }
            }
            .padding()
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        }
    }

    private var footnote: some View {
        Text("记账、待办、想法等本地功能，免费版与 Plus 版完全一致。")
            .font(.system(size: 12))
            .foregroundColor(.holoTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 主操作按钮

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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

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

            Text("这里会切换服务端真实权益与独立验收额度。\"跟随购买\"会恢复账号的真实购买状态，不会被验收数据覆盖。")
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
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
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
            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
        .disabled(entitlementState.isRefreshing)
    }
    #endif
}
