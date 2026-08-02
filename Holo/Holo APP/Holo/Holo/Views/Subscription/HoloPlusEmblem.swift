//
//  HoloPlusEmblem.swift
//  Holo
//
//  Holo Plus 在会员入口和付费墙中的统一标识。
//

import SwiftUI

struct HoloPlusEmblem: View {
    var size: CGFloat = 56
    var showsPlusBadge = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.holoPrimaryLight,   // #FED7AA 浅橙高光
                                Color.holoPrimary,        // #F46D38 品牌橙
                                Color(hex: "#3A211A")     // 暖深褐收尾
                            ],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: size * 0.72
                        )
                    )

                Circle()
                    .strokeBorder(
                        Color.holoPrimaryLight.opacity(0.8),
                        lineWidth: max(1, size * 0.035)
                    )

                Circle()
                    .strokeBorder(
                        Color.white.opacity(0.18),
                        lineWidth: max(1, size * 0.02)
                    )
                    .padding(size * 0.18)

                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.holoPrimaryLight],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(width: size, height: size)
            .shadow(
                color: Color.holoPrimary.opacity(0.22),
                radius: size * 0.18,
                x: 0,
                y: size * 0.08
            )

            if showsPlusBadge {
                Text("+")
                    .font(.system(size: size * 0.2, weight: .black))
                    .foregroundColor(Color.holoPrimaryDark)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .background(Color.holoPrimaryLight)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.72), lineWidth: 1))
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
        .accessibilityLabel("Holo Plus")
    }
}
