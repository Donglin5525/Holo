//
//  MarkdownParser.swift
//  Holo
//
//  观点模块 - Markdown 解析器
//  将 Markdown 文本解析为 AST 节点树
//

import Foundation

// MARK: - AST 节点协议

/// Markdown AST 节点协议
protocol MarkdownNode {
    /// 纯文本内容（去除所有格式标记）
    var plainText: String { get }
}

// MARK: - 内联节点

/// 纯文本节点
struct TextNode: MarkdownNode {
    let text: String
    var plainText: String { text }
}

/// 加粗节点
struct BoldNode: MarkdownNode {
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 斜体节点
struct ItalicNode: MarkdownNode {
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 下划线节点（自定义语法 ++text++）
struct UnderlineNode: MarkdownNode {
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 颜色节点（自定义语法 {color:#hex}text{/color}）
struct ColoredNode: MarkdownNode {
    let colorHex: String
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 内联标签节点（#tagname）
struct InlineTagNode: MarkdownNode {
    let tagName: String
    var plainText: String { "#\(tagName)" }
}

// MARK: - 块级节点

/// 段落节点
struct ParagraphNode: MarkdownNode {
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 无序列表项节点
struct UnorderedListItemNode: MarkdownNode {
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 有序列表项节点
struct OrderedListItemNode: MarkdownNode {
    let index: Int
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

/// 文档根节点
struct DocumentNode: MarkdownNode {
    let children: [MarkdownNode]
    var plainText: String { children.map(\.plainText).joined() }
}

// MARK: - 正则缓存

/// 预编译正则表达式缓存，避免重复编译
private enum RegexCache {
    static let unorderedList = try! NSRegularExpression(pattern: "^[\\-\\*] (.+)$")
    static let orderedList = try! NSRegularExpression(pattern: "^(\\d+)\\. (.+)$")
    static let inlineTag = try! NSRegularExpression(pattern: "#[\\p{L}][\\p{L}\\p{N}_]*")
    static let colorOpen = try! NSRegularExpression(pattern: "\\{color:(#[0-9A-Fa-f]{3,8}|[0-9A-Fa-f]{3,8})\\}")
    static let colorClose = try! NSRegularExpression(pattern: "\\{/color\\}")

    // stripFormatting 专用
    static let colorOpenStrip = try! NSRegularExpression(pattern: "\\{color:[^}]+\\}")
    static let italicStrip = try! NSRegularExpression(pattern: "(?<![\\*])\\*(?![\\*])")
    static let unorderedListStrip = try! NSRegularExpression(pattern: "^[\\-\\*] ", options: .anchorsMatchLines)
    static let orderedListStrip = try! NSRegularExpression(pattern: "^\\d+\\. ", options: .anchorsMatchLines)
    static let tagStrip = try! NSRegularExpression(pattern: "#([\\p{L}][\\p{L}\\p{N}_]*)")
}

// MARK: - MarkdownParser

/// 轻量 Markdown 解析器
/// 两阶段解析：块级解析（列表/段落）→ 内联解析（格式/标签）
struct MarkdownParser {

    // MARK: - 公共接口

    /// 解析 Markdown 文本为 AST
    static func parse(_ markdown: String) -> DocumentNode {
        let lines = markdown.components(separatedBy: "\n")
        let blocks = parseBlocks(lines)
        return DocumentNode(children: blocks)
    }

    /// 提取所有 # 标签名称
    static func extractTags(from content: String) -> [String] {
        let range = NSRange(content.startIndex..., in: content)
        let matches = RegexCache.inlineTag.matches(in: content, range: range)
        return matches.compactMap { match in
            let matchRange = match.range
            guard let swiftRange = Range(matchRange, in: content) else { return nil }
            let fullMatch = String(content[swiftRange])
            return String(fullMatch.dropFirst()) // 去掉 #
        }
    }

    /// 去除所有格式标记，返回纯文本
    static func stripFormatting(_ markdown: String) -> String {
        var result = markdown

        // 去除颜色标记
        result = stripMatches(pattern: RegexCache.colorOpenStrip, in: result)
        result = result.replacingOccurrences(of: "{/color}", with: "")

        // 去除加粗标记
        result = result.replacingOccurrences(of: "**", with: "")

        // 去除下划线标记
        result = result.replacingOccurrences(of: "++", with: "")

        // 去除斜体标记（单个 *）
        result = stripMatches(pattern: RegexCache.italicStrip, in: result)

        // 去除列表标记
        result = stripMatches(pattern: RegexCache.unorderedListStrip, in: result)
        result = stripMatches(pattern: RegexCache.orderedListStrip, in: result)

        // 去除 # 标签的 # 号
        result = stripTagHashes(in: result)

        return result
    }

    // MARK: - 块级解析

    /// 将行列表解析为块级节点
    private static func parseBlocks(_ lines: [String]) -> [MarkdownNode] {
        var nodes: [MarkdownNode] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // 跳过空行
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            // 检测无序列表
            if matchUnorderedList(line) != nil {
                let items = collectUnorderedListItems(lines: lines, from: &index)
                nodes.append(contentsOf: items)
                continue
            }

            // 检测有序列表
            if matchOrderedList(line) != nil {
                let items = collectOrderedListItems(lines: lines, from: &index)
                nodes.append(contentsOf: items)
                continue
            }

            // 收集连续非空行作为段落
            var paragraphLines: [String] = []
            while index < lines.count {
                let currentLine = lines[index]
                if currentLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                if matchUnorderedList(currentLine) != nil
                    || matchOrderedList(currentLine) != nil {
                    break
                }
                paragraphLines.append(currentLine)
                index += 1
            }

            if !paragraphLines.isEmpty {
                let paragraphText = paragraphLines.joined(separator: "\n")
                let inlineNodes = parseInline(paragraphText)
                nodes.append(ParagraphNode(children: inlineNodes))
            }
        }

        return nodes
    }

    /// 匹配无序列表行，返回内容部分
    private static func matchUnorderedList(_ line: String) -> String? {
        let nsRange = NSRange(line.startIndex..., in: line)
        guard let match = RegexCache.unorderedList.firstMatch(in: line, range: nsRange),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        // 确保整行匹配
        if match.range.location != 0 || match.range.length != nsRange.length {
            return nil
        }
        return String(line[contentRange])
    }

    /// 匹配有序列表行，返回 (序号, 内容)
    private static func matchOrderedList(_ line: String) -> (Int, String)? {
        let nsRange = NSRange(line.startIndex..., in: line)
        guard let match = RegexCache.orderedList.firstMatch(in: line, range: nsRange),
              match.numberOfRanges > 2,
              let numberRange = Range(match.range(at: 1), in: line),
              let contentRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        if match.range.location != 0 || match.range.length != nsRange.length {
            return nil
        }
        let number = Int(String(line[numberRange])) ?? 1
        return (number, String(line[contentRange]))
    }

    /// 收集连续的无序列表项
    private static func collectUnorderedListItems(lines: [String], from index: inout Int) -> [MarkdownNode] {
        var items: [MarkdownNode] = []

        while index < lines.count {
            let line = lines[index]
            if let content = matchUnorderedList(line) {
                let inlineNodes = parseInline(content)
                items.append(UnorderedListItemNode(children: inlineNodes))
                index += 1
            } else {
                break
            }
        }

        return items
    }

    /// 收集连续的有序列表项
    private static func collectOrderedListItems(lines: [String], from index: inout Int) -> [MarkdownNode] {
        var items: [MarkdownNode] = []

        while index < lines.count {
            let line = lines[index]
            if let (number, content) = matchOrderedList(line) {
                let inlineNodes = parseInline(content)
                items.append(OrderedListItemNode(index: number, children: inlineNodes))
                index += 1
            } else {
                break
            }
        }

        return items
    }

    // MARK: - 内联解析

    /// 解析内联格式（加粗、斜体、下划线、颜色、标签）
    private static func parseInline(_ text: String) -> [MarkdownNode] {
        var nodes: [MarkdownNode] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            if let (node, rest) = tryParseColor(remaining) {
                nodes.append(node)
                remaining = rest
            } else if let (node, rest) = tryParseBold(remaining) {
                nodes.append(node)
                remaining = rest
            } else if let (node, rest) = tryParseUnderline(remaining) {
                nodes.append(node)
                remaining = rest
            } else if let (node, rest) = tryParseItalic(remaining) {
                nodes.append(node)
                remaining = rest
            } else if let (node, rest) = tryParseInlineTag(remaining) {
                nodes.append(node)
                remaining = rest
            } else {
                if let (textNode, rest) = tryParsePlainText(remaining) {
                    nodes.append(textNode)
                    remaining = rest
                } else {
                    nodes.append(TextNode(text: String(remaining.prefix(1))))
                    remaining = remaining.dropFirst()
                }
            }
        }

        return nodes
    }

    // MARK: - 单个格式解析

    /// 尝试解析颜色标记 {color:#hex}text{/color}
    private static func tryParseColor(_ text: Substring) -> (MarkdownNode, Substring)? {
        let fullText = String(text)
        let fullNSRange = NSRange(fullText.startIndex..., in: fullText)
        guard let openMatch = RegexCache.colorOpen.firstMatch(in: fullText, range: fullNSRange),
              openMatch.range.location == 0,
              openMatch.numberOfRanges > 1,
              let hexRange = Range(openMatch.range(at: 1), in: fullText) else {
            return nil
        }

        let colorHex = String(fullText[hexRange])

        // 在开始标记之后搜索闭合标记
        let afterOpenStart = openMatch.range.upperBound
        let remainingLength = fullNSRange.length - afterOpenStart
        guard remainingLength > 0,
              let afterOpenRange = Range(NSRange(location: afterOpenStart, length: remainingLength), in: fullText) else {
            return nil
        }

        let afterOpenString = String(fullText[afterOpenRange])
        let afterOpenNSRange = NSRange(afterOpenString.startIndex..., in: afterOpenString)
        guard let closeMatch = RegexCache.colorClose.firstMatch(in: afterOpenString, range: afterOpenNSRange),
              let closeSwiftRange = Range(closeMatch.range, in: afterOpenString) else {
            return nil
        }

        // 提取颜色标记内的内容
        let contentEndOffset = afterOpenStart + closeMatch.range.location
        let contentStart = fullText.index(fullText.startIndex, offsetBy: afterOpenStart)
        let contentEnd = fullText.index(fullText.startIndex, offsetBy: contentEndOffset)
        let content = String(fullText[contentStart..<contentEnd])
        let inlineNodes = parseInline(content)

        // 计算剩余文本
        let restOffset = afterOpenStart + closeMatch.range.upperBound
        let rest = text[text.index(text.startIndex, offsetBy: restOffset)...]

        return (ColoredNode(colorHex: colorHex, children: inlineNodes), rest)
    }

    /// 尝试解析加粗 **text**
    private static func tryParseBold(_ text: Substring) -> (MarkdownNode, Substring)? {
        guard text.hasPrefix("**") else { return nil }

        let contentStart = text.index(text.startIndex, offsetBy: 2)
        let searchRange = text[contentStart...]

        guard let closeRange = searchRange.range(of: "**") else {
            return nil
        }

        let content = String(text[contentStart..<closeRange.lowerBound])
        let inlineNodes = parseInline(content)
        let rest = text[closeRange.upperBound...]

        return (BoldNode(children: inlineNodes), rest)
    }

    /// 尝试解析下划线 ++text++
    private static func tryParseUnderline(_ text: Substring) -> (MarkdownNode, Substring)? {
        guard text.hasPrefix("++") else { return nil }

        let contentStart = text.index(text.startIndex, offsetBy: 2)
        let searchRange = text[contentStart...]

        guard let closeRange = searchRange.range(of: "++") else {
            return nil
        }

        let content = String(text[contentStart..<closeRange.lowerBound])
        let inlineNodes = parseInline(content)
        let rest = text[closeRange.upperBound...]

        return (UnderlineNode(children: inlineNodes), rest)
    }

    /// 尝试解析斜体 *text*
    private static func tryParseItalic(_ text: Substring) -> (MarkdownNode, Substring)? {
        guard text.hasPrefix("*"),
              !text.hasPrefix("**") else { return nil }

        let contentStart = text.index(text.startIndex, offsetBy: 1)
        let searchRange = text[contentStart...]

        guard let closeIndex = searchRange.firstIndex(of: "*") else {
            return nil
        }

        // 确保 * 后面不是另一个 *（避免与加粗混淆）
        let afterClose = searchRange[closeIndex...]
        if afterClose.count > 1 && afterClose[afterClose.index(afterClose.startIndex, offsetBy: 1)] == "*" {
            return nil
        }

        let content = String(text[contentStart..<closeIndex])
        let inlineNodes = parseInline(content)
        let rest = text[closeIndex...].dropFirst()

        return (ItalicNode(children: inlineNodes), Substring(rest))
    }

    /// 尝试解析内联标签 #tagname
    private static func tryParseInlineTag(_ text: Substring) -> (MarkdownNode, Substring)? {
        let nsString = String(text)
        let nsRange = NSRange(nsString.startIndex..., in: nsString)
        guard let match = RegexCache.inlineTag.firstMatch(in: nsString, range: nsRange),
              match.range.location == 0,
              let swiftRange = Range(match.range, in: nsString) else {
            return nil
        }

        let fullMatch = String(nsString[swiftRange])
        let tagName = String(fullMatch.dropFirst()) // 去掉 #
        let restOffset = nsString.distance(from: nsString.startIndex, to: swiftRange.upperBound)
            let rest = text[text.index(text.startIndex, offsetBy: restOffset)...]

        return (InlineTagNode(tagName: tagName), rest)
    }

    /// 解析普通文本直到遇到格式标记
    private static func tryParsePlainText(_ text: Substring) -> (MarkdownNode, Substring)? {
        var end = text.startIndex
        let formatPrefixes: [String] = ["**", "++", "*", "{color:", "#"]

        while end < text.endIndex {
            let remaining = text[end...]
            var isFormatStart = false

            for prefix in formatPrefixes {
                if remaining.hasPrefix(prefix) {
                    if prefix == "#" {
                        let afterHash = remaining.dropFirst()
                        if let firstChar = afterHash.first, firstChar.isLetter {
                            isFormatStart = true
                            break
                        }
                    } else {
                        isFormatStart = true
                        break
                    }
                }
            }

            if isFormatStart {
                break
            }
            end = text.index(after: end)
        }

        guard end > text.startIndex else { return nil }
        let plainText = String(text[text.startIndex..<end])
        let rest = text[end...]

        return (TextNode(text: plainText), rest)
    }

    // MARK: - Strip 辅助方法

    /// 用正则替换所有匹配为空
    private static func stripMatches(pattern: NSRegularExpression, in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// 去除标签的 # 前缀
    private static func stripTagHashes(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return RegexCache.tagStrip.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }
}
