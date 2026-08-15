//
//  ReadOnlyRichTextView.swift
//  Holo
//
//  观点模块 - 阅读态结构化内容渲染
//  复用编辑器节点管线（只读），支持 # 标签 / @ 引用 Token 点击
//

import SwiftUI
import UIKit

// MARK: - ReadOnlyRichTextView

/// 阅读态富文本：渲染 ContentNode（含 Token），点击 Token 回调
struct ReadOnlyRichTextView: UIViewRepresentable {

    @Environment(\.sizeCategory) private var sizeCategory

    let nodes: [HoloContentNode]
    /// 目标已删除的引用 ID 集合（灰色「原记录已删除」样式）
    var deletedReferenceIds: Set<UUID> = []
    /// Token 点击回调（标签 → 筛选列表；引用 → 打开目标/快照）
    var onTokenTap: (HoloContentNode) -> Void
    /// 卡片等预览场景可限制最大行数；详情页传 nil 展示全文。
    var lineLimit: Int? = nil
    /// 卡片预览不接管点击，让外层卡片继续作为整体入口。
    var allowsTokenInteraction: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownTextView.makeTaskAwareTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = lineLimit ?? 0
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.isUserInteractionEnabled = allowsTokenInteraction
        // 禁用系统「自动填充」与 Writing Tools，避免点按 Token 时弹出系统菜单
        if #available(iOS 18.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        textView.attributedText = MarkdownTextView.makeAttributedText(from: nodes, deletedReferenceIds: deletedReferenceIds)
        textView.accessibilityLabel = "想法内容"
        textView.accessibilityValue = MarkdownTextView.accessibilityText(from: nodes)
        textView.accessibilityCustomActions = allowsTokenInteraction
            ? context.coordinator.accessibilityActions(for: nodes)
            : nil
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.lastSizeCategory = sizeCategory

        if allowsTokenInteraction {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            textView.addGestureRecognizer(tap)
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let rendered = MarkdownTextView.makeAttributedText(from: nodes, deletedReferenceIds: deletedReferenceIds)
        textView.textContainer.maximumNumberOfLines = lineLimit ?? 0
        textView.isUserInteractionEnabled = allowsTokenInteraction
        let sizeCategoryChanged = context.coordinator.lastSizeCategory != sizeCategory
        if sizeCategoryChanged || !textView.attributedText.isEqual(to: rendered) {
            textView.attributedText = rendered
        }
        textView.accessibilityLabel = "想法内容"
        textView.accessibilityValue = MarkdownTextView.accessibilityText(from: nodes)
        textView.accessibilityCustomActions = allowsTokenInteraction
            ? context.coordinator.accessibilityActions(for: nodes)
            : nil
        context.coordinator.lastSizeCategory = sizeCategory
        context.coordinator.onTokenTap = onTokenTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTokenTap: onTokenTap)
    }

    /// 让 SwiftUI 按当前实际宽度向 UIKit 要求完整排版高度。
    ///
    /// 只依赖 UITextView 的 intrinsicContentSize 在 Dynamic Type 或富文本节点变化后
    /// 不稳定：首次布局拿到的高度可能被复用，导致大字号/空行的后半段跑到卡片边界外。
    /// 这里把宽度作为唯一输入，交给 UITextView 的真实排版引擎计算高度，保证列表、详情
    /// 与字号变化后的阅读容器始终包住可见正文。
    @available(iOS 16.0, *)
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }

        let fittedSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fittedSize.height))
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTokenTap: (HoloContentNode) -> Void
        var lastSizeCategory: ContentSizeCategory?

        init(onTokenTap: @escaping (HoloContentNode) -> Void) {
            self.onTokenTap = onTokenTap
        }

        /// 为每个行内关系提供 VoiceOver 可执行动作；正文仍保持单一连续朗读顺序。
        func accessibilityActions(for nodes: [HoloContentNode]) -> [UIAccessibilityCustomAction] {
            nodes.compactMap { node in
                let name: String
                switch node {
                case .tag(_, let displayPath):
                    name = "筛选标签 #\(displayPath)"
                case .reference(_, let displayText, _):
                    name = "打开引用 @\(displayText)"
                case .taskMark(_, _, let displayText, _):
                    name = displayText.isEmpty ? "打开任务" : "打开任务：\(displayText)"
                case .text:
                    return nil
                }

                return UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    self?.onTokenTap(node)
                    return true
                }
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView,
                  let position = textView.closestPosition(to: gesture.location(in: textView)) else { return }

            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard offset < textView.attributedText.length else { return }

            let attributes = textView.attributedText.attributes(at: offset, effectiveRange: nil)
            guard let node = MarkdownTextView.makeTokenNode(from: attributes) else { return }
            onTokenTap(node)
        }

        /// 命中 Token 时才接管点击（其余位置保留系统文字选择能力）
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView = gestureRecognizer.view as? UITextView,
                  let position = textView.closestPosition(to: touch.location(in: textView)) else { return false }

            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard offset < textView.attributedText.length else { return false }

            let attributes = textView.attributedText.attributes(at: offset, effectiveRange: nil)
            return attributes[.holoTokenType] != nil
        }
    }
}

// MARK: - ReadOnlyRichTextPreview

/// 列表卡片的只读正文预览。
///
/// 列表不承担全文阅读，避免长卡片把信息流撑成一篇篇详情；但截断必须可感知，
/// 否则用户会把预览误认为正文已经结束。这里用同一份富文本节点和同一套 UIKit
/// 排版测量判断是否超过行数，只在确实溢出时显示“点击查看全文”提示。
struct ReadOnlyRichTextPreview: View {

    @Environment(\.sizeCategory) private var sizeCategory

    let nodes: [HoloContentNode]
    var lineLimit: Int = 7

    @State private var availableWidth: CGFloat = 0
    @State private var isOverflowing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReadOnlyRichTextView(
                nodes: nodes,
                onTokenTap: { _ in },
                lineLimit: lineLimit,
                allowsTokenInteraction: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateWidth(proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            updateWidth(newWidth)
                        }
                }
            )

            if isOverflowing {
                HStack(spacing: 3) {
                    Text("点击查看全文")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
                .accessibilityHidden(true)
            }
        }
        .onAppear {
            updateOverflow()
        }
        .onChange(of: nodes) { _, _ in
            updateOverflow()
        }
        .onChange(of: lineLimit) { _, _ in
            updateOverflow()
        }
        .onChange(of: sizeCategory) { _, _ in
            // 正文会随 Dynamic Type 重新排版，溢出提示也必须同步重算，
            // 否则字号变大后可能出现“正文已截断但没有查看全文入口”。
            updateOverflow()
        }
    }

    private func updateWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        if abs(availableWidth - width) > 0.5 {
            availableWidth = width
            updateOverflow()
        }
    }

    private func updateOverflow() {
        guard availableWidth > 0, lineLimit > 0 else { return }
        isOverflowing = ReadOnlyRichTextLayoutMetrics.exceedsLineLimit(
            nodes: nodes,
            width: availableWidth,
            lineLimit: lineLimit
        )
    }
}

/// 用 UIKit 的真实 attributed text 计算完整排版与限行排版的高度差。
/// 不用字符数估算，中文、英文、Emoji、Markdown 和 Token 都沿用编辑器的实际字体与段落样式。
private enum ReadOnlyRichTextLayoutMetrics {

    static func exceedsLineLimit(
        nodes: [HoloContentNode],
        width: CGFloat,
        lineLimit: Int
    ) -> Bool {
        let attributedText = MarkdownTextView.makeAttributedText(from: nodes)
        guard attributedText.length > 0 else { return false }

        let fullHeight = measuredHeight(
            for: attributedText,
            width: width,
            maximumNumberOfLines: 0
        )
        let limitedHeight = measuredHeight(
            for: attributedText,
            width: width,
            maximumNumberOfLines: lineLimit
        )
        return fullHeight > limitedHeight + 1
    }

    private static func measuredHeight(
        for attributedText: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int
    ) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        if maximumNumberOfLines > 0 {
            textContainer.maximumNumberOfLines = maximumNumberOfLines
            textContainer.lineBreakMode = .byTruncatingTail
        } else {
            textContainer.lineBreakMode = .byWordWrapping
        }

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }
}
