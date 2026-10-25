import SwiftUI
import UIKit

/// 字体只用于想法纸面；按钮、导航与其他模块继续使用全局字体。
enum ThoughtTypography {
    static func font(_ role: ThoughtFontRole, size: CGFloat = 17, bold: Bool = false, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        if role == .system { return .system(textStyle, design: .default, weight: bold ? .semibold : .regular) }
        return .custom(fontName(role, bold: bold), size: size, relativeTo: textStyle)
    }

    static func uiFont(_ role: ThoughtFontRole, size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        let isBold = traits.contains(.traitBold)
        let base = role == .system
            ? UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
            : UIFont(name: fontName(role, bold: isBold), size: size) ?? UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
        guard traits.contains(.traitItalic),
              let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func fontName(_ role: ThoughtFontRole, bold: Bool = false) -> String {
        let weight = bold ? "Bold" : "Regular"
        switch role {
        case .system: return UIFont.systemFont(ofSize: 17).fontName
        case .serif: return "HoloNoteSerif-\(weight)"
        case .handwritten: return "HoloNoteHand-\(weight)"
        }
    }

    /// 分享使用同一套 Markdown 解析和用户格式，转成可被 ImageRenderer 绘制的字体。
    static func exportText(_ text: String, style: ThoughtStyle) -> AttributedString {
        let source = ThoughtEditorAppearance.attributed(
            MarkdownTextView.makeAttributedText(from: text), style: style
        )
        var result = AttributedString()
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var part = AttributedString((source.string as NSString).substring(with: range))
            if let current = attributes[.font] as? UIFont {
                if style.fontRole == .system {
                    part.font = .system(size: current.pointSize, weight: current.fontDescriptor.symbolicTraits.contains(.traitBold) ? .bold : .regular)
                } else {
                    // UIKit 已按 Dynamic Type 得到实际字号，转 SwiftUI 时不再重复放大。
                    part.font = .custom(current.fontName, fixedSize: current.pointSize)
                }
                if current.fontDescriptor.symbolicTraits.contains(.traitItalic) { part.font = part.font?.italic() }
            }
            if let color = attributes[.foregroundColor] as? UIColor { part.foregroundColor = Color(color) }
            if let value = attributes[.underlineStyle] as? Int, value != 0 { part.underlineStyle = .single }
            if let value = attributes[.strikethroughStyle] as? Int, value != 0 { part.strikethroughStyle = .single }
            result += part
        }
        return result
    }
}
