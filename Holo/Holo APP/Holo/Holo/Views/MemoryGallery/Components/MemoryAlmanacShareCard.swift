//
//  MemoryAlmanacShareCard.swift
//  Holo
//
//  年鉴分享图（定稿 A）：固定浅色纸面 9:16；刊头 + 衬线大数字 + 12 行 × 31 列同大小点阵
//  （只画记过的日子，3 档深浅，今天橙色）+ 页脚印章。默认不含任何正文与用户名。
//  方案：docs/_common/plans/2026-11-21-记忆长廊年鉴卡/01-方案.md
//

import SwiftUI

// MARK: - 分享卡（渲染为图片的画面本体）

struct MemoryAlmanacShareCard: View {
    let almanac: MemoryAlmanacYear

    /// 画布 360×640pt，3x 导出 1080×1920
    static let canvasSize = CGSize(width: 360, height: 640)
    private static let inset: CGFloat = 28
    private static let labelWidth: CGFloat = 26
    private static let levelOpacity: [Double] = [0, 0.28, 0.58, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Text(verbatim: "\(almanac.recordedDays)")
                .font(.holoHeroNumber(size: 76))
                .foregroundStyle(Color.holoAlmanacPaperInk)
                .padding(.top, 34)
            Text("天，留下了记录。")
                .font(.system(size: 15))
                .foregroundStyle(Color.holoAlmanacPaperInk)
                .padding(.top, 4)
            Text(String(localized: "共 \(almanac.totalCount.formatted()) 件事"))
                .font(.system(size: 12))
                .foregroundStyle(Color.holoAlmanacPaperMuted)
                .padding(.top, 2)
            Canvas { context, size in drawGrid(in: &context, size: size) }
                .frame(height: Self.gridHeight)
                .padding(.top, 44)
            Text("每一个点是一天，颜色越深记得越多。")
                .font(.system(size: 10))
                .tracking(0.5)
                .foregroundStyle(Color.holoAlmanacPaperMuted)
                .padding(.top, 14)
            Spacer(minLength: 0)
            footer
        }
        .padding(Self.inset)
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
        .background(Color.holoAlmanacPaper)
        .environment(\.colorScheme, .light)
    }

    private var masthead: some View {
        VStack(spacing: 3) {
            HStack {
                Text("HOLO · 人生年鉴")
                Spacer()
                Text(verbatim: String(almanac.year))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(2.5)
            .foregroundStyle(Color.holoAlmanacPaperInk)
            .padding(.bottom, 2)
            Rectangle().fill(Color.holoAlmanacPaperInk).frame(height: 1.5)
            Rectangle().fill(Color.holoAlmanacPaperInk).frame(height: 0.5)
        }
    }

    private var footer: some View {
        HStack {
            Text("记录我的人生")
                .font(.system(size: 9.5))
                .tracking(2)
                .foregroundStyle(Color.holoAlmanacPaperMuted)
            Spacer()
            Text(verbatim: "HOLO")
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Color.holoPrimary)
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(Color.holoPrimary, lineWidth: 1.5))
                .rotationEffect(.degrees(-12))
        }
    }

    // MARK: - 12 × 31 点阵

    private static var pitch: CGFloat { (canvasSize.width - inset * 2 - labelWidth) / 31 }
    /// 行距放宽到 1.9 倍点距：点阵占满纸面中段，避免下方大片留空（走查反馈）
    private static var rowHeight: CGFloat { pitch * 1.9 }
    private static var gridHeight: CGFloat { 12 + rowHeight * 12 }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let pitch = Self.pitch, radius = pitch * 0.29
        for day in [1, 10, 20, 31] {
            context.draw(
                Text(verbatim: "\(day)").font(.system(size: 7.5)).foregroundColor(.holoAlmanacPaperMuted),
                at: CGPoint(x: Self.labelWidth + (CGFloat(day) - 0.5) * pitch, y: 4)
            )
        }
        for month in almanac.months {
            let y = 12 + (CGFloat(month.month - 1) + 0.5) * Self.rowHeight
            context.draw(
                Text(String(localized: "\(month.month)月")).font(.system(size: 8.5)).foregroundColor(.holoAlmanacPaperMuted),
                at: CGPoint(x: 0, y: y), anchor: .leading
            )
            for (index, day) in month.days.enumerated() where day.kind == .today || (day.kind == .past && day.level > 0) {
                let x = Self.labelWidth + (CGFloat(index) + 0.5) * pitch
                let isToday = day.kind == .today
                let r = isToday ? radius + 0.6 : radius
                let color: Color = isToday ? .holoPrimary : Color.holoAlmanacPaperInk.opacity(Self.levelOpacity[day.level])
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
    }
}

// MARK: - 分享弹层（预览 + 系统分享）

struct MemoryAlmanacShareSheet: View {
    let almanac: MemoryAlmanacYear
    @Environment(\.dismiss) private var dismiss

    /// init 时渲染一次，避免 ShareLink 的 item / preview 各取一次重复渲染（同纪念日分享）
    private let renderedImage: Image

    init(almanac: MemoryAlmanacYear) {
        self.almanac = almanac
        let renderer = ImageRenderer(content: MemoryAlmanacShareCard(almanac: almanac))
        renderer.scale = 3
        #if canImport(UIKit)
        let rendered = renderer.uiImage.map { Image(uiImage: $0) }
        #else
        let rendered = renderer.nsImage.map { Image(nsImage: $0) }
        #endif
        self.renderedImage = rendered ?? Image(systemName: "photo")
    }

    var body: some View {
        HoloSheetScaffold(title: String(localized: "分享年鉴"), onClose: { dismiss() }) {
            renderedImage
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .padding(.horizontal, HoloSpacing.xl)
                .padding(.vertical, HoloSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(String(localized: "\(String(almanac.year)) 年，\(almanac.recordedDays) 天有记录，共 \(almanac.totalCount) 件事"))
                .safeAreaInset(edge: .bottom) {
                    ShareLink(
                        item: renderedImage,
                        preview: SharePreview(String(localized: "Holo 人生年鉴"), image: renderedImage)
                    ) {
                        Label(String(localized: "分享这张年鉴"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HoloActionStyle(role: .primary))
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.bottom, HoloSpacing.sm)
                }
        }
        .holoSheetShell()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
