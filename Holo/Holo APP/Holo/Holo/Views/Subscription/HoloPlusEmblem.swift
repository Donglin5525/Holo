//
//  HoloPlusEmblem.swift
//  Holo
//
//  Holo Plus 徽章（两态）：以 Holo logo 一笔画侧脸（HoloFaceLineArt）为核心。
//  - 免费态：银灰素描线稿 + 细灰环，安静未点亮
//  - Plus 态：金色麦穗桂冠 + 金线侧脸 + PLUS 缎带，带光晕
//  同一个侧脸符号，免费是素描，升级点亮成金——「从素描到镀金」。
//  2026-10-28 东林拍板回退 10-27 的星芒简洁版；构图整体收进 size×size
//  方框（旧版桂冠横向溢出格子、底部额外撑高，尺寸测试守护此约束）。
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

    private static let goldGradient = LinearGradient(
        colors: [
            Color(hex: "#FFE7AE"),
            Color(hex: "#F2C063"),
            Color(hex: "#D8992B")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static let silverGradient = LinearGradient(
        colors: [
            Color(hex: "#C9BFB4"),
            Color(hex: "#8F857A")
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        Group {
            switch tier {
            case .free: freeEmblem
            case .plus: plusEmblem
            }
        }
        .frame(width: size, height: size)
        .fixedSize()
        .modifier(ShineSweepIfEnabled(enabled: showsShine))
        .accessibilityHidden(true)
    }

    // MARK: - 免费态：素描肖像章

    private var freeEmblem: some View {
        lineArt(tint: Self.silverGradient, side: size * 0.6)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: "#453D36").opacity(0.5)))
            .overlay(Circle().strokeBorder(Color(hex: "#9A8E82").opacity(0.5), lineWidth: 1.2))
    }

    // MARK: - Plus 态：麦穗桂冠 + 金线侧脸 + PLUS 缎带

    private var plusEmblem: some View {
        // 36pt 小尺寸下缎带文字按宽度预算收缩，保证不比方框宽
        let ribbonFontSize = min(9, max(7.5, size * 0.155))

        return HStack(spacing: -size * 0.02) {
            laurel("laurel.leading", side: size * 0.58)
            lineArt(tint: Self.goldGradient, side: size * 0.54)
            laurel("laurel.trailing", side: size * 0.58)
        }
        .foregroundStyle(Self.goldGradient)
        .offset(y: size * 0.04)
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            // 36pt 档缎带宽度逼近方框，必须钉死单行，否则被挤换行撑破构图
            Text("PLUS")
                .font(.system(size: ribbonFontSize, weight: .black))
                .tracking(ribbonFontSize * 0.1)
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(Color(hex: "#5C3A08"))
                .padding(.horizontal, ribbonFontSize * 0.7)
                .padding(.vertical, ribbonFontSize * 0.34)
                .background(Self.goldGradient)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
        }
        .shadow(color: Color(hex: "#D8992B").opacity(0.4), radius: size * 0.16, x: 0, y: size * 0.06)
    }

    /// 侧脸线稿：白色透明底素材，用渐变 mask 上色
    private func lineArt(tint: LinearGradient, side: CGFloat) -> some View {
        tint
            .mask {
                Image("HoloFaceLineArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
            }
    }

    /// 桂冠枝：resizable 后定宽定高，构图总宽可控不溢出方框
    private func laurel(_ name: String, side: CGFloat) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: side * 0.38, height: side)
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
