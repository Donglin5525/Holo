//
//  DailyKanbanEntryButton.swift
//  Holo
//
//  首页中心今日看板入口按钮
//  纯圆圈按钮，后续替换图标
//

import SwiftUI

struct DailyKanbanEntryButton: View {

    let action: () -> Void

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            outerRing(size: 320, opacity: 0.05)
            outerRing(size: 256, opacity: 0.1)
            mainButton
        }
        .frame(width: 192, height: 192)
    }

    private func outerRing(size: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(Color.holoPrimary.opacity(opacity), lineWidth: 1)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }

    private var mainButton: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.holoPrimaryLight, .holoPrimary, .holoPrimaryDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.8)
            }
        }
        .frame(width: 192, height: 192)
        .contentShape(Circle())
        .shadow(color: .holoPrimary.opacity(0.3), radius: 30)
        .scaleEffect(isAnimating ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }
}

#Preview {
    ZStack {
        Color.holoBackground.ignoresSafeArea()
        DailyKanbanEntryButton { }
    }
}
