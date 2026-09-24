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
        textView.accessibilityLabel = String(localized: "想法内容")
        textView.accessibilityValue = MarkdownTextView.accessibilityText(from: nodes)
        textView.accessibilityCustomActions = allowsTokenInteraction
            ? context.coordinator.accessibilityActions(for: nodes)
            : nil
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.lastSizeCategory = sizeCategory
        // 同步渲染输入缓存：首次 updateUIView 时若输入未变可整体跳过
        context.coordinator.syncRenderInputs(
            nodes: nodes,
            deletedReferenceIds: deletedReferenceIds,
            allowsTokenInteraction: allowsTokenInteraction
        )

        if allowsTokenInteraction {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            textView.addGestureRecognizer(tap)
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // 便宜的状态同步每次都做；贵的重建（attributedText 全量构建、
        // accessibility 文本/动作遍历）仅在渲染输入变化时执行。
        // 卡片上任意 @State 变化（如点「…」弹菜单）都会触发 updateUIView，
        // 长文的重建成本即列表卡顿主因。
        textView.textContainer.maximumNumberOfLines = lineLimit ?? 0
        textView.isUserInteractionEnabled = allowsTokenInteraction
        context.coordinator.onTokenTap = onTokenTap

        let sizeCategoryChanged = context.coordinator.lastSizeCategory != sizeCategory
        let inputsChanged = sizeCategoryChanged || !context.coordinator.hasSameRenderInputs(
            nodes: nodes,
            deletedReferenceIds: deletedReferenceIds,
            allowsTokenInteraction: allowsTokenInteraction
        )
        guard inputsChanged else { return }

        let rendered = MarkdownTextView.makeAttributedText(from: nodes, deletedReferenceIds: deletedReferenceIds)
        textView.attributedText = rendered
        textView.accessibilityLabel = String(localized: "想法内容")
        textView.accessibilityValue = MarkdownTextView.accessibilityText(from: nodes)
        textView.accessibilityCustomActions = allowsTokenInteraction
            ? context.coordinator.accessibilityActions(for: nodes)
            : nil
        context.coordinator.lastSizeCategory = sizeCategory
        context.coordinator.syncRenderInputs(
            nodes: nodes,
            deletedReferenceIds: deletedReferenceIds,
            allowsTokenInteraction: allowsTokenInteraction
        )
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
        // 渲染输入缓存：nodes 等输入不变时跳过 updateUIView 的全量重建。
        // lineLimit 刻意不入键：attributedText 内容与行数无关，行数只是
        // textContainer 属性（updateUIView 每次同步），把卡片预览的展开/收起
        // 挡在全量重建之外，切换只触发一次 UIKit reflow。
        private var lastRenderedNodes: [HoloContentNode] = []
        private var lastDeletedReferenceIds: Set<UUID> = []
        private var lastAllowsTokenInteraction: Bool?

        init(onTokenTap: @escaping (HoloContentNode) -> Void) {
            self.onTokenTap = onTokenTap
        }

        func hasSameRenderInputs(
            nodes: [HoloContentNode],
            deletedReferenceIds: Set<UUID>,
            allowsTokenInteraction: Bool
        ) -> Bool {
            lastRenderedNodes == nodes
                && lastDeletedReferenceIds == deletedReferenceIds
                && lastAllowsTokenInteraction == allowsTokenInteraction
        }

        func syncRenderInputs(
            nodes: [HoloContentNode],
            deletedReferenceIds: Set<UUID>,
            allowsTokenInteraction: Bool
        ) {
            lastRenderedNodes = nodes
            lastDeletedReferenceIds = deletedReferenceIds
            lastAllowsTokenInteraction = allowsTokenInteraction
        }

        /// 为每个行内关系提供 VoiceOver 可执行动作；正文仍保持单一连续朗读顺序。
        func accessibilityActions(for nodes: [HoloContentNode]) -> [UIAccessibilityCustomAction] {
            nodes.compactMap { node in
                let name: String
                switch node {
                case .tag(_, let displayPath):
                    name = String(localized: "筛选标签 #\(displayPath)")
                case .reference(_, let displayText, _):
                    name = String(localized: "打开引用 @\(displayText)")
                case .taskMark(_, _, let displayText, _):
                    name = displayText.isEmpty ? String(localized: "打开任务") : String(localized: "打开任务：\(displayText)")
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
    /// 收起态压掉空白行（预览行数配额让给有效文字）；展开态还原原文格式。
    /// 列表卡片传 true；需要忠实原文格式的预览场景保持 false。
    var compressesBlankLines: Bool = false

    @State private var availableWidth: CGFloat = 0
    @State private var isOverflowing = false
    // 展开态封闭在本组件内部：外层卡片（ThoughtContentBody 只依赖内容字符串）
    // 不感知这个状态，父级状态型重算依旧整体跳过正文；卡片滚出 LazyVStack
    // 即销毁，展开态随之复位，无驻留成本。
    @State private var isExpanded = false

    /// 收起态渲染用的节点（可含空行压缩）；展开态忠实还原原文。
    private var displayNodes: [HoloContentNode] {
        guard compressesBlankLines, !isExpanded else { return nodes }
        return RichContentSerializer.previewNodes(from: nodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReadOnlyRichTextView(
                nodes: displayNodes,
                onTokenTap: { _ in },
                lineLimit: isExpanded ? nil : lineLimit,
                allowsTokenInteraction: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    // 测宽用的透明占位必须禁命中：SwiftUI 的 Color.clear 默认可命中，
                    // 触摸穿透上方禁交互的 UITextView 后会被它截胡，正文点击（Button
                    // 命中链）整体失灵（2026-09-17 探针实证；同纪念日/报告收藏事故根因）
                    Color.clear
                        .allowsHitTesting(false)
                        .onAppear {
                            updateWidth(proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            updateWidth(newWidth)
                        }
                }
            )

            if isOverflowing {
                // 展开入口是独立 Button：嵌在外层正文 Button（进编辑页）的 label
                // 内，SwiftUI 内层 Button 优先命中，点这里原地展开、点正文其余
                // 区域仍进编辑页。
                Button {
                    withAnimation(HoloAnimation.standard) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(isExpanded ? String(localized: "收起") : String(localized: "点击查看全文"))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
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
        // 恒按收起态行数判定：isOverflowing = 内容超过预览行数上限，
        // 展开态不需要复判（按钮文案由 isExpanded 分流）。
        // 溢出对象是「收起态实际渲染的内容」：压缩空白行后行数变少，
        // 判定输入必须与 displayNodes 同源，否则会出现"截断已发生却判不溢出"。
        guard availableWidth > 0, lineLimit > 0 else { return }
        let judgingNodes = compressesBlankLines
            ? RichContentSerializer.previewNodes(from: nodes)
            : nodes
        isOverflowing = ReadOnlyRichTextLayoutMetrics.exceedsLineLimit(
            nodes: judgingNodes,
            width: availableWidth,
            lineLimit: lineLimit,
            sizeCategory: sizeCategory
        )
    }
}

/// 用与渲染同引擎的 attributed text 计算完整排版与限行排版的高度差。
/// 不用字符数估算，中文、英文、Emoji、Markdown 和 Token 都沿用编辑器的实际字体与段落样式。
/// 保持 internal（勿改回 private）——HoloTests 的 MarkdownTextViewNodePipelineTests
/// 依赖直接调用判定入口做回归（同 MarkdownTextView extension 先例）。
enum ReadOnlyRichTextLayoutMetrics {

    /// 溢出判定结果缓存：LazyVStack 卡片滚出即销毁、滚回即重建，onAppear 每次都重算；
    /// 全量 Markdown 构建 + 两次全文排版是 O(笔记长度) 的主线程重活（长文几十 ms），
    /// 而同一内容在同一宽度/行数/字号档下的溢出结论是确定的，直接命中缓存。
    private static let overflowCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 600
        return cache
    }()

    static func exceedsLineLimit(
        nodes: [HoloContentNode],
        width: CGFloat,
        lineLimit: Int,
        sizeCategory: ContentSizeCategory?
    ) -> Bool {
        let key = cacheKey(nodes: nodes, width: width, lineLimit: lineLimit, sizeCategory: sizeCategory)
        if let cached = overflowCache.object(forKey: key) {
            return cached.boolValue
        }

        let attributedText = MarkdownTextView.makeAttributedText(from: nodes)
        guard attributedText.length > 0 else {
            overflowCache.setObject(NSNumber(false), forKey: key)
            return false
        }

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
        let result = fullHeight > limitedHeight + 1
        overflowCache.setObject(NSNumber(value: result), forKey: key)
        return result
    }

    /// 与阅读态渲染同引擎的测量：离屏 UITextView（iOS 17+ 为 TextKit 2）。
    ///
    /// 此前的手动 NSLayoutManager 管线是 TextKit 1，与 UITextView（TextKit 2）
    /// 对中文折行的判定存在临界差：同一内容测量算 7 行整、渲染实际 8 行，
    /// 造成"正文已被截断、溢出提示却不出现"。测量必须与渲染同引擎才可信。
    /// 主线程专用（视图生命周期回调内调用）；结果经 overflowCache 缓存，频率低。
    private static let measuringTextView: UITextView = {
        let textView = UITextView(frame: .zero)
        textView.isScrollEnabled = false
        textView.backgroundColor = nil
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }()

    private static func measuredHeight(
        for attributedText: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int
    ) -> CGFloat {
        let textView = measuringTextView
        textView.attributedText = attributedText
        textView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        textView.textContainer.lineBreakMode = maximumNumberOfLines > 0
            ? .byTruncatingTail
            : .byWordWrapping
        let fitted = textView.sizeThatFits(
            CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        )
        return ceil(fitted.height)
    }

    /// 宽度按 1pt 取整成档（过滤亚像素抖动）；其余维度原样入键。
    private static func cacheKey(
        nodes: [HoloContentNode],
        width: CGFloat,
        lineLimit: Int,
        sizeCategory: ContentSizeCategory?
    ) -> NSString {
        var key = "\(Int(width.rounded()))|\(lineLimit)|\(sizeCategory.map(String.init(describing:)) ?? "-")|"
        for node in nodes {
            switch node {
            case .text(let value):
                key += "t\(value.utf16.count)|\(value)"
            case .tag(let id, let displayPath):
                key += "g\(id.uuidString)|\(displayPath)"
            case .reference(let noteId, let displayText, let snapshot):
                key += "r\(noteId.uuidString)|\(displayText.utf16.count)|\(displayText)|\(snapshot.utf16.count)|\(snapshot)"
            case .taskMark(let id, let taskId, let displayText, _):
                key += "k\(id.uuidString)|\(taskId.uuidString)|\(displayText.utf16.count)|\(displayText)"
            }
        }
        return key as NSString
    }
}
