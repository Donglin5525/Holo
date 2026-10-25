import SwiftUI
import UIKit

/// 模板只改显示属性，文字、Token、选色与语义格式仍由原编辑管线保存。
enum ThoughtEditorAppearance {
    static func apply(_ style: ThoughtStyle, to textView: UITextView) {
        guard textView.markedTextRange == nil else { return }
        let selection = textView.selectedRange
        let updates = updates(in: textView.attributedText, style: style)
        if !updates.isEmpty {
            textView.textStorage.beginEditing()
            for (range, attributes) in updates { textView.textStorage.addAttributes(attributes, range: range) }
            textView.textStorage.endEditing()
            textView.selectedRange = selection
        }
        var typing = textView.typingAttributes
        if typing[.holoColorHex] == nil { typing[.foregroundColor] = UIColor(style.editorInk) }
        if let current = typing[.font] as? UIFont {
            typing[.font] = ThoughtTypography.uiFont(style.fontRole, size: current.pointSize, traits: current.fontDescriptor.symbolicTraits)
        }
        textView.typingAttributes = typing
        textView.tintColor = UIColor(style == .plain ? Color.holoToolAction : style.accent)
    }

    /// 只读测量、卡片与导出复用同样的显示转换，不触碰绑定或数据库。
    static func attributed(_ source: NSAttributedString, style: ThoughtStyle) -> NSAttributedString {
        guard style != .plain else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        for (range, attributes) in updates(in: source, style: style) { result.addAttributes(attributes, range: range) }
        return result
    }

    private static func updates(in source: NSAttributedString, style: ThoughtStyle) -> [(NSRange, [NSAttributedString.Key: Any])] {
        let color = UIColor(style.editorInk)
        var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            guard attributes[.holoTokenType] == nil, attributes[.attachment] == nil else { return }
            var replacement: [NSAttributedString.Key: Any] = [:]
            if attributes[.holoColorHex] == nil,
               (attributes[.foregroundColor] as? UIColor)?.isEqual(color) != true {
                replacement[.foregroundColor] = color
            }
            if let current = attributes[.font] as? UIFont {
                let proposed = ThoughtTypography.uiFont(style.fontRole, size: current.pointSize, traits: current.fontDescriptor.symbolicTraits)
                if proposed != current { replacement[.font] = proposed }
            }
            if !replacement.isEmpty { updates.append((range, replacement)) }
        }
        return updates
    }
}
