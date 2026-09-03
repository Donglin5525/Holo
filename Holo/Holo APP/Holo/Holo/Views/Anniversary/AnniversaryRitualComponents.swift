//
//  AnniversaryRitualComponents.swift
//  Holo
//
//  纪念日「仪式感」组件库：翻牌数字 / 彩带 / 里程碑轨道 / 年度进度环 / 点亮庆祝层
//

import SwiftUI

// MARK: - 翻牌数字

/// 倒数日式的翻牌数字：每位一张卡，中线压痕 + 顶部高光，出场缩放
struct AnniversaryFlipDigits: View {

    let number: Int
    var cardWidth: CGFloat = 58
    var cardHeight: CGFloat = 80
    var fontSize: CGFloat = 48

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(String(number).enumerated()), id: \.offset) { _, ch in
                flipCard(digit: ch)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.15)) {
                revealed = true
            }
        }
    }

    private func flipCard(digit: Character) -> some View {
        Text(String(digit))
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .frame(width: cardWidth, height: cardHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cardWidth * 0.24, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom))
                    // 中线压痕：上下两半的「翻页缝」
                    Rectangle()
                        .fill(Color.black.opacity(0.30))
                        .frame(height: 1.2)
                        .padding(.horizontal, 7)
                    // 顶部高光
                    RoundedRectangle(cornerRadius: cardWidth * 0.24, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.10), .clear],
                            startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardWidth * 0.24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            .scaleEffect(revealed ? 1 : 0.7)
            .opacity(revealed ? 1 : 0)
    }
}

// MARK: - 彩带

/// 庆祝彩带：主题色系碎屑，循环飘落
struct AnniversaryConfetti: View {

    var tint: Color = .white
    var count: Int = 36

    private struct Piece: Identifiable {
        let id: Int
        let xRatio: CGFloat        // 水平位置（0...1）
        let size: CGFloat
        let duration: Double
        let delay: Double
        let rotation: Double
        let colorIndex: Int
        let isCircle: Bool
    }

    @State private var falling = false

    private var pieces: [Piece] {
        var generator = SeededGenerator(seed: 42)
        return (0..<count).map { i in
            Piece(
                id: i,
                xRatio: CGFloat.random(in: 0.05...0.95, using: &generator),
                size: CGFloat.random(in: 4.5...8.5, using: &generator),
                duration: Double.random(in: 2.6...5.2, using: &generator),
                delay: Double.random(in: 0...2.2, using: &generator),
                rotation: Double.random(in: 300...760, using: &generator),
                colorIndex: Int.random(in: 0..<6, using: &generator),
                isCircle: Bool.random(using: &generator)
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(pieces) { piece in
                Group {
                    if piece.isCircle {
                        Circle()
                    } else {
                        RoundedRectangle(cornerRadius: 1.5)
                            .frame(width: piece.size * 0.66, height: piece.size)
                    }
                }
                .foregroundColor(palette[piece.colorIndex % palette.count])
                .frame(width: piece.size, height: piece.size)
                .position(
                    x: geo.size.width * piece.xRatio,
                    y: falling ? geo.size.height + 30 : -30)
                .rotationEffect(.degrees(falling ? piece.rotation : 0))
                .opacity(0.9)
                .animation(
                    .linear(duration: piece.duration)
                        .repeatForever(autoreverses: false)
                        .delay(piece.delay),
                    value: falling)
            }
        }
        .allowsHitTesting(false)
        .onAppear { falling = true }
    }

    private var palette: [Color] {
        [tint, tint.opacity(0.6), Color(red: 0.99, green: 0.90, blue: 0.54), .white.opacity(0.85), Color(red: 0.98, green: 0.65, blue: 0.75), Color(red: 0.65, green: 0.83, blue: 0.99)]
    }
}

/// 固定种子的随机源（彩带布局稳定，避免 SwiftUI 重渲染时碎屑跳变）
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - 里程碑轨道

/// 长途倒数的驿站：已达成（主题色勾）→ 今天恰好（金色星）→ 下一个
struct AnniversaryMilestoneTrack: View {

    let info: AnniversaryMilestoneInfo
    let tint: Color
    var title: String = String(localized: "里程碑")

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if info.isMilestoneToday {
                    Text(String(localized: "今天恰好是第 \(info.totalDays) 天 ✦"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color(red: 0.99, green: 0.90, blue: 0.54))
                } else if let next = info.nextThreshold, let daysTo = info.daysToNext {
                    Text(String(localized: "还有 \(daysTo) 天到第 \(next) 天"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    Text(String(localized: "所有里程碑都已点亮"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            GeometryReader { geo in
                let marks = info.trackMarks
                ZStack(alignment: .leading) {
                    // 底轨
                    Capsule()
                        .fill(Color.white.opacity(0.13))
                        .frame(height: 3)
                    // 进度填充（到下一个里程碑的完成度）
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fillRatio, 4), height: 3)

                    if marks.count >= 2 {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                            let x = geo.size.width * CGFloat(index) / CGFloat(marks.count - 1)
                            node(mark)
                                .position(x: x, y: 1.5)
                        }
                    }
                }
            }
            .frame(height: 24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    /// 进度线填充比例：最后一个已达成里程碑 → 下一个里程碑的进度
    private var fillRatio: CGFloat {
        guard let next = info.nextThreshold else { return 1 }
        let lastReached = info.reached.last ?? 0
        guard next > lastReached else { return 1 }
        return CGFloat(info.totalDays - lastReached) / CGFloat(next - lastReached)
    }

    @ViewBuilder
    private func node(_ mark: AnniversaryMilestoneInfo.Mark) -> some View {
        VStack(spacing: 3) {
            ZStack {
                switch mark.state {
                case .reached:
                    Circle()
                        .fill(tint)
                        .frame(width: 20, height: 20)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white))
                case .now:
                    Circle()
                        .fill(Color(red: 0.99, green: 0.90, blue: 0.54))
                        .frame(width: 20, height: 20)
                        .overlay(Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(Color(red: 0.62, green: 0.36, blue: 0.02)))
                        .shadow(color: Color(red: 0.99, green: 0.90, blue: 0.54).opacity(pulse ? 0.55 : 0.12), radius: pulse ? 9 : 4)
                case .upcoming:
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5).frame(width: 20, height: 20))
                }
            }
            Text(markLabel(mark))
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundColor(mark.state == .now ? Color(red: 0.99, green: 0.90, blue: 0.54) : .white.opacity(0.6))
        }
        .offset(y: -12)
    }

    private func markLabel(_ mark: AnniversaryMilestoneInfo.Mark) -> String {
        "\(mark.days)"
    }
}

// MARK: - 年度进度环

/// 每年重复的「本轮周期走到哪」进度环
struct AnniversaryCycleRing: View {

    let progress: Double
    let tint: Color
    var size: CGFloat = 68
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(
                    AngularGradient(
                        colors: [Color(red: 0.99, green: 0.90, blue: 0.54), tint],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(320)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                Text(String(localized: "本周期"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 点亮庆祝层

/// 「✨ 点亮这个日子」保存后的庆祝时刻：定妆卡 + 盖章 + 彩带
struct AnniversaryLitUpOverlay: View {

    let icon: String
    let title: String
    let dateText: String
    let daysText: String
    let tint: Color
    var onDone: () -> Void

    @State private var cardSettled = false
    @State private var stamped = false

    var body: some View {
        ZStack {
            // 暮色渐变底 + 主题色光晕
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.06, blue: 0.09),
                             tint.opacity(0.22),
                             Color(red: 0.14, green: 0.05, blue: 0.13)],
                    startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                RadialGradient(
                    colors: [tint.opacity(0.45), .clear],
                    center: .center, startRadius: 10, endRadius: 320)
                .ignoresSafeArea()
            }
            .ignoresSafeArea()

            AnniversaryConfetti(tint: tint)

            VStack(spacing: 0) {
                Spacer()

                // 定妆卡
                VStack(spacing: 10) {
                    Group {
                        if EmojiCatalog.isEmojiIcon(icon) {
                            Text(icon).font(.system(size: 38))
                        } else {
                            Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundColor(.white)
                        }
                    }
                    Text(title)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                    Text(daysText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                    Text(dateText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.85), tint.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: tint.opacity(0.5), radius: 26, y: 12)
                .scaleEffect(cardSettled ? 1 : 0.6)
                .opacity(cardSettled ? 1 : 0)

                // 印章
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.25))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 2.5)
                    VStack(spacing: 2) {
                        Text(String(localized: "已点亮"))
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.white)
                        Text(String(localized: "LIT UP"))
                            .font(.system(size: 8, weight: .bold))
                            .kerning(1.5)
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .frame(width: 92, height: 92)
                .offset(y: -18)
                .rotationEffect(.degrees(stamped ? -12 : 6))
                .scaleEffect(stamped ? 1 : 2.1)
                .opacity(stamped ? 1 : 0)

                Spacer().frame(height: 26)

                VStack(spacing: 6) {
                    Text(String(localized: "这一天已被收进你的纪念日"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Text(String(localized: "从今天起，Holo 会替你守着它"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                .multilineTextAlignment(.center)
                .opacity(stamped ? 1 : 0)

                Spacer()

                Button(action: onDone) {
                    Text(String(localized: "去看看"))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
                .opacity(stamped ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) { cardSettled = true }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.6)) { stamped = true }
            HapticManager.success()
        }
    }
}
