//
//  PolaroidMomentCard.swift
//  Holo
//
//  册页风想法卡片（记忆长廊·日回放）：带图想法以「冲印照片贴册页」呈现——
// 白边、微旋转、层叠错落；3 张以上盖一枚印章计数；照片堆支持横向滑动翻片，
// 顶片跟手偏移、松手弹性翻层。整卡轻点跳转想法详情页（长廊不设想法详情弹层）。
//
// 翻片秩序口径（2026-10-02 东林反馈「全堆跟着动、乱」重做）：
// 照片堆为**槽位固定制**——顶/右/左/右下四个槽位的位移、缩放、角度恒定，
// 槽位内容按片序队列轮换（photos[(topIndex+slot)%count]）。翻片时旧顶片沿
// 手势方向飞出、新顶片淡入补位，其余槽位原位交叉淡换、零位移——
// 全程只有一张照片在移动（此前 depth 重排会让全堆一起弹动）。
//
// 性能口径（多图卡翻片掉帧专项）：
// ① 槽位天然 ≤4 个——更深层与前槽完全重合、被整张盖住，渲染纯属浪费；
// ② 阴影分层——只有顶槽付双层阴影、次槽一层轻阴影，更深层被盖住阴影不可见；
// ③ 槽位参数恒定 + Equatable 子视图，拖片时 SwiftUI 跳过静止槽位 body；
// ④ 解码走 AttachmentImageLoader 共享缓存，真解码在后台、像素就绪才上屏。
//

import SwiftUI

struct PolaroidMomentCard: View {
    let moment: DailyReplayMoment
    let onSelect: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 宽屏档新增文本元素排印放大（与无图时刻卡同口径，iPhone 不变）
    @Environment(\.holoContentWidth) private var textWindowWidth
    private var typeScale: CGFloat { HoloAdaptiveLayout.galleryTypeScale(forWindowWidth: textWindowWidth) }
    @State private var topIndex: Int = 0
    @State private var dragX: CGFloat = 0
    /// 最近一次翻片方向：决定旧顶片飞出的边（左滑看下一张 → 向左飞出）
    @State private var lastSwipeLeft = true
    @State private var decodedImages: [UIImage?] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(moment: DailyReplayMoment, onSelect: @escaping () -> Void) {
        self.moment = moment
        self.onSelect = onSelect
    }

    private var photos: [Data] {
        moment.events.first(where: { !$0.attachmentThumbnails.isEmpty })?.attachmentThumbnails ?? []
    }

    /// iPad 的时间线卡片更宽，多图照片堆同步放大，避免沿用 iPhone 尺寸后在大屏上失去焦点。
    private var galleryScale: CGFloat {
        horizontalSizeClass == .regular ? 1.45 : 1
    }

    // MARK: - 册页几何（槽位姿态恒定：同一想法每次渲染、每次翻片姿态都一致，不做随机）

    /// 冲印照片的基础旋转（度），按槽位取用；单图时用更轻的 1.6°
    private static let baseAngles: [Double] = [-3.2, 2.6, -1.0, 4.2, -2.4, 1.8, -4.0, 2.2, -1.5]

    private var photoWidth: CGFloat {
        switch photos.count {
        case 1: return 234 * galleryScale
        case 2: return 168 * galleryScale
        default: return 196 * galleryScale
        }
    }

    private var photoHeight: CGFloat {
        switch photos.count {
        case 1: return 184 * galleryScale
        case 2: return 148 * galleryScale
        default: return 156 * galleryScale
        }
    }

    /// 槽位姿态（恒定，与内容无关）：slot 0 为顶槽；双片左右分立，
    /// 多片时呈「左中右」三列阶梯展开。错位幅度吃满卡片两侧留白——
    /// 叠得太拢时后片会被顶片完全盖住，照片糊成一摞。
    private func slotPlacement(_ slot: Int) -> (dx: CGFloat, dy: CGFloat, scale: CGFloat) {
        let factor = galleryScale
        if photos.count == 2 {
            switch slot {
            case 0: return (-52 * factor, 4 * factor, 1)
            default: return (52 * factor, -6 * factor, 0.97)
            }
        }
        switch slot {
        case 0:  return (-8 * factor, 0, 1)
        case 1:  return (58 * factor, 12 * factor, 0.93)
        case 2:  return (-56 * factor, 20 * factor, 0.89)
        default: return (62 * factor, 28 * factor, 0.85)
        }
    }

    private func slotAngle(_ slot: Int) -> Double {
        if photos.count == 1 { return 1.6 }
        return Self.baseAngles[slot % Self.baseAngles.count]
    }

    /// 照片堆槽位数：更深层与前槽完全重合、物理不可见，最多 4 槽（见文件头性能口径①）。
    private var slotCount: Int { min(photos.count, 4) }

    /// 槽位当前显示的片序：内容按队列推进，槽位本身永不移动。
    private func photoIndex(forSlot slot: Int) -> Int {
        (topIndex + slot) % photos.count
    }

    // MARK: -

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerLine
            photoStack
            caption
            if needsFullTextHint {
                Text("轻点查看全文")
                    .font(.system(size: 10 * typeScale, weight: .medium))
                    .foregroundColor(.holoPrimary.opacity(0.85))
                    .padding(.horizontal, 4)
            }
            if let context = moment.contextText, !context.isEmpty {
                Text(context)
                    .font(.system(size: 11 * typeScale, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }
            if moment.events.count > 1 {
                groupedRecords
            }
            if let topics = moment.events.first?.relatedTopics, !topics.isEmpty {
                topicLine(topics)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .sensoryFeedback(.selection, trigger: topIndex)
        .task(id: moment.photoRevision) {
            await decodePhotos()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(String(localized: "第 \(topIndex + 1) 张，共 \(photos.count) 张"))
        .accessibilityIdentifier("daily.replay.photo.\(moment.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "轻点打开想法详情，左右滑动切换照片"))
    }

    /// 解码进共享缓存：先同步探测（滚动回位时当帧全部命中，不闪占位），
    /// 未命中的逐张后台强制解码、到一张显一张。
    private func decodePhotos() async {
        guard !photos.isEmpty else { decodedImages = []; return }
        topIndex = min(topIndex, photos.count - 1)
        var images = photos.map { AttachmentImageLoader.cachedThumbnail(for: $0) }
        decodedImages = images
        for (index, data) in photos.enumerated() where images[index] == nil {
            guard !Task.isCancelled else { return }
            images[index] = await AttachmentImageLoader.decodedThumbnail(from: data)
            guard !Task.isCancelled else { return }
            decodedImages = images
        }
    }

    private func image(at index: Int) -> UIImage? {
        if decodedImages.indices.contains(index), let image = decodedImages[index] {
            return image
        }
        guard photos.indices.contains(index) else { return nil }
        return AttachmentImageLoader.cachedThumbnail(for: photos[index])
    }

    private var accessibilityText: String {
        var parts = [String(localized: "想法"), moment.timeText, moment.title]
        if photos.count > 1 { parts.append(String(localized: "共 \(photos.count) 张照片")) }
        return parts.joined(separator: "，")
    }

    // MARK: - 照片堆

    private var photoStack: some View {
        ZStack {
            ForEach(0..<slotCount, id: \.self) { slot in
                polaroid(slot: slot)
            }
            if photos.count > 2 {
                sealStamp
            }
        }
        .frame(height: photoHeight + 46 * galleryScale)
        .frame(maxWidth: .infinity)
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    guard photos.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    let threshold: CGFloat = 56
                    let passed = photos.count > 1 && abs(value.translation.width) >= threshold
                        && abs(value.translation.width) > abs(value.translation.height)
                    if passed {
                        lastSwipeLeft = value.translation.width < 0
                    }
                    // 翻片秩序：槽位恒定、内容轮换——顶片沿手势方向飞出、新顶片淡入
                    // 补位，其余槽位原位交叉淡换，全程只有一张照片在移动。
                    withAnimation(reduceMotion ? nil : HoloAnimation.grounded) {
                        if passed {
                            topIndex = lastSwipeLeft
                                ? (topIndex + 1) % photos.count
                                : (topIndex - 1 + photos.count) % photos.count
                        }
                        dragX = 0
                    }
                }
        )
    }

    private func polaroid(slot: Int) -> some View {
        let index = photoIndex(forSlot: slot)
        let placement = slotPlacement(slot)
        let dragDx: CGFloat = slot == 0 ? dragX : 0
        return PolaroidLayer(
            image: image(at: index),
            size: CGSize(width: photoWidth, height: photoHeight),
            dx: placement.dx + dragDx,
            dy: placement.dy + dragDx * 0.05,
            scale: placement.scale,
            angle: slotAngle(slot) + Double(dragDx) * 0.018,
            shadow: slot == 0 ? .top : (slot == 1 ? .mid : .none),
            zIndex: Double(100 - slot)
        )
        .equatable()
        // 槽位内容身份：翻片时槽内照片轮换 → 旧照移除/新照插入按 transition 过渡；
        // 拖片时槽位与片序都不变，不触发 transition。
        .id("slot\(slot)-photo\(index)")
        .transition(slot == 0 ? topSlotTransition : .opacity)
    }

    /// 顶槽过渡：新顶片淡入补位，旧顶片沿翻片方向飞出。
    private var topSlotTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .move(edge: lastSwipeLeft ? .leading : .trailing)
                .combined(with: .opacity)
        )
    }

    // MARK: - 印章（3 张以上才盖章）

    private var sealStamp: some View {
        VStack(spacing: 0) {
            Text("\(photos.count)")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundColor(.holoSealRed)
            Text("张")
                .font(.system(size: 7.5, weight: .medium))
                .foregroundColor(.holoSealRed.opacity(0.85))
                .tracking(2)
        }
        .frame(width: 34, height: 34)
        .background(Color.holoPaper.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.holoSealRed.opacity(0.55), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .rotationEffect(.degrees(6))
        .offset(x: 4, y: -2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(200)
        .allowsHitTesting(false)
    }

    // MARK: - 文字

    /// 册页卡信息行（A 案）：徽章独立行，与无图时刻卡第一行同构——
    /// 有图/无图想法展示的信息字段完全一致，照片只是多出的一块内容。
    private var headerLine: some View {
        HStack(spacing: HoloSpacing.sm) {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10 * typeScale, weight: .semibold))
                Text(String(localized: "想法"))
                    .font(.system(size: 10 * typeScale, weight: .bold))
            }
            .foregroundColor(moment.module.color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(moment.module.color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Spacer(minLength: 0)
            if let count = moment.recordCountText {
                Text(count)
                    .font(.system(size: 10 * typeScale, weight: .medium))
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
        .padding(.horizontal, 4)
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(moment.title)
                .font(.system(size: 14.5, weight: .semibold, design: .serif))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                // 与无图时刻卡同一行数口径；超长时下方给「轻点查看全文」提示。
                .lineLimit(6)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 6)
            Text(moment.timeText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.holoTextSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
    }

    /// 判定与无图卡同源（DailyReplayPresentation.thoughtNeedsFullTextHint）。
    /// 字号按 caption 实际渲染字号 14.5；宽度 = 屏宽 − 页边距 − caption 内边距。
    private var needsFullTextHint: Bool {
        DailyReplayPresentation.thoughtNeedsFullTextHint(
            moment.title,
            lines: 6,
            fontSize: 14.5,
            availableWidth: UIScreen.main.bounds.width - 2 * HoloSpacing.md - 8
        )
    }

    /// 多条时刻明细：与无图时刻卡同构（想法不走习惯胶囊分支）。
    private var groupedRecords: some View {
        VStack(spacing: 7) {
            ForEach(Array(moment.events.prefix(4))) { event in
                HStack(spacing: HoloSpacing.sm) {
                    Text(event.title)
                        .lineLimit(1)
                    Spacer(minLength: HoloSpacing.sm)
                    if let detail = event.detail {
                        Text(detail)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10 * typeScale, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            }
            if moment.events.count > 4 {
                Text("另有 \(moment.events.count - 4) 条")
                    .font(.system(size: 10 * typeScale, weight: .medium))
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.holoBorder.opacity(0.42))
                .frame(height: 1)
        }
        .padding(.horizontal, 4)
    }

    private func topicLine(_ topics: [String]) -> some View {
        Text(topics.prefix(3).map { "#\($0)" }.joined(separator: " · "))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.holoTextSecondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }
}

// MARK: - 单层冲印照片（白边 + 分层阴影，静止层可跳过重算）

/// 拖片时只有顶片携带 dragX，静止层的全部参数不变——Equatable 判等后
/// SwiftUI 直接跳过它们的 body 重算与重绘，每帧只剩顶片一层在动。
private struct PolaroidLayer: View, Equatable {
    enum ShadowTier {
        case top
        case mid
        case none
    }

    let image: UIImage?
    let size: CGSize
    let dx: CGFloat
    let dy: CGFloat
    let scale: CGFloat
    let angle: Double
    let shadow: ShadowTier
    let zIndex: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        // UIImage 按引用判等：解码结果实例稳定（共享缓存/卡内 @State 均如此）
        lhs.image === rhs.image
            && lhs.size == rhs.size
            && lhs.dx == rhs.dx && lhs.dy == rhs.dy
            && lhs.scale == rhs.scale
            && lhs.angle == rhs.angle
            && lhs.shadow == rhs.shadow
            && lhs.zIndex == rhs.zIndex
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.holoNestedCardBackground)
            }
        }
        .frame(width: size.width - 12, height: size.height - 12)
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .padding(6)
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadowTier(shadow)
        .scaleEffect(scale)
        .offset(x: dx, y: dy)
        .rotationEffect(.degrees(angle))
        .zIndex(zIndex)
    }
}

private extension View {
    /// 阴影分层：整堆只保留顶片双层 + 次片一层轻阴影，更深层被前层盖住、
    /// 阴影不可见，不再为它们付逐帧合成成本（原为每层双阴影）。
    @ViewBuilder
    func shadowTier(_ tier: PolaroidLayer.ShadowTier) -> some View {
        switch tier {
        case .top:
            self.shadow(color: Color.black.opacity(0.09), radius: 4, x: 0, y: 3)
                .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 8)
        case .mid:
            self.shadow(color: Color.black.opacity(0.09), radius: 4, x: 0, y: 3)
        case .none:
            self
        }
    }
}
