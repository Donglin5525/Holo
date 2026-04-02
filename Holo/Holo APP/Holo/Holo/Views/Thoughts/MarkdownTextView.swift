//
//  MarkdownTextView.swift
//  Holo
//
//  观点模块 - Markdown 编辑器
//  UIViewRepresentable 包装 UITextView，支持光标追踪和程序化文本插入
//

import SwiftUI
import UIKit

// MARK: - MarkdownTextView

/// 支持 Markdown 编辑的文本视图
/// 包装 UITextView 以获取光标位置控制和程序化文本插入能力
struct MarkdownTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var selectedRange: NSRange

    /// 是否显示语法高亮
    var showHighlight: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        textView.textColor = UIColor(Color.holoTextPrimary)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.keyboardType = .default

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // 同步文本（避免递归更新）
        if textView.text != text {
            textView.text = text
        }

        // 同步选中范围
        let currentNSRange = textView.selectedRange
        if currentNSRange != selectedRange {
            textView.selectedRange = selectedRange
        }

        // 应用语法高亮
        if showHighlight {
            applyHighlight(to: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedRange: $selectedRange)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var selectedRange: NSRange

        init(text: Binding<String>, selectedRange: Binding<NSRange>) {
            self._text = text
            self._selectedRange = selectedRange
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            DispatchQueue.main.async { [self] in
                selectedRange = textView.selectedRange
            }
        }
    }

    // MARK: - 语法高亮

    /// 对编辑器中的文本应用基础语法高亮
    private func applyHighlight(to textView: UITextView) {
        let attributedString = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // 基础样式
        attributedString.addAttribute(.font, value: UIFont.systemFont(ofSize: 16, weight: .medium), range: fullRange)
        attributedString.addAttribute(.foregroundColor, value: UIColor(Color.holoTextPrimary), range: fullRange)

        // 加粗标记高亮 **...**
        highlightPattern("\\*\\*[^*]+\\*\\*", in: attributedString, color: UIColor(Color.holoPrimary))

        // 斜体标记高亮 *...*
        highlightPattern("(?<!\\*)\\*(?!\\*)[^*]+\\*(?!\\*)", in: attributedString, color: UIColor(Color.holoInfo))

        // 下划线标记高亮 ++...++
        highlightPattern("\\+\\+[^+]+\\+\\+", in: attributedString, color: UIColor(Color.holoSuccess))

        // 颜色标记高亮 {color:...}...{/color}
        highlightPattern("\\{color:[^}]+\\}", in: attributedString, color: UIColor(Color.holoPurple))
        highlightPattern("\\{/color\\}", in: attributedString, color: UIColor(Color.holoPurple))

        // 内联标签高亮 #tagname
        let tagRegex = try? NSRegularExpression(pattern: "#[\\p{L}][\\p{L}\\p{N}_]*")
        if let regex = tagRegex {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                attributedString.addAttribute(.foregroundColor, value: UIColor(Color.holoPrimary), range: match.range)
            }
        }

        // 列表标记高亮
        highlightPattern("^[\\-\\*] ", in: attributedString, color: UIColor(Color.holoTextSecondary), options: .anchorsMatchLines)
        highlightPattern("^\\d+\\. ", in: attributedString, color: UIColor(Color.holoTextSecondary), options: .anchorsMatchLines)

        textView.attributedText = attributedString
    }

    /// 用正则匹配并高亮
    private func highlightPattern(
        _ pattern: String,
        in attributedString: NSMutableAttributedString,
        color: UIColor,
        options: NSRegularExpression.Options = []
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)
        for match in matches {
            attributedString.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

// MARK: - MarkdownTextView 扩展（程序化插入）

extension MarkdownTextView {

    /// 在当前光标位置插入 Markdown 语法
    /// - Parameters:
    ///   - prefix: 插入在选中文本前的标记
    ///   - suffix: 插入在选中文本后的标记
    ///   - content: 绑定的内容字符串
    ///   - range: 当前的选中范围
    ///   - returns: 更新后的内容和范围
    static func insertFormat(
        prefix: String,
        suffix: String,
        content: Binding<String>,
        range: Binding<NSRange>
    ) {
        let currentContent = content.wrappedValue
        let nsString = currentContent as NSString
        let currentRange = range.wrappedValue

        // 确保范围有效
        let safeRange = NSRange(
            location: min(currentRange.location, nsString.length),
            length: min(currentRange.length, max(0, nsString.length - currentRange.location))
        )

        let selectedText = nsString.substring(with: safeRange)
        let replacement = "\(prefix)\(selectedText)\(suffix)"

        let newContent = nsString.replacingCharacters(in: safeRange, with: replacement)
        content.wrappedValue = newContent

        // 将光标放在 prefix 之后（如果有选中文本则选中内容，否则放在中间位置）
        if selectedText.isEmpty {
            let cursorPos = safeRange.location + (prefix as NSString).length
            range.wrappedValue = NSRange(location: cursorPos, length: 0)
        } else {
            let newCursorStart = safeRange.location + (prefix as NSString).length
            let newCursorLength = (selectedText as NSString).length
            range.wrappedValue = NSRange(location: newCursorStart, length: newCursorLength)
        }
    }

    /// 在当前行的行首插入文本（用于列表）
    static func insertAtLineStart(
        _ linePrefix: String,
        content: Binding<String>,
        range: Binding<NSRange>
    ) {
        let currentContent = content.wrappedValue
        let nsString = currentContent as NSString
        let cursorPos = range.wrappedValue.location

        // 找到当前行的起始位置
        var lineStart = 0
        if cursorPos > 0 {
            let substring = nsString.substring(with: NSRange(location: 0, length: cursorPos))
            if let lastNewline = substring.lastIndex(of: "\n") {
                lineStart = substring.distance(from: substring.startIndex, to: lastNewline) + 1
            }
        }

        // 在行首插入前缀
        let insertRange = NSRange(location: lineStart, length: 0)
        let newContent = nsString.replacingCharacters(in: insertRange, with: linePrefix)
        content.wrappedValue = newContent

        // 移动光标到前缀之后
        range.wrappedValue = NSRange(location: cursorPos + (linePrefix as NSString).length, length: 0)
    }
}
