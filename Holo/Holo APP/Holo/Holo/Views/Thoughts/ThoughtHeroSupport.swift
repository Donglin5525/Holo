//
//  ThoughtHeroSupport.swift
//  Holo
//
//  想法头图接线（方案 01 §6，原型场景四 1:1；2026-11-23 东林拍板方案 B）：
//  照片铺满宽度、高度跟随照片比例（夹在 16:9 与 4:3 之间），贴纸完整站在淡色舞台上；
//  列表与编辑页用同一套比例规则。头图独立于正文附件与纸张；九种纸张照旧；
//  无头图整段折叠不留空占位；只换头图不触发文本 AI（纯视觉提交，02 §5.2）。
//  对比原型：docs/design-prototypes/想法头图协调方案/想法头图协调方案-对比原型.html
//

import SwiftUI
import CoreData

extension Thought {
    static let visualOwnerKind = "thought"
    static let visualSlot = "hero"

    /// 存量老数据 id 可能未写——安全读，缺 id 的旧想法跳过头图解析（原排版）
    var visualOwnerKey: String? {
        (value(forKey: "id") as? UUID)?.uuidString
    }

    func resolveHeroVisual(in context: NSManagedObjectContext) -> ResolvedPlacement {
        guard let visualOwnerKey else { return .none }
        return VisualAssetRepository.shared.resolvePlacement(ownerKind: Self.visualOwnerKind,
                                                      ownerKey: visualOwnerKey,
                                                      slot: Self.visualSlot,
                                                      in: context)
    }
}

// MARK: - 排版数值

enum ThoughtHeroMetrics {
    /// 通栏最扁 / 最高的比例（宽÷高）：比 16:9 更扁的照片压到 16:9，比 4:3 更高的照片压到 4:3
    static let widestBandRatio: CGFloat = 16.0 / 9.0
    static let tallestBandRatio: CGFloat = 4.0 / 3.0
    /// 贴纸舞台的高度与贴纸边长：列表卡 / 编辑页
    static let listStageHeight: CGFloat = 148
    static let listStickerSize: CGFloat = 118
    static let editorStageHeight: CGFloat = 232
    static let editorStickerSize: CGFloat = 196
}

enum ThoughtHeroPhotoLayout {
    /// 通栏比例 = 照片自身比例夹进 [4:3, 16:9]；像素尺寸未到按 4:3（01 §6.2 照片头图容器）。
    /// 大字号下压到最扁一档，把屏幕让给正文（01 §9）。
    static func bandRatio(pixelWidth: Int, pixelHeight: Int, shrinksForLargeText: Bool) -> CGFloat {
        if shrinksForLargeText { return ThoughtHeroMetrics.widestBandRatio }
        guard pixelWidth > 0, pixelHeight > 0 else { return ThoughtHeroMetrics.tallestBandRatio }
        let ratio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        return min(max(ratio, ThoughtHeroMetrics.tallestBandRatio), ThoughtHeroMetrics.widestBandRatio)
    }
}

/// 头图通栏外形：列表卡顶部只圆上面两角（接卡片圆角），编辑页的独立块四角都圆
struct ThoughtHeroBandShape: Shape {
    let cornerRadius: CGFloat
    let roundsBottomCorners: Bool

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: roundsBottomCorners ? cornerRadius : 0,
            bottomTrailingRadius: roundsBottomCorners ? cornerRadius : 0,
            topTrailingRadius: cornerRadius,
            style: .continuous
        ).path(in: rect)
    }
}

// MARK: - 头图块

/// 照片头图通栏：宽度铺满宿主，高度由比例决定；照片铺满并裁掉溢出部分
struct ThoughtHeroPhotoBand: View {
    let descriptor: VisualDescriptor
    let role: VisualRenderRole
    var roundsBottomCorners = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let ratio = ThoughtHeroPhotoLayout.bandRatio(
            pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight,
            shrinksForLargeText: dynamicTypeSize.isAccessibilitySize
        )
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                VisualAssetView(descriptor: descriptor, role: role, contentMode: .fill)
                    .allowsHitTesting(false)
            }
            .clipShape(ThoughtHeroBandShape(cornerRadius: HoloRadius.lg, roundsBottomCorners: roundsBottomCorners))
            .contentShape(Rectangle())
    }
}

/// 贴纸舞台：纸色向淡色衬底过渡的横条托住贴纸，底边一条细线接到正文（原型 .tc-visual）
struct ThoughtHeroStickerStage: View {
    let descriptor: VisualDescriptor
    let role: VisualRenderRole
    let style: ThoughtStyle
    let height: CGFloat
    let stickerSize: CGFloat
    var roundsBottomCorners = false
    /// 通栏贴卡片顶边时画底边细线；编辑页的独立圆角块不画
    var showsBottomRule = true

    var body: some View {
        ZStack {
            LinearGradient(colors: [style.listPaper, Color.holoToolInset],
                           startPoint: .top, endPoint: .bottom)
            VisualPlacementView(placement: .assetReady(descriptor), role: role)
                .frame(width: stickerSize, height: stickerSize)
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if showsBottomRule {
                Rectangle().fill(style.listBorder).frame(height: 0.5)
            }
        }
        .clipShape(ThoughtHeroBandShape(cornerRadius: HoloRadius.lg, roundsBottomCorners: roundsBottomCorners))
        .contentShape(Rectangle())
    }
}

// MARK: - 列表卡 / 编辑页入口

/// 列表卡的头图通栏（贴卡片顶边，不进卡片内边距）；未就绪的头图整段折叠
struct ThoughtHeroListPreview: View {
    let placement: ResolvedPlacement
    let style: ThoughtStyle
    /// 点头图与点正文走同一入口；不传则头图不响应点击
    var onOpen: (() -> Void)? = nil

    /// 头图是否在卡片里占位（决定纸面的顶部内边距）
    static func occupiesSpace(_ placement: ResolvedPlacement) -> Bool {
        if case .assetReady = placement { return true }
        return false
    }

    /// 是否是照片通栏：纸张装饰只画在它下方的纸面，不压到照片上
    static func isPhotoBand(_ placement: ResolvedPlacement) -> Bool {
        if case .assetReady(let descriptor) = placement { return descriptor.kind == .photo }
        return false
    }

    var body: some View {
        if case .assetReady(let descriptor) = placement {
            if let onOpen {
                Button(action: onOpen) {
                    band(descriptor).accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "头图"))
                .accessibilityHint(String(localized: "轻点编辑这条想法"))
            } else {
                band(descriptor).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func band(_ descriptor: VisualDescriptor) -> some View {
        switch descriptor.kind {
        case .photo:
            ThoughtHeroPhotoBand(descriptor: descriptor, role: .list, roundsBottomCorners: false)
        case .sticker:
            ThoughtHeroStickerStage(descriptor: descriptor, role: .list, style: style,
                                    height: ThoughtHeroMetrics.listStageHeight,
                                    stickerSize: ThoughtHeroMetrics.listStickerSize)
        }
    }
}

/// 编辑页的头图块（左右各留内容边距）：照片通栏与列表同一套比例规则，贴纸站舞台
struct ThoughtHeroView: View {
    let placement: ResolvedPlacement
    let style: ThoughtStyle

    var body: some View {
        if case .assetReady(let descriptor) = placement {
            Group {
                switch descriptor.kind {
                case .photo:
                    ThoughtHeroPhotoBand(descriptor: descriptor, role: .hero)
                case .sticker:
                    ThoughtHeroStickerStage(descriptor: descriptor, role: .hero, style: style,
                                            height: ThoughtHeroMetrics.editorStageHeight,
                                            stickerSize: ThoughtHeroMetrics.editorStickerSize,
                                            roundsBottomCorners: true,
                                            showsBottomRule: false)
                }
            }
            .padding(.horizontal, ThoughtLayout.contentInset)
        }
        // 无头图：整段折叠，不留空白占位（01 §6.2）
    }
}
