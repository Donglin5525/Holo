//
//  ReportOnePageShareCard.swift
//  Holo
//
//  深度报告「一屏结论」分享卡（2026-11-20 报告改版 A 期）：
//  固定 9:16 画布（340×604pt，3x 导出 1020×1812px），不随报告长度生长——
//  彻底避开长图超 8000px 降 scale 导致的「文字被压缩」。
//  内容优先级：标题 → 导语 → 要点（放不下按 3/2/1/0 依次退）→ 下一步；暖纸配色与完整长图同源。
//

import SwiftUI

struct ReportOnePageShareCard: View {
    let digest: ReportShareDigest
    let question: String?
    let scopeLine: String
    var showsBrandFooter: Bool = true

    static let canvasSize = CGSize(width: 340, height: 604)

    /// 弹性区退让顺序：导语+3/2/1/0 个要点 → 去掉导语只留 2/1 个要点
    private struct TextVariant {
        let id: String
        let points: Int
        let showsLede: Bool
    }
    private static let textVariants: [TextVariant] =
        [3, 2, 1, 0].map { TextVariant(id: "lede-\($0)", points: $0, showsLede: true) }
        + [2, 1].map { TextVariant(id: "bare-\($0)", points: $0, showsLede: false) }

    private let ink = Color(red: 0.239, green: 0.196, blue: 0.161)
    private let inkSoft = Color(red: 0.627, green: 0.541, blue: 0.455)
    private let holo = Color(red: 0.957, green: 0.427, blue: 0.220)
    private let holoDeep = Color(red: 0.918, green: 0.345, blue: 0.047)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let question {
                Text(verbatim: "“\(question)”")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(inkSoft)
                    .lineLimit(1)
                    .padding(.top, 14)
            }
            Text(digest.title)
                .font(Font.custom("Songti SC", size: 20).weight(.bold))
                .foregroundColor(ink)
                .lineSpacing(4)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, question == nil ? 16 : 8)

            // 组件最简形态：进度环 / 数字卡 + 关联事项每周柱（固定区，优先于文字）
            if let progress = digest.progress {
                progressHero(progress)
                    .padding(.top, 14)
            } else if !digest.tiles.isEmpty {
                tilesRow(digest.tiles)
                    .padding(.top, 14)
            }
            if !digest.habits.isEmpty {
                habitBars(digest.habits)
                    .padding(.top, 14)
            }

            // 弹性区：导语 + 要点，放不下按 3/2/1/0 个要点依次退，再退掉导语
            // 候选布局必须单个 ForEach + 唯一 ID：两个 ForEach 的 Int ID 重复会让 ViewThatFits 直接 Fatal error
            ViewThatFits(in: .vertical) {
                ForEach(Self.textVariants, id: \.id) { variant in
                    flexibleText(points: variant.points, showsLede: variant.showsLede)
                }
                Color.clear.frame(height: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            .padding(.top, 14)

            if let nextStep = digest.nextStep {
                nextStepBlock(nextStep)
            }
            if showsBrandFooter {
                footer
            } else {
                Spacer().frame(height: 22)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
        .background(background)
    }

    // MARK: - 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(holo)
                Text("HOLO 深度洞察")
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(2)
                    .foregroundColor(holoDeep)
                Spacer()
            }
            if !scopeLine.isEmpty {
                Text(scopeLine)
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1)
                    .foregroundColor(inkSoft)
                    .lineLimit(1)
            }
        }
    }

    private func flexibleText(points: Int, showsLede: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsLede, let lede = digest.lede {
                ledeBlock(lede)
            }
            if points > 0, !digest.points.isEmpty {
                pointsList(Array(digest.points.prefix(points)))
            }
        }
    }

    private func progressHero(_ progress: HoloReportComponent.Progress) -> some View {
        HStack(spacing: 14) {
            if let fraction = progress.fraction {
                ZStack {
                    Circle().stroke(ink.opacity(0.08), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0), 1))
                        .stroke(progress.isStale == true ? inkSoft : holo, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(ReportProgressView.percent(fraction))
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundColor(ink)
                        Text(String(localized: "已完成"))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(inkSoft)
                    }
                }
                .frame(width: 70, height: 70)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let current = progress.current {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ReportProgressView.format(current))
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundColor(ink)
                        Text(progress.unit ?? "")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(inkSoft)
                    }
                }
                Text(progress.statusLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor((progress.tone ?? .neutral).color)
                if let caption = progress.caption ?? progress.projections?.last.map({ "\($0.label)：\($0.value)" }) {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(inkSoft)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tilesRow(_ tiles: [HoloReportComponent.KPITiles.Tile]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(inkSoft)
                        .lineLimit(1)
                    Text(tile.value + (tile.unit ?? ""))
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let delta = tile.delta {
                        Text(delta)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor((tile.tone ?? .neutral).color)
                            .lineLimit(1)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(holo.opacity(0.06)))
            }
        }
    }

    private func habitBars(_ habits: [ReportShareDigest.HabitBars]) -> some View {
        VStack(spacing: 7) {
            ForEach(Array(habits.enumerated()), id: \.offset) { _, habit in
                HStack(spacing: 8) {
                    Text(habit.name)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(ink)
                        .lineLimit(1)
                        .frame(width: 62, alignment: .leading)
                    HStack(alignment: .bottom, spacing: 2) {
                        let peak = max(habit.weekly.max() ?? 1, 1)
                        ForEach(Array(habit.weekly.enumerated()), id: \.offset) { _, count in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(holo.opacity(count == 0 ? 0.18 : 0.85))
                                .frame(height: max(2, 16 * CGFloat(count) / CGFloat(peak)))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 16, alignment: .bottom)
                    if let status = habit.statusLabel {
                        Text(status)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor((habit.tone ?? .neutral).color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .background(Capsule().fill((habit.tone ?? .neutral).color.opacity(0.12)))
                            .frame(width: 62, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func ledeBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(holo)
                .frame(width: 3)
            Text(text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(ink.opacity(0.9))
                .lineSpacing(5)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(holo.opacity(0.07)))
        // 按内容收高：左侧竖条是弹性形状，不收高会在弹性区里被无限拉长
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pointsList(_ points: [ReportShareDigest.Point]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(holoDeep)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(holo.opacity(0.13)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.title)
                            .font(Font.custom("Songti SC", size: 14).weight(.bold))
                            .foregroundColor(ink)
                            .lineLimit(1)
                        Text(point.line)
                            .font(.system(size: 12.5))
                            .foregroundColor(ink.opacity(0.78))
                            .lineSpacing(3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nextStepBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "下一步"))
                .font(.system(size: 10, weight: .heavy))
                .kerning(2)
                .foregroundColor(holoDeep)
            Text(text)
                .font(Font.custom("Songti SC", size: 13.5).weight(.semibold))
                .foregroundColor(ink)
                .lineSpacing(4)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(holo.opacity(0.09)))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image("HoloFaceLineArt")
                .resizable()
                .scaledToFit()
                .frame(height: 14)
                .opacity(0.9)
            Text(String(localized: "HOLO · 人生数据库"))
                .font(.system(size: 10, weight: .semibold))
                .kerning(2.5)
                .foregroundColor(Color(red: 0.659, green: 0.573, blue: 0.478))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.992, green: 0.976, blue: 0.941), Color(red: 0.980, green: 0.953, blue: 0.902)],
                startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)
            )
            RadialGradient(colors: [holo.opacity(0.07), .clear],
                           center: UnitPoint(x: 0.08, y: 0.02), startRadius: 8, endRadius: 240)
            RadialGradient(colors: [holo.opacity(0.07), .clear],
                           center: UnitPoint(x: 0.95, y: 0.98), startRadius: 8, endRadius: 220)
        }
    }

    // MARK: - 导出

    /// 固定画布 3x 导出（1020×1812px），远低于 ImageRenderer 约 8192px 上限，无需降 scale 重渲。
    @MainActor static func renderExportImage(_ card: ReportOnePageShareCard) -> UIImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        #if canImport(UIKit)
        return renderer.uiImage
        #else
        return renderer.nsImage
        #endif
    }
}
