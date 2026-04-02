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
    case toggleItalic
    case toggleUnderline
    case applyColor(String)
    case insertUnorderedList
    case insertOrderedList
    case insertTag
}

// MARK: - MarkdownTextView

/// 支持 Markdown 编辑的文本视图
/// 编辑时展示富文本效果，底层仍使用 markdown 字符串存储
struct MarkdownTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var pendingAction: MarkdownEditorAction?
    /// 动态高度绑定，由视图自动计算并报告给父视图
    @Binding var dynamicHeight: CGFloat

    /// 是否启用富文本渲染
    var showHighlight: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let textView = SelfSizingTextView()
        textView.delegate = context.coordinator
        textView.font = Self.baseFont
        textView.textColor = Self.baseTextColor
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        // 启用滚动以避免 isScrollEnabled=false 在 SwiftUI ScrollView 中
        // 产生的 intrinsicContentSize 无限布局反馈循环
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
        context.coordinator.refreshTypingAttributes(for: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if let action = pendingAction {
            pendingAction = nil
            context.coordinator.perform(action: action, on: textView, markdown: $text)
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

        init(text: Binding<String>) {
            self._text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticChange else { return }
            guard textView.markedTextRange == nil else { return }
            syncMarkdown(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
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
            case .toggleItalic:
                toggleInlineStyle(on: textView, attribute: .holoItalic, value: true)
            case .toggleUnderline:
                toggleInlineStyle(on: textView, attribute: .holoUnderline, value: true)
            case .applyColor(let hex):
                applyColor(hex, on: textView)
            case .insertUnorderedList:
                insertAtLineStart("- ", on: textView)
            case .insertOrderedList:
                insertAtLineStart("1. ", on: textView)
            case .insertTag:
                prefixSelection(with: "#", on: textView)
            }

            if textView.markedTextRange == nil {
                syncMarkdown(from: textView)
            }
            markdown.wrappedValue = lastKnownMarkdown
        }

        func refreshTypingAttributes(for textView: UITextView) {
            var typingAttributes = MarkdownTextView.baseAttributes
            let location = max(0, min(textView.selectedRange.location, textView.attributedText.length))

            if textView.selectedRange.length > 0, location < textView.attributedText.length {
                typingAttributes.merge(MarkdownTextView.inlineAttributes(at: location, in: textView.attributedText)) { _, new in new }
            } else if location > 0, location - 1 < textView.attributedText.length {
                typingAttributes.merge(MarkdownTextView.inlineAttributes(at: location - 1, in: textView.attributedText)) { _, new in new }
            }

            typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
            if typingAttributes[.underlineStyle] == nil {
                typingAttributes[.underlineStyle] = 0
            }
            textView.typingAttributes = typingAttributes
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
                typingAttributes[.underlineStyle] = ((typingAttributes[.holoUnderline] as? Bool) == true)
                    ? NSUnderlineStyle.single.rawValue
                    : 0
                if typingAttributes[.foregroundColor] == nil {
                    typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
                }
                textView.typingAttributes = typingAttributes
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

        private func applyColor(_ hex: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)

            if safeRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                typingAttributes[.holoColorHex] = hex
                typingAttributes[.foregroundColor] = UIColor(Color(hex: hex))
                typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
                textView.typingAttributes = typingAttributes
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.beginEditing()
            mutable.enumerateAttributes(in: safeRange, options: []) { attrs, range, _ in
                var updated = attrs
                updated[.holoColorHex] = hex
                updated[.foregroundColor] = UIColor(Color(hex: hex))
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

        private func prefixSelection(with prefix: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let insertAttributes = textView.typingAttributes.merging(MarkdownTextView.baseAttributes) { current, _ in current }
            let prefixText = NSAttributedString(string: prefix, attributes: MarkdownTextView.resolvedAttributes(from: insertAttributes))

            mutable.insert(prefixText, at: safeRange.location)

            let newLocation = safeRange.location + (prefix as NSString).length
            let newLength = safeRange.length

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: newLocation, length: newLength)
            isProgrammaticChange = false
            refreshTypingAttributes(for: textView)
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
        .foregroundColor: baseTextColor
    ]

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
            result.append(NSAttributedString(string: "#\(tag.tagName)", attributes: attributes(for: style)))

        case let item as UnorderedListItemNode:
            result.append(NSAttributedString(string: "- ", attributes: baseAttributes))
            appendInlineNodes(item.children, to: result, style: style)

        case let item as OrderedListItemNode:
            result.append(NSAttributedString(string: "\(item.index). ", attributes: baseAttributes))
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
        var traits: UIFontDescriptor.SymbolicTraits = []
        if (attributes[.holoBold] as? Bool) == true {
            traits.insert(.traitBold)
        }
        if (attributes[.holoItalic] as? Bool) == true {
            traits.insert(.traitItalic)
        }

        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) ?? baseFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // 利用 sizeThatFits 根据当前宽度计算内容所需高度
        let targetSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        let fittedSize = sizeThatFits(targetSize)
        if fittedSize.height > 0 {
            (delegate as? MarkdownTextView.Coordinator)?.onHeightChange?(fittedSize.height)
        }
    }
}
