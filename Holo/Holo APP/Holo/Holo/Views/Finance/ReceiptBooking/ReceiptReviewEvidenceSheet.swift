//
//  ReceiptReviewEvidenceSheet.swift
//  Holo
//
//  复核确认页 · 两个弹层（2026-11-11 重设计，弹层语言照设计规范 §8.8）：
//  原图弹层——原图从页面内嵌块改弹层，看完关掉页面位置不动；
//  日期弹层——日期从常驻控件改「chip 点开弹层」（复核场景日期基本不用改）。
//

import SwiftUI

/// 原图弹层：统一 HoloSheetScaffold 壳（左上 X 圆钮 + 标题 + 拖拽条）、支持双指缩放与双击放大、底部暂存脚注
struct ReceiptReviewEvidenceSheet: View {
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "凭证原图"),
            onClose: { dismiss() }
        ) {
            VStack(spacing: 0) {
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        platformImage(image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .gesture(magnificationGesture)
                            .onTapGesture(count: 2) {
                                withAnimation(HoloAnimation.standard) {
                                    scale = scale > 1.05 ? 1 : 2.2
                                    lastScale = scale
                                }
                            }
                    }
                } else {
                    ContentUnavailableView(
                        "原图已清理",
                        systemImage: "photo",
                        description: Text("暂存的凭证原图已不存在。")
                    )
                }

                Text("仅在本机暂存，确认或删除后自动清理")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .presentationDetents([.large])
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    private func platformImage(_ image: UIImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

/// 日期弹层：统一 HoloSheetScaffold 壳（左上 X 放弃修改 + 居中标题 + 右上「今天」+ 贴底「完成」主按钮），
/// 内部 ScrollView 兜底 6 行月份与大号字体，不再挤压标题或裁切按钮。
struct ReceiptReviewDatePickerSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss

    @State private var draftDate: Date

    init(date: Binding<Date>) {
        self._date = date
        self._draftDate = State(initialValue: date.wrappedValue)
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "记账日期"),
            onClose: { dismiss() },
            trailingTitle: String(localized: "今天"),
            trailingAction: {
                withAnimation(HoloAnimation.standard) {
                    draftDate = Date()
                }
            },
            primaryTitle: String(localized: "完成"),
            primaryAction: {
                date = draftDate
                dismiss()
            },
            footerShowsDivider: false
        ) {
            ScrollView {
                DatePicker("", selection: $draftDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDetents([.height(520), .large])
    }
}
