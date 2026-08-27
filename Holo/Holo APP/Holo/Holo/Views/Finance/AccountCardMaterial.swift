//
//  AccountCardMaterial.swift
//  Holo
//
//  账户卡堆的材质层：暖家族色板 + 多层光效卡面（渐变/柔光/晕影/斜光带/噪点/内描边）
//  视觉规范见 docs/design-mockups/finance-account-cards-brand.html
//

import SwiftUI
import UIKit

// MARK: - 暖家族色板

/// 每张账户卡的材质色板：暖深褐打底 → 暖化主色 → 亮段。
/// 五个类型默认色走精确预设（与设计稿一致）；用户自定义色按同一规则暖化生成，
/// 保证任何颜色进来的卡都和净资产卡、Plus 主题同一「暖家族」血缘。
struct AccountCardPalette {
    let c1: Color      // 暖深褐底
    let c2: Color      // 暖化主色
    let c3: Color      // 亮段
    let accent: Color  // 环境光 / 动态区强调色

    /// 品牌橙金卡（信用卡默认）：品牌色最重的舞台
    static let brandGold = AccountCardPalette(
        c1: Color(hex: "#4A2410"),
        c2: Color(hex: "#B4581E"),
        c3: Color(hex: "#F07A2E"),
        accent: Color(hex: "#E06A1F")
    )

    static func palette(for account: Account) -> AccountCardPalette {
        // 用户没改色（账户色 == 类型默认色）时直接用预设，呈现设计稿精确效果
        if account.color == account.accountType.defaultColor {
            switch account.accountType {
            case .cash:
                return AccountCardPalette(c1: Color(hex: "#1A1B14"), c2: Color(hex: "#23684A"), c3: Color(hex: "#35A06D"), accent: Color(hex: "#2E8B60"))
            case .digital:
                return AccountCardPalette(c1: Color(hex: "#1E1B33"), c2: Color(hex: "#3E46A8"), c3: Color(hex: "#6B74E8"), accent: Color(hex: "#4F55C4"))
            case .bank, .card:
                return AccountCardPalette(c1: Color(hex: "#2A2050"), c2: Color(hex: "#5B4BC8"), c3: Color(hex: "#8E7AF0"), accent: Color(hex: "#6A58D8"))
            case .creditCard:
                return .brandGold
            case .other:
                return AccountCardPalette(c1: Color(hex: "#241F1C"), c2: Color(hex: "#5A5148"), c3: Color(hex: "#8A8074"), accent: Color(hex: "#6E655A"))
            }
        }
        return AccountCardPalette(warmFamilyOf: UIColor(Color(hex: account.color)))
    }
}

extension AccountCardPalette {
    /// 自定义色的暖化映射：色相向琥珀拉近、饱和压低，三段渐变同源
    /// （放在 extension 里，避免抑制四参数 memberwise init）
    private init(warmFamilyOf base: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // 环形最短路径向琥珀色相 (~32°) 拉近 18%
        let amberHue: CGFloat = 32.0 / 360.0
        let delta = ((amberHue - h + 0.5).truncatingRemainder(dividingBy: 1)) - 0.5
        let warmH = (h + delta * 0.18).truncatingRemainder(dividingBy: 1)
        let clampedS = min(max(s * 0.85, 0.40), 0.62)

        self.init(
            c1: Color(hue: warmH, saturation: 0.28, brightness: 0.10),
            c2: Color(hue: warmH, saturation: clampedS, brightness: 0.48),
            c3: Color(hue: warmH, saturation: clampedS * 0.9, brightness: 0.66),
            accent: Color(hue: warmH, saturation: clampedS, brightness: 0.55)
        )
    }
}

// MARK: - 噪点肌理

/// 一次性生成的灰度噪点纹理：叠在渐变上（overlay 混合、5% 透明度），
/// 消除纯数码渐变的「平」感，出印刷/金属质感。
enum AccountCardNoise {
    static let image: UIImage = {
        let width = 128, height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let v = UInt8.random(in: 0...255)
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 255
        }
        let cgImage = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        // 生成失败时退化为空图（仅损失噪点肌理，无功能影响）
        return cgImage.map(UIImage.init) ?? UIImage()
    }()
}

// MARK: - 材质修饰符

/// 账户卡面材质：基底三段渐变 + 右上暖金柔光 + 左下晕影 + 斜向光带 + 噪点 +
/// 内描边高光 + 双层投影；当前卡额外带品牌橙描边光晕（品牌光照在哪张卡上）。
/// compact = 收起卡：用更小更近的投影，叠压处形成实体卡堆的深度感。
struct AccountCardMaterial: ViewModifier {
    let palette: AccountCardPalette
    let isCurrent: Bool
    var compact: Bool = false

    static let cornerRadius: CGFloat = 20
    /// 统一 Holo 暖金高光（所有卡同一颗暖光）
    private static let warmGlow = Color(hex: "#FFCD8C")
    /// 负债色：卡面/列表的负余额统一用这支暖橙红（与净资产卡「总负债」同色）
    static let debtColor = Color(hex: "#FFA98F")

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    LinearGradient(colors: [palette.c1, palette.c2, palette.c3], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [Self.warmGlow.opacity(0.16), .clear], center: UnitPoint(x: 0.86, y: -0.10), startRadius: 8, endRadius: 320)
                    RadialGradient(colors: [.black.opacity(0.35), .clear], center: UnitPoint(x: -0.08, y: 1.1), startRadius: 8, endRadius: 300)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.34),
                            .init(color: Color(hex: "#FFEBCD").opacity(0.09), location: 0.44),
                            .init(color: Color(hex: "#FFEBCD").opacity(0.16), location: 0.48),
                            .init(color: Color(hex: "#FFEBCD").opacity(0.05), location: 0.54),
                            .init(color: .clear, location: 0.64)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(uiImage: AccountCardNoise.image)
                        .resizable()
                        .blendMode(.overlay)
                        .opacity(0.05)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            // 收起卡投影压轻一档：叠压处深色背景下曾显「脏缝」，
            // 深度感交给叠压几何本身，阴影只做轻托底
            .shadow(color: .black.opacity(compact ? 0.22 : 0.28), radius: compact ? 7 : 20, y: compact ? 4 : 14)
            .shadow(color: .black.opacity(compact ? 0.10 : 0.16), radius: compact ? 2 : 5, y: compact ? 1 : 3)
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.holoPrimary.opacity(0.45), lineWidth: 1)
                    .shadow(color: Color.holoPrimary.opacity(0.22), radius: 14)
                    .allowsHitTesting(false)
                    .opacity(isCurrent ? 1 : 0)
            )
    }
}

// MARK: - 卡面小组件

/// 信用卡 / 储蓄卡卡面的金属芯片（现金、钱包类不带——实体感分层）
struct AccountChipIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex:"#F8DE8E"), Color(hex:"#D9AE55"), Color(hex:"#B98836"), Color(hex:"#E8C56B")], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex:"#5A3C0F").opacity(0.35)).frame(height: 1.2)
                HStack(spacing: 0) {
                    Rectangle().fill(Color(hex:"#5A3C0F").opacity(0.30)).frame(width: 1.2)
                    Spacer()
                    Rectangle().fill(Color(hex:"#5A3C0F").opacity(0.30)).frame(width: 1.2)
                }
                Rectangle().fill(Color(hex:"#5A3C0F").opacity(0.35)).frame(height: 1.2)
            }
            .padding(.horizontal, 7)
        }
        .frame(width: 44, height: 33)
        .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
    }
}

// MARK: - 账户类型英文标签（卡面中英双语排印）

extension AccountType {
    /// 卡面类型行的英文小字：实体银行卡的经典排印手法
    var englishLabel: String {
        switch self {
        case .cash: return "CASH"
        case .digital: return "WALLET"
        case .bank, .card: return "SAVINGS"
        case .creditCard: return "CREDIT"
        case .other: return "ACCOUNT"
        }
    }
}
