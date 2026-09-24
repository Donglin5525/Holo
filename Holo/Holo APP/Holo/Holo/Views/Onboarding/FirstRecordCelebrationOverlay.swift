//
//  FirstRecordCelebrationOverlay.swift
//  Holo
//
//  首次记录成功庆祝：轻浮层（暗蒙层 + 徽章卡片 + 纸屑微动画）。
//  触发与一次性落盘由宿主（HomeView）判定；点蒙层或「以后再说」关闭，
//  「去长廊看看」关闭并跳记忆长廊，让用户亲眼看到第一条记录长在那里。
//

import SwiftUI

struct FirstRecordCelebrationOverlay: View {

    var onOpenGallery: () -> Void
    var onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            CelebrationConfetti()

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.holoPrimaryLight, .holoPrimary, Color(red: 234/255, green: 88/255, blue: 12/255)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                        .shadow(color: Color.holoPrimary.opacity(0.4), radius: 14, y: 6)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 14)

                Text(String(localized: "第一条记录完成 🎉"))
                    .font(.title3.weight(.bold))
                    .foregroundColor(.holoTextPrimary)

                Text(String(localized: "你的人生数据库开始运转了。\n去记忆长廊看看，它会随你的生活慢慢生长。"))
                    .font(.subheadline)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 6)

                Button(action: onOpenGallery) {
                    Text(String(localized: "去长廊看看"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.holoPrimary)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .accessibilityIdentifier("firstRecordCelebration.openGallery")

                Button(action: onDismiss) {
                    Text(String(localized: "以后再说"))
                        .font(.caption)
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.holoCardBackground)
                    .shadow(color: Color.black.opacity(0.22), radius: 24, y: 10)
            )
            .padding(.horizontal, 34)
            .scaleEffect(appeared ? 1 : 0.88)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(HoloAnimation.snappy) {
                appeared = true
            }
        }
        .accessibilityIdentifier("firstRecordCelebrationOverlay")
    }
}

// MARK: - 纸屑

/// 循环下落的彩色纸屑；纯装饰，不拦截触摸。
private struct CelebrationConfetti: View {

    struct Piece: Identifiable {
        let id = UUID()
        let xRatio: CGFloat
        let color: Color
        let size: CGSize
        let delay: Double
        let duration: Double
    }

    let pieces: [Piece]

    init() {
        let palette: [Color] = [.holoPrimary, .holoPrimaryLight, .holoChart8, .holoPurple, .holoInfo, .holoSuccess]
        var g = SystemRandomNumberGenerator()
        pieces = (0..<16).map { index in
            Piece(
                xRatio: CGFloat.random(in: 0.06...0.94, using: &g),
                color: palette[index % palette.count],
                size: CGSize(
                    width: CGFloat.random(in: 4...7, using: &g),
                    height: CGFloat.random(in: 7...11, using: &g)
                ),
                delay: Double.random(in: 0...1.6, using: &g),
                duration: Double.random(in: 2.2...3.2, using: &g)
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(pieces) { piece in
                FallingPiece(color: piece.color, size: piece.size, delay: piece.delay, duration: piece.duration)
                    .position(x: piece.xRatio * proxy.size.width, y: proxy.size.height * 0.3)
            }
        }
        .allowsHitTesting(false)
    }

    private struct FallingPiece: View {
        let color: Color
        let size: CGSize
        let delay: Double
        let duration: Double
        @State private var falling = false

        var body: some View {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: size.width, height: size.height)
                .opacity(falling ? 0 : 0.95)
                .offset(y: falling ? 320 : -12)
                .rotationEffect(.degrees(falling ? 210 : 0))
                .onAppear {
                    withAnimation(.easeIn(duration: duration).delay(delay).repeatForever(autoreverses: false)) {
                        falling = true
                    }
                }
        }
    }
}

#Preview {
    FirstRecordCelebrationOverlay(onOpenGallery: {}, onDismiss: {})
}
