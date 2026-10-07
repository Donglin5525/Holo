//
//  ChatCardView.swift
//  Holo
//
//  AI Chat 通用卡片容器
//  统一外壳：圆角、阴影、边框、交互状态
//

import SwiftUI

// MARK: - 通用卡片外壳

struct ChatCardView<Content: View>: View {

    let content: Content
    var onTap: (() -> Void)?
    let isDeleted: Bool

    init(isDeleted: Bool = false, onTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.isDeleted = isDeleted
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        if let onTap {
            Button {
                if !isDeleted { onTap() }
            } label: {
                cardBody
            }
            .buttonStyle(CardButtonStyle())
            .disabled(isDeleted)
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(HoloSpacing.md)
        .holoSurface()
        .opacity(isDeleted ? 0.5 : 1.0)
        .saturation(isDeleted ? 0 : 1)
    }
}

// MARK: - 卡片交互样式

/// 卡片按下效果：scale(0.97) + opacity(0.8)
typealias CardButtonStyle = HoloPressStyle

// MARK: - 卡片通用组件

/// 卡片头部行（图标 + 标题 + 可选徽章）
struct CardHeaderView: View {

    let icon: String
    let title: String
    var badge: CardBadge?
    var subtitle: String?
    var isDeleted: Bool = false

    init(icon: String, title: String, badge: CardBadge? = nil, subtitle: String? = nil, isDeleted: Bool = false) {
        self.icon = icon
        self.title = title
        self.badge = badge
        self.subtitle = subtitle
        self.isDeleted = isDeleted
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            categoryIconGlyph(icon, size: 16, color: .holoPrimary)
                .frame(width: 34, height: 34)
                .background(Color.holoPrimary.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .holoText(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.holoToolText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(isDeleted)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(2)
                        .strikethrough(isDeleted)
                }

                if let badge {
                    badge
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
    }
}

/// 卡片徽章
struct CardBadge: View {

    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// 卡片分隔线
struct CardDivider: View {

    var body: some View {
        Rectangle()
            .fill(Color.holoDivider.opacity(0.75))
            .frame(height: 0.5)
    }
}

/// 卡片底部行（时间 + 操作入口箭头）
struct CardFooterView: View {

    let timeText: String
    var isDeleted: Bool = false
    /// 是否渲染右侧箭头：箭头暗示「点击有去向」，纯展示卡片（无跳转入口）必须传 false
    var showsChevron: Bool = true

    var body: some View {
        HStack {
            Text(timeText)
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .strikethrough(isDeleted)

            Spacer()

            if isDeleted {
                Text("已删除")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.holoToolTextSecondary.opacity(0.12))
                    )
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoPrimary.opacity(0.78))
            }
        }
    }
}

// MARK: - HoloAI 阅读组件

struct HoloAIHeroMetric: View {
    let label: String
    let value: String
    var note: String?
    var tint: Color = .holoPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoToolTextSecondary)

            Text(value)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(tint)
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HoloAIFactItem: View {
    let kicker: String
    let bodyText: String
    var tint: Color = .holoPrimary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 8)
                .background {
                    Circle()
                        .fill(tint.opacity(0.12))
                        .frame(width: 18, height: 18)
                        .offset(y: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)

                Text(bodyText)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.holoToolBorder.opacity(0.55), lineWidth: 1)
        )
    }
}

struct HoloAIMetricTile: View {
    let label: String
    let value: String
    var note: String?
    var isProminent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoToolTextSecondary)

            Text(value)
                .font(.system(size: isProminent ? 26 : 21, weight: .bold))
                .foregroundColor(.holoToolText)
                .minimumScaleFactor(0.78)
                .lineLimit(1)

            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.holoToolBorder.opacity(0.7), lineWidth: 1)
        )
    }
}

struct HoloAISectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.holoToolTextSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.holoToolTextSecondary.opacity(0.08))
            .clipShape(Capsule())
    }
}
