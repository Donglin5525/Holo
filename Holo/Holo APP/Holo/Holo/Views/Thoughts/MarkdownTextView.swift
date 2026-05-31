//
//  MarkdownTextView.swift
//  Holo
//
//  观点模块 - Markdown 编辑器
//  编辑态使用富文本渲染，保存时再序列化回 markdown 文本
//

import SwiftUI
import UIKit

// MARK: - MarkdownEditorAction

/// 编辑器格式化动作
enum MarkdownEditorAction: Equatable {
    case toggleBold
    case insertUnorderedList
    case insertOrderedList
    case insertText(String)
}

// MARK: - TypingFormatState

/// 当前光标处的格式状态，用于工具栏按钮高亮反馈
struct TypingFormatState: Equatable {
    var isBold: Bool = false
}

// MARK: - MarkdownTextView

/// 支持 Markdown 编辑的文本视图
/// 编辑时展示富文本效果，底层仍使用 markdown 字符串存储
struct MarkdownTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var pendingAction: MarkdownEditorAction?
    /// 动态高度绑定，由视图自动计算并报告给父视图
    @Binding var dynamicHeight: CGFloat
    /// 当前光标处的格式状态，用于工具栏按钮高亮反馈
    @Binding var formatState: TypingFormatState

    /// 是否启用富文本渲染
    var showHighlight: Bool = true
    /// UIKit 文本容器内边距，便于外层悬浮按钮预留空间
    var textContainerInset: UIEdgeInsets = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)

    func makeUIView(context: Context) -> UITextView {
        let textView = SelfSizingTextView()
        textView.delegate = context.coordinator
        textView.font = Self.baseFont
        textView.textColor = Self.baseTextColor
        textView.backgroundColor = .clear
        textView.textContainerInset = textContainerInset
        // 初始启用滚动，SelfSizingTextView.layoutSubviews() 会根据内容与 frame 的关系动态切换
        // 内容不超出 frame 时自动禁用，让外层 SwiftUI ScrollView 接管滚动手势
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = true
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.keyboardType = .default
        textView.typingAttributes = Self.baseAttributes
        textView.attributedText = showHighlight ? Self.makeAttributedText(from: text) : NSAttributedString(string: text, attributes: Self.baseAttributes)

        context.coordinator.lastKnownMarkdown = text
        context.coordinator.onHeightChange = { height in
            DispatchQueue.main.async {
                self.dynamicHeight = height
            }
        }
        context.coordinator.onFormatStateChange = { state in
            DispatchQueue.main.async {
                self.formatState = state
            }
        }
        context.coordinator.refreshTypingAttributes(for: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if let action = pendingAction {
            pendingAction = nil
            context.coordinator.perform(action: action, on: textView, markdown: $text)
            return
        }

        if !context.coordinator.isProgrammaticChange,
           textView.markedTextRange == nil,
           text != context.coordinator.lastKnownMarkdown {
            let preservedSelection = Self.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let attributedText = showHighlight
                ? Self.makeAttributedText(from: text)
                : NSAttributedString(string: text, attributes: Self.baseAttributes)
            context.coordinator.isProgrammaticChange = true
            textView.attributedText = attributedText
            textView.selectedRange = Self.clampedRange(preservedSelection, for: attributedText.length)
            context.coordinator.isProgrammaticChange = false
            context.coordinator.lastKnownMarkdown = text
            context.coordinator.refreshTypingAttributes(for: textView)
        }

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        var isProgrammaticChange = false
        var lastKnownMarkdown: String = ""
        var onHeightChange: ((CGFloat) -> Void)?
        var onFormatStateChange: ((TypingFormatState) -> Void)?

        // 用户显式切换的加粗状态（Word-like sticky toggle）
        // nil = 无显式状态，走 contextual 推断
        // true = 强制开启，false = 强制关闭（覆盖 contextual）
        var explicitBold: Bool? = nil

        init(text: Binding<String>) {
            self._text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticChange else { return }
            guard textView.markedTextRange == nil else { return }
            syncMarkdown(from: textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            // 只处理回车键的列表续行逻辑
            guard text == "\n", !isProgrammaticChange else { return true }

            let currentText = textView.attributedText.string as NSString
            let cursorLocation = range.location

            // 找到当前行的起始位置
            var lineStart = 0
            if cursorLocation > 0 {
                let substring = currentText.substring(with: NSRange(location: 0, length: cursorLocation))
                if let lastNewline = substring.lastIndex(of: "\n") {
                    lineStart = substring.distance(from: substring.startIndex, to: lastNewline) + 1
                }
            }

            let lineLength = max(0, cursorLocation - lineStart)
            let currentLine = currentText.substring(with: NSRange(location: lineStart, length: lineLength))

            // 检测无序列表（支持 - * • 三种前缀）
            if let match = Self.listPrefixMatch(pattern: "^[\\-\\*\u{2022}] ", in: currentLine) {
                let contentAfterPrefix = String(currentLine.dropFirst(match.length)).trimmingCharacters(in: .whitespaces)

                // 空列表项：退出列表
                if contentAfterPrefix.isEmpty {
                    let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                    mutable.deleteCharacters(in: NSRange(location: lineStart, length: lineLength))
                    mutable.insert(NSAttributedString(string: "\n", attributes: textView.typingAttributes), at: lineStart)

                    isProgrammaticChange = true
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: lineStart + 1, length: 0)
                    isProgrammaticChange = false
                    syncMarkdown(from: textView)
                    return false
                }

                // 续行：插入新行 + 圆角点前缀
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                mutable.insert(NSAttributedString(string: "\n\u{2022} ", attributes: prefixAttrs), at: cursorLocation)

                isProgrammaticChange = true
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: cursorLocation + 3, length: 0)
                isProgrammaticChange = false
                syncMarkdown(from: textView)
                return false
            }

            // 检测有序列表
            if let match = Self.listPrefixMatch(pattern: "^(\\d+)\\. ", in: currentLine),
               match.numberValue != nil {
                let prefixEnd = currentLine.index(currentLine.startIndex, offsetBy: match.length, limitedBy: currentLine.endIndex) ?? currentLine.endIndex
                let contentAfterPrefix = String(currentLine[prefixEnd...]).trimmingCharacters(in: .whitespaces)

                if contentAfterPrefix.isEmpty {
                    let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                    mutable.deleteCharacters(in: NSRange(location: lineStart, length: lineLength))
                    mutable.insert(NSAttributedString(string: "\n", attributes: textView.typingAttributes), at: lineStart)

                    isProgrammaticChange = true
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: lineStart + 1, length: 0)
                    isProgrammaticChange = false
                    syncMarkdown(from: textView)
                    return false
                }

                let nextNumber = match.numberValue! + 1
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                let newPrefix = "\n\(nextNumber). "
                mutable.insert(NSAttributedString(string: newPrefix, attributes: prefixAttrs), at: cursorLocation)

                isProgrammaticChange = true
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: cursorLocation + (newPrefix as NSString).length, length: 0)
                isProgrammaticChange = false
                syncMarkdown(from: textView)
                return false
            }

            return true
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // IME 组字期间不刷新 typingAttributes，防止自定义格式属性被丢弃
            guard textView.markedTextRange == nil else { return }
            refreshTypingAttributes(for: textView)
        }

        func perform(
            action: MarkdownEditorAction,
            on textView: UITextView,
            markdown: Binding<String>
        ) {
            guard textView.markedTextRange == nil else { return }

            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }

            switch action {
            case .toggleBold:
                toggleInlineStyle(on: textView, attribute: .holoBold, value: true)
            case .insertUnorderedList:
                insertAtLineStart("\u{2022} ", on: textView)
            case .insertOrderedList:
                insertAtLineStart("1. ", on: textView)
            case .insertText(let text):
                insertText(text, on: textView)
            }

            if textView.markedTextRange == nil {
                syncMarkdown(from: textView)
            }
            markdown.wrappedValue = lastKnownMarkdown
        }

        func refreshTypingAttributes(for textView: UITextView) {
            var typingAttributes = MarkdownTextView.baseAttributes
            let location = max(0, min(textView.selectedRange.location, textView.attributedText.length))

            // 先从周围文字推断 contextual 格式
            if textView.selectedRange.length > 0, location < textView.attributedText.length {
                typingAttributes.merge(MarkdownTextView.inlineAttributes(at: location, in: textView.attributedText)) { _, new in new }
            } else if location > 0, location - 1 < textView.attributedText.length {
                typingAttributes.merge(MarkdownTextView.inlineAttributes(at: location - 1, in: textView.attributedText)) { _, new in new }
            }

            // 叠加用户显式切换的加粗状态（sticky toggle，Word-like 行为）
            if let bold = explicitBold {
                if bold {
                    typingAttributes[.holoBold] = true
                } else {
                    typingAttributes.removeValue(forKey: .holoBold)
                }
            }

            typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
            if typingAttributes[.foregroundColor] == nil {
                typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
            }
            textView.typingAttributes = typingAttributes

            notifyFormatState(typingAttributes)
        }

        private func syncMarkdown(from textView: UITextView) {
            let markdown = MarkdownTextView.serializeMarkdown(from: textView.attributedText)
            lastKnownMarkdown = markdown
            text = markdown
        }

        private func toggleInlineStyle(on textView: UITextView, attribute: NSAttributedString.Key, value: Bool) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)

            if safeRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let isActive = (typingAttributes[attribute] as? Bool) == true
                if isActive {
                    typingAttributes.removeValue(forKey: attribute)
                } else {
                    typingAttributes[attribute] = value
                }
                typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
                if typingAttributes[.foregroundColor] == nil {
                    typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
                }
                textView.typingAttributes = typingAttributes

                // 更新 sticky toggle 状态
                if attribute == .holoBold { explicitBold = !isActive }
                notifyFormatState(typingAttributes)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let shouldEnable = !MarkdownTextView.rangeHasAttribute(attribute, in: mutable, range: safeRange)

            mutable.beginEditing()
            mutable.enumerateAttributes(in: safeRange, options: []) { attrs, range, _ in
                var updated = attrs
                if shouldEnable {
                    updated[attribute] = value
                } else {
                    updated.removeValue(forKey: attribute)
                }
                MarkdownTextView.applyResolvedAttributes(updated, to: mutable, range: range)
            }
            mutable.endEditing()

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = safeRange
            isProgrammaticChange = false
            refreshTypingAttributes(for: textView)
        }

        private func insertAtLineStart(_ prefix: String, on textView: UITextView) {
            let currentText = textView.attributedText.string as NSString
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: currentText.length)
            let cursorLocation = safeRange.location

            var lineStart = 0
            if cursorLocation > 0 {
                let substring = currentText.substring(with: NSRange(location: 0, length: cursorLocation))
                if let lastNewline = substring.lastIndex(of: "\n") {
                    lineStart = substring.distance(from: substring.startIndex, to: lastNewline) + 1
                }
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let prefixAttributes = textView.typingAttributes.merging(MarkdownTextView.baseAttributes) { current, _ in current }
            let insert = NSAttributedString(string: prefix, attributes: MarkdownTextView.resolvedAttributes(from: prefixAttributes))
            mutable.insert(insert, at: lineStart)

            let newCursorLocation = cursorLocation + (prefix as NSString).length
            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: newCursorLocation, length: safeRange.length)
            isProgrammaticChange = false
            refreshTypingAttributes(for: textView)
        }

        private func insertText(_ text: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let insertionText = ThoughtVoiceTranscriptInsertion.makeInsertionText(
                transcript: text,
                currentContent: textView.attributedText.string,
                selectedRange: safeRange
            )
            guard !insertionText.isEmpty else { return }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let insert = NSAttributedString(
                string: insertionText,
                attributes: MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            )
            mutable.replaceCharacters(in: safeRange, with: insert)

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: safeRange.location + (insertionText as NSString).length, length: 0)
            isProgrammaticChange = false
            refreshTypingAttributes(for: textView)
        }

        // MARK: - 列表续行辅助

        /// 列表前缀匹配结果
        private struct ListPrefixResult {
            let length: Int
            let numberValue: Int?
        }

        /// 检测行首是否匹配列表前缀
        private static func listPrefixMatch(pattern: String, in line: String) -> ListPrefixResult? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.range.location == 0 else {
                return nil
            }
            let numberValue: Int? = match.numberOfRanges > 1
                ? (Range(match.range(at: 1), in: line).flatMap { Int(String(line[$0])) })
                : nil
            return ListPrefixResult(length: match.range.length, numberValue: numberValue)
        }

        /// 通知外部当前格式状态
        private func notifyFormatState(_ typingAttributes: [NSAttributedString.Key: Any]) {
            onFormatStateChange?(TypingFormatState(
                isBold: (typingAttributes[.holoBold] as? Bool) == true
            ))
        }
    }
}

// MARK: - 富文本转换

private extension MarkdownTextView {
    struct RenderStyle {
        var isBold = false
        var isItalic = false
        var isUnderline = false
        var colorHex: String?
    }

    static let baseFont = UIFont.systemFont(ofSize: 16, weight: .medium)
    static let baseTextColor = UIColor(Color.holoTextPrimary)
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: baseTextColor,
        .paragraphStyle: baseParagraphStyle()
    ]

    private static func baseParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        return style
    }

    static func makeAttributedText(from markdown: String) -> NSAttributedString {
        let document = MarkdownParser.parse(markdown)
        let result = NSMutableAttributedString()

        for (index, node) in document.children.enumerated() {
            append(node: node, to: result, style: RenderStyle())
            if index < document.children.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
        }

        if result.length == 0 {
            return NSAttributedString(string: "", attributes: baseAttributes)
        }

        return result
    }

    static func append(node: MarkdownNode, to result: NSMutableAttributedString, style: RenderStyle) {
        switch node {
        case let textNode as TextNode:
            result.append(NSAttributedString(string: textNode.text, attributes: attributes(for: style)))

        case let paragraph as ParagraphNode:
            appendInlineNodes(paragraph.children, to: result, style: style)

        case let bold as BoldNode:
            var nextStyle = style
            nextStyle.isBold = true
            appendInlineNodes(bold.children, to: result, style: nextStyle)

        case let italic as ItalicNode:
            var nextStyle = style
            nextStyle.isItalic = true
            appendInlineNodes(italic.children, to: result, style: nextStyle)

        case let underline as UnderlineNode:
            var nextStyle = style
            nextStyle.isUnderline = true
            appendInlineNodes(underline.children, to: result, style: nextStyle)

        case let colored as ColoredNode:
            var nextStyle = style
            nextStyle.colorHex = colored.colorHex
            appendInlineNodes(colored.children, to: result, style: nextStyle)

        case let tag as InlineTagNode:
            var tagAttrs = attributes(for: style)
            tagAttrs[.foregroundColor] = UIColor(Color.holoPrimary)
            result.append(NSAttributedString(string: "#\(tag.tagName)", attributes: tagAttrs))

        case let item as UnorderedListItemNode:
            var bulletAttrs = baseAttributes
            bulletAttrs[.foregroundColor] = UIColor(Color.holoTextSecondary)
            result.append(NSAttributedString(string: "\u{2022} ", attributes: bulletAttrs))
            appendInlineNodes(item.children, to: result, style: style)

        case let item as OrderedListItemNode:
            var numberAttrs = baseAttributes
            numberAttrs[.foregroundColor] = UIColor(Color.holoTextSecondary)
            result.append(NSAttributedString(string: "\(item.index). ", attributes: numberAttrs))
            appendInlineNodes(item.children, to: result, style: style)

        default:
            break
        }
    }

    static func appendInlineNodes(_ nodes: [MarkdownNode], to result: NSMutableAttributedString, style: RenderStyle) {
        for node in nodes {
            append(node: node, to: result, style: style)
        }
    }

    static func serializeMarkdown(from attributedText: NSAttributedString) -> String {
        guard attributedText.length > 0 else { return "" }

        var markdown = ""
        attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length), options: []) { attrs, range, _ in
            let text = attributedText.attributedSubstring(from: range).string
            let colorHex = attrs[.holoColorHex] as? String
            let isBold = (attrs[.holoBold] as? Bool) == true
            let isItalic = (attrs[.holoItalic] as? Bool) == true
            let isUnderline = (attrs[.holoUnderline] as? Bool) == true

            let prefix = markdownPrefix(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, colorHex: colorHex)
            let suffix = markdownSuffix(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, colorHex: colorHex)

            markdown += prefix + text + suffix
        }

        return markdown
    }

    static func markdownPrefix(isBold: Bool, isItalic: Bool, isUnderline: Bool, colorHex: String?) -> String {
        var prefix = ""
        if let colorHex {
            prefix += "{color:\(colorHex)}"
        }
        if isBold {
            prefix += "**"
        }
        if isUnderline {
            prefix += "++"
        }
        if isItalic {
            prefix += "*"
        }
        return prefix
    }

    static func markdownSuffix(isBold: Bool, isItalic: Bool, isUnderline: Bool, colorHex: String?) -> String {
        var suffix = ""
        if isItalic {
            suffix += "*"
        }
        if isUnderline {
            suffix += "++"
        }
        if isBold {
            suffix += "**"
        }
        if colorHex != nil {
            suffix += "{/color}"
        }
        return suffix
    }

    static func attributes(for style: RenderStyle) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        if style.isBold {
            attributes[.holoBold] = true
        }
        if style.isItalic {
            attributes[.holoItalic] = true
        }
        if style.isUnderline {
            attributes[.holoUnderline] = true
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let colorHex = style.colorHex {
            attributes[.holoColorHex] = colorHex
            attributes[.foregroundColor] = UIColor(Color(hex: colorHex))
        }
        attributes[.font] = font(from: attributes)
        if attributes[.underlineStyle] == nil {
            attributes[.underlineStyle] = 0
        }
        return attributes
    }

    static func resolvedAttributes(from source: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        for (key, value) in source {
            attributes[key] = value
        }
        attributes[.font] = font(from: attributes)
        if (attributes[.holoUnderline] as? Bool) == true {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            attributes[.underlineStyle] = 0
        }
        if let colorHex = attributes[.holoColorHex] as? String {
            attributes[.foregroundColor] = UIColor(Color(hex: colorHex))
        } else {
            attributes[.foregroundColor] = baseTextColor
        }
        return attributes
    }

    static func applyResolvedAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        to attributedString: NSMutableAttributedString,
        range: NSRange
    ) {
        let resolved = resolvedAttributes(from: attributes)
        attributedString.setAttributes(resolved, range: range)
    }

    static func font(from attributes: [NSAttributedString.Key: Any]) -> UIFont {
        let isBold = (attributes[.holoBold] as? Bool) == true
        let isItalic = (attributes[.holoItalic] as? Bool) == true

        // 直接用 weight 创建字体，避免 withSymbolicTraits 在 .medium base 上效果微弱
        let weight: UIFont.Weight = isBold ? .bold : .medium
        let base = UIFont.systemFont(ofSize: baseFont.pointSize, weight: weight)

        guard isItalic else { return base }

        var traits = base.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        guard let italicDescriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: italicDescriptor, size: baseFont.pointSize)
    }

    static func clampedRange(_ range: NSRange, for length: Int) -> NSRange {
        let safeLocation = max(0, min(range.location, length))
        let safeLength = max(0, min(range.length, length - safeLocation))
        return NSRange(location: safeLocation, length: safeLength)
    }

    static func rangeHasAttribute(_ key: NSAttributedString.Key, in attributedText: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }

        var allMatch = true
        attributedText.enumerateAttribute(key, in: range, options: []) { value, _, stop in
            if (value as? Bool) != true {
                allMatch = false
                stop.pointee = true
            }
        }
        return allMatch
    }

    static func inlineAttributes(at location: Int, in attributedText: NSAttributedString) -> [NSAttributedString.Key: Any] {
        guard attributedText.length > 0, location < attributedText.length else {
            return [:]
        }

        let attrs = attributedText.attributes(at: location, effectiveRange: nil)
        var inline: [NSAttributedString.Key: Any] = [:]
        if let isBold = attrs[.holoBold] as? Bool, isBold {
            inline[.holoBold] = true
        }
        if let isItalic = attrs[.holoItalic] as? Bool, isItalic {
            inline[.holoItalic] = true
        }
        if let isUnderline = attrs[.holoUnderline] as? Bool, isUnderline {
            inline[.holoUnderline] = true
        }
        if let colorHex = attrs[.holoColorHex] as? String {
            inline[.holoColorHex] = colorHex
            inline[.foregroundColor] = UIColor(Color(hex: colorHex))
        }
        return inline
    }
}

private extension NSAttributedString.Key {
    static let holoBold = NSAttributedString.Key("holoMarkdownBold")
    static let holoItalic = NSAttributedString.Key("holoMarkdownItalic")
    static let holoUnderline = NSAttributedString.Key("holoMarkdownUnderline")
    static let holoColorHex = NSAttributedString.Key("holoMarkdownColorHex")
}

// MARK: - SelfSizingTextView

/// 自动计算内容高度的 UITextView
/// 通过 sizeThatFits 在布局完成后计算正确高度，避免 intrinsicContentSize 反馈循环
private final class SelfSizingTextView: UITextView {

    /// 重写 intrinsicContentSize 返回无固定值，避免 SwiftUI ScrollView 内布局反馈循环
    /// 实际高度由 dynamicHeight binding + .frame(height:) 控制
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 利用 sizeThatFits 根据当前宽度计算内容所需高度
        let targetSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        let fittedSize = sizeThatFits(targetSize)
        if fittedSize.height > 0 {
            (delegate as? MarkdownTextView.Coordinator)?.onHeightChange?(fittedSize.height)
            // 内容不超出 frame 时禁用自身滚动，让外层 SwiftUI ScrollView 接管滚动手势
            let needsSelfScroll = fittedSize.height > frame.height + 1
            if isScrollEnabled != needsSelfScroll {
                isScrollEnabled = needsSelfScroll
            }
        }
    }
}
