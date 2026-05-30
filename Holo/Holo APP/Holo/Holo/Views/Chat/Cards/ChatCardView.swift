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
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)

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
            .font(.holoTinyLabel)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }
}

/// 卡片分隔线
struct CardDivider: View {

    var body: some View {
        Rectangle()
            .fill(Color.holoDivider)
            .frame(height: 0.5)
    }
}

/// 卡片底部行（时间 + 操作入口箭头）
struct CardFooterView: View {

    let timeText: String

    var body: some View {
        HStack {
            Text(timeText)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
        }
    }
}
