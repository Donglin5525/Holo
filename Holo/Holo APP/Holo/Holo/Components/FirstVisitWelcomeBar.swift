//
//  FirstVisitWelcomeBar.swift
//  Holo
//
//  页面首访欢迎条：第一次进入某页面时顶部出现的一条「这是什么页 + 第一步做什么」提示。
//  点 × 关闭即落盘（OnboardingProgressStore），不再重复出现。
//  样式与 ScheduleOnboardingBar 一脉相承（图标 + 两行文案 + 关闭按钮的卡片条）。
//

import SwiftUI

struct FirstVisitWelcomeBar: View {

    let icon: String
    let iconColor: Color
    let title: String
    let message: String

    /// OnboardingProgressStore 中的落盘 key
    private let seenKey: String

    /// 初始可见性：进入时读一次落盘（关闭后不再出现，无需监听外部变化）
    @State private var visible: Bool

    init(
        icon: String,
        iconColor: Color = .holoPrimary,
        title: String,
        message: String,
        seenKey: String
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.message = message
        self.seenKey = seenKey
        _visible = State(initialValue: !OnboardingProgressStore.hasSeen(seenKey))
    }

    var body: some View {
        if visible {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(iconColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    OnboardingProgressStore.markSeen(seenKey)
                    withAnimation(.easeOut(duration: 0.2)) {
                        visible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭引导")
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 10)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        FirstVisitWelcomeBar(
            icon: "book.fill",
            title: "欢迎来到记忆长廊",
            message: "你的每条记录都会自动汇到这里，按日、周、月回看生活。",
            seenKey: "preview.welcome.1"
        )
        FirstVisitWelcomeBar(
            icon: "wallet.pass",
            iconColor: .holoSuccess,
            title: "这是你的财务中心",
            message: "账本记流水，账户管资产，统计看趋势。",
            seenKey: "preview.welcome.2"
        )
    }
    .padding()
    .background(Color.holoBackground)
}
