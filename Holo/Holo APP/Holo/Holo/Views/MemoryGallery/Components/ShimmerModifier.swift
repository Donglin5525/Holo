//
//  ShimmerModifier.swift
//  Holo
//
//  Shimmer 加载动画 — 用于骨架屏卡片
//

import SwiftUI

/// Shimmer 动画修饰器
struct ShimmerModifier: ViewModifier {

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Color.white.opacity(0.3), location: 0.5),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 400)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .holoRepeatingPhase($phase, from: -1, to: 1,
                                animation: .linear(duration: 1.5).repeatForever(autoreverses: false))
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}
