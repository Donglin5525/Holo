//
//  PolaroidMomentCard.swift
//  Holo
//
//  册页风想法卡片（记忆长廊·日回放）：带图想法以「冲印照片贴册页」呈现——
// 白边、微旋转、层叠错落；3 张以上盖一枚印章计数；照片堆支持横向滑动翻片，
// 顶片跟手偏移、松手弹性翻层。整卡轻点跳转想法详情页（长廊不设想法详情弹层）。
//

import SwiftUI

struct PolaroidMomentCard: View {
    let moment: DailyReplayMoment
    let onSelect: () -> Void

    @State private var topIndex: Int = 0
    @State private var dragX: CGFloat = 0
    @State private var decodedImages: [UIImage?] = []

    init(moment: DailyReplayMoment, onSelect: @escaping () -> Void) {
        self.moment = moment
        self.onSelect = onSelect
    }

    private var photos: [Data] {
        moment.events.first(where: { !$0.attachmentThumbnails.isEmpty })?.attachmentThumbnails ?? []
    }

    // MARK: - 册页几何（角度为确定值：同一想法每次渲染姿态一致，不做随机）

    /// 冲印照片的基础旋转（度），按片序取用；顶片单图时用更轻的 1.6°
    private static let baseAngles: [Double] = [-3.2, 2.6, -1.0, 4.2, -2.4, 1.8, -4.0, 2.2, -1.5]

    private var photoWidth: CGFloat {
        switch photos.count {
        case 1: return 234
        case 2: return 168
        default: return 196
        }
    }

    private var photoHeight: CGFloat {
        switch photos.count {
        case 1: return 184
        case 2: return 148
        default: return 156
        }
    }

    /// 叠层姿态：depth 0 为顶片；双片左右分立，多片时顶片微偏左、右侧与左下各露一角
    private func placement(depth: Int, count: Int) -> (dx: CGFloat, dy: CGFloat, scale: CGFloat) {
        if count == 2 {
            switch depth {
            case 0: return (-46, 6, 1)
            default: return (46, -4, 0.97)
            }
        }
        switch depth {
        case 0:  return (-12, 0, 1)
        case 1:  return (52, 12, 0.93)
        case 2:  return (-48, 20, 0.89)
        default: return (56, 26, 0.85)
        }
    }

    private var angleForTop: Double {
        photos.count == 1 ? 1.6 : Self.baseAngles[topIndex % Self.baseAngles.count]
    }

    // MARK: -

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            photoStack
            caption
            if let topics = moment.events.first?.relatedTopics, !topics.isEmpty {
                topicLine(topics)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .sensoryFeedback(.selection, trigger: topIndex)
        .onAppear {
            guard decodedImages.isEmpty, !photos.isEmpty else { return }
            decodedImages = photos.map { UIImage(data: $0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点打开想法详情，左右滑动切换照片")
    }

    private var accessibilityText: String {
        var parts = ["想法", moment.timeText, moment.title]
        if photos.count > 1 { parts.append("共 \(photos.count) 张照片") }
        return parts.joined(separator: "，")
    }

    // MARK: - 照片堆

    private var photoStack: some View {
        ZStack {
            ForEach(Array(photos.indices), id: \.self) { index in
                polaroid(index: index)
            }
            if photos.count > 2 {
                sealStamp
            }
        }
        .frame(height: photoHeight + 40)
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    guard photos.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    let threshold: CGFloat = 56
                    let passed = photos.count > 1 && abs(value.translation.width) >= threshold
                        && abs(value.translation.width) > abs(value.translation.height)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                        if passed {
                            topIndex = value.translation.width < 0
                                ? (topIndex + 1) % photos.count
                                : (topIndex - 1 + photos.count) % photos.count
                        }
                        dragX = 0
                    }
                }
        )
    }

    private func polaroid(index: Int) -> some View {
        let count = photos.count
        let depth = (index - topIndex + count) % count
        let placement = placement(depth: depth, count: count)
        let isTop = depth == 0
        let angle = isTop ? angleForTop : Self.baseAngles[index % Self.baseAngles.count]
        let dragDx: CGFloat = isTop ? dragX : 0
        let dragAngle = Double(dragDx) * 0.018

        return PolaroidPhoto(
            image: decodedImages.indices.contains(index) ? decodedImages[index] : nil,
            width: photoWidth,
            height: photoHeight
        )
        .scaleEffect(placement.scale)
        .offset(x: placement.dx + dragDx,
                y: placement.dy + dragDx * 0.05)
        .rotationEffect(.degrees(angle + dragAngle))
        .zIndex(Double(100 - depth))
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
        .allowsHitTesting(false)
    }

    // MARK: - 文字

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(moment.title)
                .font(.system(size: 14.5, weight: .semibold, design: .serif))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 6)
            Text(moment.timeText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.holoTextSecondary)
                .monospacedDigit()
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

// MARK: - 单张冲印照片（白边 + 阴影）

private struct PolaroidPhoto: View {
    let image: UIImage?
    let width: CGFloat
    let height: CGFloat

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
        .frame(width: width - 12, height: height - 12)
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .padding(6)
        .frame(width: width, height: height)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: Color.black.opacity(0.09), radius: 4, x: 0, y: 3)
        .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 8)
    }
}
