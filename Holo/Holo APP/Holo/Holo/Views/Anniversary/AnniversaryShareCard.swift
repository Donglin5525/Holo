//
//  AnniversaryShareCard.swift
//  Holo
//
//  纪念日分享卡：详情页「分享这一天」/ 当天「把祝福说出口」→ 生成图片分享
//

import SwiftUI

// MARK: - 分享卡视图（渲染目标）

struct AnniversaryShareCard: View {

    let icon: String
    let title: String
    let dateText: String
    /// 主数字行：「51」（配 unitLine 显示「还有 51 天」）
    let bigText: String
    let unitLine: String
    /// 可选祝福语（当天分享）
    let wishText: String?
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 34)

            Group {
                if EmojiCatalog.isEmojiIcon(icon) {
                    Text(icon).font(.system(size: 44))
                } else {
                    Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundColor(.white)
                }
            }

            Text(title)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 14)

            Text(dateText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 5)

            Text(bigText)
                .font(.system(size: 86, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .padding(.top, 22)

            Text(unitLine)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.top, 2)

            if let wish = wishText, !wish.isEmpty {
                Text(wish)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 44)
                    .padding(.top, 22)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4)
                Text(String(localized: "Holo · 替你守着每个重要的日子"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4)
            }
            .padding(.bottom, 26)
        }
        .frame(width: 320, height: 460)
        .background(
            ZStack {
                LinearGradient(
                    colors: [tint.opacity(0.92), tint.opacity(0.45), Color(red: 0.09, green: 0.06, blue: 0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [Color.white.opacity(0.14), .clear],
                    center: UnitPoint(x: 0.8, y: 0.1), startRadius: 6, endRadius: 260)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: - 分享面板（预览 + 系统分享）

struct AnniversaryShareSheet: View {

    let card: AnniversaryShareCard
    var tint: Color = Color(hex: "#F46D38")

    @Environment(\.dismiss) private var dismiss

    private var renderedImage: Image {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2.5
        if let uiImage = renderer.uiImage {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "photo")
    }

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4.5)
                .padding(.top, 10)

            Text(String(localized: "分享这一天"))
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)

            card
                .frame(height: 430)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

            ShareLink(
                item: renderedImage,
                preview: SharePreview(String(localized: "Holo 纪念日"), image: renderedImage)) {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.up")
                        Text(String(localized: "把这一天说给 TA 听"))
                    }
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(tint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .background(Color(red: 0.10, green: 0.07, blue: 0.11).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }
}
