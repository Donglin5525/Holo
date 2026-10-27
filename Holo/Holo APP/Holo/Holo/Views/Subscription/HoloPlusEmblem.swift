//
//  HoloPlusEmblem.swift
//  Holo
//
//  固定尺寸的星芒标识：暖纸底、品牌橙与右下角 Plus 标记。
//  免费态使用次文字色，不重复叠加会员文字或大幅装饰。
//

import SwiftUI

/// 徽章档位
enum HoloPlusEmblemTier {
    case free
    case plus
}

struct HoloPlusEmblem: View {
    var size: CGFloat = 56
    /// 徽章档位：个人页/会员中心按真实权益传入；付费墙始终展示 Plus 态
    var tier: HoloPlusEmblemTier = .plus
    /// 扫光动效：仅付费墙开启
    var showsShine: Bool = false

    private var isPlus: Bool { tier == .plus }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.holoToolInset)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.holoToolBorder, lineWidth: 0.75)
                }
            // 使用清晰的原生矢量符号，小尺寸下不依赖细线插画。
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.52, weight: .medium))
                .foregroundStyle(isPlus ? Color.holoToolAction : Color.holoToolTextSecondary)
                .frame(width: size, height: size)
            if isPlus {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.17, weight: .bold))
                    .foregroundStyle(Color.holoToolOnAction)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .background(Color.holoToolAction, in: Circle())
                    .overlay(Circle().strokeBorder(Color.holoToolSurface, lineWidth: 1.5))
            }
        }
        .frame(width: size, height: size)
        .fixedSize()
        .modifier(ShineSweepIfEnabled(enabled: showsShine))
        .accessibilityHidden(true)
    }

}

// MARK: - 扫光动效（仅付费墙开启）

struct ShineSweepIfEnabled: ViewModifier {
    let enabled: Bool

    @State private var x: CGFloat = -1.4

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.65), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 0.24)
                        .offset(x: geo.size.width * x)
                        .allowsHitTesting(false)
                    }
                )
                .mask { content }
                .holoRepeatingPhase($x, from: -1.4, to: 1.4,
                                    animation: .linear(duration: 2.6).repeatForever(autoreverses: false))
        } else {
            content
        }
    }
}
