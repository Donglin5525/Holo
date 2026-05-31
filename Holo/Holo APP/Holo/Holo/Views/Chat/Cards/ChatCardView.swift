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
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [
                    Color.holoCardBackground,
                    Color.holoCardBackground.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: HoloShadow.card.opacity(0.55), radius: 14, x: 0, y: 7)
        .opacity(isDeleted ? 0.5 : 1.0)
        .saturation(isDeleted ? 0 : 1)
        .overlay(alignment: .bottomTrailing) {
            if isDeleted {
                Text("已删除")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoError)
                    .padding(.horizontal, HoloSpacing.xs)
                    .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - 卡片交互样式

/// 卡片按下效果：scale(0.97) + opacity(0.8)
struct CardButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 卡片通用组件

/// 卡片头部行（图标 + 标题 + 可选徽章）
struct CardHeaderView: View {

    let icon: String
    let title: String
    var badge: CardBadge?
    var subtitle: String?

    init(icon: String, title: String, badge: CardBadge? = nil, subtitle: String? = nil) {
        self.icon = icon
        self.title = title
        self.badge = badge
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 34, height: 34)
                .background(Color.holoPrimary.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let badge {
                badge
            }
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
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

    var body: some View {
        HStack {
            Text(timeText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.holoPrimary.opacity(0.78))
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
                .foregroundColor(.holoTextSecondary)

            Text(value)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(tint)
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
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
                    .foregroundColor(.holoTextSecondary)

                Text(bodyText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.holoTextPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
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
                .foregroundColor(.holoTextSecondary)

            Text(value)
                .font(.system(size: isProminent ? 26 : 21, weight: .bold))
                .foregroundColor(.holoTextPrimary)
                .minimumScaleFactor(0.78)
                .lineLimit(1)

            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.7), lineWidth: 1)
        )
    }
}

struct HoloAISectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.holoTextSecondary.opacity(0.08))
            .clipShape(Capsule())
    }
}
