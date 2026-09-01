//
//  HoloPlusEmblem.swift
//  Holo
//
//  Holo Plus 徽章（两态）：以 Holo logo 一笔画侧脸（HoloFaceLineArt）为核心。
//  - 免费态：银灰素描线稿 + 细灰环，安静未点亮
//  - Plus 态：金色麦穗桂冠 + 金线侧脸 + PLUS 缎带，带光晕
//  同一个侧脸符号，免费是素描，升级点亮成金——「从素描到镀金」。
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
        switch tier {
        case .free: freeEmblem
        case .plus: plusEmblem
        }
    }

    // MARK: - 免费态：素描肖像章

    private var freeEmblem: some View {
        lineArt(tint: Self.silverGradient, height: size * 0.6)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: "#453D36").opacity(0.5)))
            .overlay(Circle().strokeBorder(Color(hex: "#9A8E82").opacity(0.5), lineWidth: 1.2))
    }

    // MARK: - Plus 态：麦穗桂冠 + 金线侧脸 + PLUS 缎带

    private var plusEmblem: some View {
        let laurelFont = size * 0.72
        let ribbonFontSize = max(9, size * 0.155)

        return HStack(spacing: 0) {
            Image(systemName: "laurel.leading")
                .font(.system(size: laurelFont))

            lineArt(tint: Self.goldGradient, height: size)

            Image(systemName: "laurel.trailing")
                .font(.system(size: laurelFont))
        }
        .foregroundStyle(Self.goldGradient)
        .overlay(alignment: .bottom) {
            Text("PLUS")
                .font(.system(size: ribbonFontSize, weight: .black))
                .tracking(ribbonFontSize * 0.16)
                .foregroundColor(Color(hex: "#5C3A08"))
                .padding(.horizontal, ribbonFontSize * 0.9)
                .padding(.vertical, ribbonFontSize * 0.34)
                .background(Self.goldGradient)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
                .offset(y: size * 0.1)
        }
        .shadow(color: Color(hex: "#D8992B").opacity(0.4), radius: size * 0.16, x: 0, y: size * 0.06)
        .modifier(ShineSweepIfEnabled(enabled: showsShine))
        // 缎带压在桂冠下缘，预留纵向空间避免被父视图裁切
        .padding(.bottom, size * 0.14)
    }

    /// 侧脸线稿：白色透明底素材，用渐变 mask 上色
    private func lineArt(tint: LinearGradient, height: CGFloat) -> some View {
        tint
            .mask {
                Image("HoloFaceLineArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: height, height: height)
            }
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
                .onAppear {
                    withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                        x = 1.4
                    }
                }
        } else {
            content
        }
    }
}
