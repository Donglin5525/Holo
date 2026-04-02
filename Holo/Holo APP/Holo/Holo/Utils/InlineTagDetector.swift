//
//  InlineTagDetector.swift
//  Holo
//
//  观点模块 - 内联标签检测器
//  检测 #tag 模式、提取光标处标签、计算替换范围
//

import Foundation

// MARK: - InlineTagDetector

/// 内联标签检测与提取工具
struct InlineTagDetector {

    /// 内联标签正则模式：# 后跟字母/CJK 字符，然后跟任意字母/数字/下划线/CJK 字符
    private static let tagRegex = try! NSRegularExpression(
        pattern: "#[\\p{L}][\\p{L}\\p{N}_]*"
    )

    // MARK: - 提取标签

    /// 从内容中提取所有标签名称（去重）
    static func extractTags(from content: String) -> [String] {
        let range = NSRange(content.startIndex..., in: content)
        let matches = tagRegex.matches(in: content, range: range)

        let tags = matches.compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: content) else { return nil }
            let fullMatch = String(content[swiftRange])
            return String(fullMatch.dropFirst()) // 去掉 #
        }

        // 去重并保持顺序
        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    // MARK: - 光标位置检测

    /// 检测光标位置是否在标签内
    /// - Returns: 如果在标签内，返回部分标签名（不含 #）；否则 nil
    static func currentTagAtCursor(content: String, cursorPosition: Int) -> String? {
        guard let tagRange = tagRangeAtCursor(content: content, cursorPosition: cursorPosition) else {
            return nil
        }
        guard let swiftRange = Range(tagRange, in: content) else { return nil }
        let fullTag = String(content[swiftRange])
        return String(fullTag.dropFirst()) // 去掉 #
    }

    /// 获取光标位置处标签的 NSRange（包含 #）
    static func tagRangeAtCursor(content: String, cursorPosition: Int) -> NSRange? {
        let nsString = content as NSString
        let length = nsString.length
        guard cursorPosition <= length else { return nil }

        // 从光标向前搜索 # 字符
        let hashChar = Character("#").asciiValue!
        let spaceChar = Character(" ").asciiValue!
        let newlineChar = Character("\n").asciiValue!
        let carriageReturnChar = Character("\r").asciiValue!

        var tagStart = -1
        var searchPos = cursorPosition - 1
        while searchPos >= 0 {
            let char = nsString.character(at: searchPos)
            if char == UInt16(hashChar) {
                tagStart = searchPos
                break
            }
            // 遇到空格、换行符等分隔符则停止
            if char == UInt16(spaceChar)
                || char == UInt16(newlineChar)
                || char == UInt16(carriageReturnChar) {
                return nil
            }
            searchPos -= 1
        }

        guard tagStart >= 0 else { return nil }

        // 检查 # 后面的第一个字符是否为字母（排除 #123 等情况）
        let afterHash = tagStart + 1
        guard afterHash < length else { return nil }
        let firstCharAfterHash = nsString.character(at: afterHash)
        guard let scalar = UnicodeScalar(firstCharAfterHash),
              CharacterSet.letters.contains(scalar) else {
            return nil
        }

        // 从 # 向后搜索标签结束位置
        var tagEnd = afterHash + 1
        let validTagChars = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "_"))
        while tagEnd < length {
            let tagChar = nsString.character(at: tagEnd)
            if let scalar = UnicodeScalar(tagChar), validTagChars.contains(scalar) {
                tagEnd += 1
            } else {
                break
            }
        }

        return NSRange(location: tagStart, length: tagEnd - tagStart)
    }
}
