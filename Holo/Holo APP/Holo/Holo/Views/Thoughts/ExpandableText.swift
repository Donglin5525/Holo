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
///
/// 支持两种内容源：
/// - 纯文本（String）：无样式高亮
/// - 结构化节点（[HoloContentNode]）：# 标签 / @ 引用 Token 渲染为橙字 + 橙底（与详情页样式一致）
struct ExpandableText: View {

    // MARK: - 配置

    /// 渲染用的属性字符串（纯文本模式为无属性的 AttributedString）
    private let attributedText: AttributedString
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

    // MARK: - 初始化

    /// 纯文本初始化器（向后兼容）
    init(text: String, lineLimit: Int = 5, font: Font = .holoBody, color: Color = .holoTextPrimary, lineSpacing: CGFloat = 8) {
        self.attributedText = AttributedString(text)
        self.lineLimit = lineLimit
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
    }

    /// 结构化节点初始化器：#/@ Token 渲染为橙字 + 橙底高亮
    /// - Parameter nodes: 富文本节点（text / tag / reference）
    init(nodes: [HoloContentNode], lineLimit: Int = 5, font: Font = .holoBody, color: Color = .holoTextPrimary, lineSpacing: CGFloat = 8) {
        self.attributedText = Self.makeAttributedText(from: nodes, font: font, textColor: color)
        self.lineLimit = lineLimit
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributedText)
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
        Text(attributedText)
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
        Text(attributedText)
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

    // MARK: - 节点 → AttributedString

    /// 把结构化节点转为 SwiftUI AttributedString：
    /// - text 节点：去掉 Markdown 格式标记（**、++ 等），与改前 plainContent 口径一致，避免星号等标记外露
    /// - tag / reference Token：橙字 + 浅橙底（色值与详情页 MarkdownTextView.makeTokenAttributedText 一致）
    /// 之所以不直接复用 UIKit 的 NSAttributedString，是因为目标是 SwiftUI Text，
    /// 用 SwiftUI 原生 AttributeScopes 才能保证 backgroundColor run 正确渲染。
    private static func makeAttributedText(from nodes: [HoloContentNode], font: Font, textColor: Color) -> AttributedString {
        var result = AttributedString()
        let tokenForegroundColor = Color.holoPrimary
        let tokenBackgroundColor = Color.holoPrimary.opacity(0.12)

        for node in nodes {
            switch node {
            case .text(let value):
                // 卡片预览态不渲染 Markdown 样式，扒掉格式标记（与 plainContent 一致）
                let plain = MarkdownParser.stripFormatting(value)
                var segment = AttributedString(plain)
                segment.foregroundColor = textColor
                segment.font = font
                result += segment

            case .tag(_, let displayPath):
                var segment = AttributedString("#\(displayPath)")
                segment.foregroundColor = tokenForegroundColor
                segment.backgroundColor = tokenBackgroundColor
                segment.font = font
                result += segment

            case .reference(_, let displayText, _):
                var segment = AttributedString("@\(displayText)")
                segment.foregroundColor = tokenForegroundColor
                segment.backgroundColor = tokenBackgroundColor
                segment.font = font
                result += segment
            }
        }

        return result
    }
}
