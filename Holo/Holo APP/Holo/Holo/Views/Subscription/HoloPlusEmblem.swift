//
//  HoloPlusEmblem.swift
//  Holo
//
//  东林确认的 A2：流畅肖像线稿 + 两侧麦穗 + 右上角 PLUS 角标。
//  免费态使用同系列银灰肖像，不展示会员麦穗与角标。
//  图形以亮度蒙版着色，角标由原生文字绘制；所有内容收在 size×size 内。
//

import SwiftUI

/// 徽章档位
enum HoloPlusEmblemTier {
    case free
    case plus
}

struct HoloPlusEmblem: View {
    var size: CGFloat = 72
    /// 徽章档位：个人页/会员中心按真实权益传入；付费墙始终展示 Plus 态
    var tier: HoloPlusEmblemTier = .plus
    /// 扫光动效：仅付费墙开启
    var showsShine: Bool = false

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
        HoloPlusTheme.emblemSilverGradient
            .mask { portraitMask("HoloPlusPortraitMask", scale: 1.16) }
            .frame(width: size, height: size)
            .background(Circle().fill(HoloPlusTheme.freeEmblemBackground))
            .overlay(Circle().strokeBorder(HoloPlusTheme.freeEmblemBorder, lineWidth: 1))
    }

    // MARK: - Plus 态：完整 A2 图形与独立角标

    private var plusEmblem: some View {
        HoloPlusTheme.emblemGoldGradient
            .mask { portraitMask("HoloPlusPortraitWheatMask", scale: 1.1) }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) { plusCornerBadge }
    }

    /// 角标不烘焙到图片；在 36–72pt 档保持单行，且不撑出图形方框。
    private var plusCornerBadge: some View {
        Text("PLUS")
            .font(.system(size: max(6, size * 0.12), weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(HoloPlusTheme.emblemBadgeText)
            .frame(width: max(16, size * 0.36), height: max(9, size * 0.18))
            .background(HoloPlusTheme.emblemGoldGradient, in: Capsule())
    }

    /// 正式素材保留黑白亮度，运行时把黑底转成透明，避免抠图杂边。
    /// 轻微提高对比度清除近黑底色；只缩放图形，不改变组件声明尺寸。
    private func portraitMask(_ name: String, scale: CGFloat) -> some View {
        Image(name)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .contrast(1.1)
            .luminanceToAlpha()
            .scaleEffect(scale)
            .frame(width: size, height: size)
            .clipped()
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
