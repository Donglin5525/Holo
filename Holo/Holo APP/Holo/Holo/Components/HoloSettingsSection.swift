//
//  HoloSettingsSection.swift
//  Holo
//
//  设置类页面统一卡片语言组件家族（2026-09-19 财务设置页重设计定稿）
//  卡片外观统一走 DesignSystem 的 .holoCard()（16pt 圆角 + 描边 + 轻投影），
//  图标底座统一 36pt 正圆 + 同色 12% 低透明底（深浅模式通用，同 CategoryIconBadge 做法）。
//  推广约定：设置类页面的「区块标题 + 卡片 + 行」一律用本家族组装，
//  禁止再手写 background/clipShape/shadow 三件套与散落的图标底座规格。
//

import SwiftUI

// MARK: - 区块（标题 + 标准卡片）

/// 设置页区块：可选标题 + 一张标准卡片，卡内放若干 HoloSettingsRow。
/// title 传 nil 即无标题区块（如危险区）。
struct HoloSettingsSection<Content: View>: View {
    var title: String?
    var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.sm)
            }

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.xs)
            .holoCard()
            .padding(.horizontal, HoloSpacing.lg)
        }
    }
}

// MARK: - 标准行

/// 设置页标准行：36pt 圆形图标底座 + 标题/副标题 + 尾随自定义视图。
/// 行本身不感知点击行为：NavigationLink / Button 的 label 用本行组装，
/// 点击语义留在调用方；行自带 8pt 垂直内边距。
struct HoloSettingsRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color
    let title: String
    var titleColor: Color
    var subtitle: String?
    let trailing: Trailing

    init(
        icon: String,
        iconColor: Color = .holoPrimary,
        title: String,
        titleColor: Color = .holoTextPrimary,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.titleColor = titleColor
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(iconColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer(minLength: HoloSpacing.sm)

            trailing
        }
        .padding(.vertical, HoloSpacing.sm)
    }
}

// MARK: - 尾随箭头

/// 设置行标准尾随箭头（规格唯一的 chevron，禁止各页散写）
struct HoloSettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.holoTextSecondary)
    }
}

// MARK: - 数量角标

/// 待办数量角标：品牌橙胶囊，≥100 显示 99+ 防无限变宽挤压标题
struct HoloSettingsBadge: View {
    var count: Int

    var body: some View {
        Text(count >= 100 ? "99+" : "\(count)")
            .font(.holoTinyLabel)
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, HoloSpacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
            .fixedSize()
    }
}

// MARK: - 卡内脚注

/// 卡内说明性脚注：与图标左缘对齐（不额外缩进），颜色用 placeholder 档
struct HoloSettingsFootnote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.holoLabel)
            .foregroundColor(.holoTextPlaceholder)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, HoloSpacing.xs)
    }
}

// MARK: - 卡内分隔线

/// 设置卡内分隔线：左缩进 60 = 卡内水平边距 16 + 图标底座 36 + 图标-文字间距 8
struct HoloSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 60)
    }
}
