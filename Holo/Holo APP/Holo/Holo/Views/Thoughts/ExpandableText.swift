//
//  ExpandableText.swift
//  Holo
//
//  通用组件 - 可展开/收起的自适应文本
//  根据实际渲染高度判断截断，不依赖固定字符数
//

import SwiftUI

// MARK: - ExpandableText

/// 支持行数自适应截断 + 展开/收起的文本组件
///
/// 工作原理：
/// 1. 两个不可见的测量视图分别计算「完整文本高度」和「限行文本高度」
/// 2. 比较两者判断是否溢出
/// 3. 溢出时显示「展开」按钮，展开后显示「收起」按钮
struct ExpandableText: View {

    // MARK: - 配置

    let text: String
    var lineLimit: Int = 5
    var font: Font = .holoBody
    var color: Color = .holoTextPrimary
    var lineSpacing: CGFloat = 8

    // MARK: - 状态

    @State private var isExpanded = false
    @State private var fullTextHeight: CGFloat = 0
    @State private var limitedTextHeight: CGFloat = 0

    /// 浮点数比较容差
    private static let heightTolerance: CGFloat = 1

    /// 文本是否超出限定行数
    private var isOverflowing: Bool {
        fullTextHeight > limitedTextHeight + Self.heightTolerance
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineSpacing(lineSpacing)
                .lineLimit(isExpanded ? nil : lineLimit)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fullHeightMeasurement)
                .background(limitedHeightMeasurement)

            if isOverflowing {
                toggleButton
            }
        }
    }

    // MARK: - 展开/收起按钮

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            Text(isExpanded ? "收起" : "展开")
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
        }
    }

    // MARK: - 高度测量

    /// 测量文本无行数限制时的完整高度
    private var fullHeightMeasurement: some View {
        Text(text)
            .font(font)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        fullTextHeight = geo.size.height
                    }
                }
            )
    }

    /// 测量文本在指定行数限制下的高度
    private var limitedHeightMeasurement: some View {
        Text(text)
            .font(font)
            .lineSpacing(lineSpacing)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        limitedTextHeight = geo.size.height
                    }
                }
            )
    }
}
