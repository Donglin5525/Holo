//
//  InlineTagDetector.swift
//  Holo
//
//  观点模块 - 内联标签检测器
//  检测 #tag 模式（含多级路径 #工作/Holo）、提取光标处标签、计算替换范围
//
//  触发条件（提取与光标检测共用）：# 位于文首，或前一字符为空格/换行/中英文标点
//

import Foundation

// MARK: - InlineTagDetector

/// 内联标签检测与提取工具
struct InlineTagDetector {

    /// 内联标签正则：# 后跟字母/CJK 起首的路径（段内允许字母/数字/下划线/CJK，段间以 / 分隔）
    /// 示例：#产品、#工作/Holo、#工作/Holo/编辑器
    private static let tagRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "#[\\p{L}][\\p{L}\\p{N}_]*(/[\\p{L}\\p{N}_]+)*") {
            return regex
        }
        assertionFailure("InlineTagDetector 正则编译失败")
        guard let fallback = try? NSRegularExpression(pattern: "^$") else {
            preconditionFailure("NSRegularExpression init 不可用")
        }
        return fallback
    }()

    /// # 前一个字符允许触发的集合：空白、换行、中英文标点（排除 /，避免 URL 片段误触发）
    private static let triggerPrecedingCharacters: CharacterSet = {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: "/"))
    }()

    // MARK: - 提取标签

    /// 从内容中提取所有标签路径（去重，归一化展示形式）
    static func extractTags(from content: String) -> [String] {
        let range = NSRange(content.startIndex..., in: content)
        let matches = tagRegex.matches(in: content, range: range)

        let tags = matches.compactMap { match -> String? in
            guard isTriggerPosition(match.range.location, in: content),
                  let swiftRange = Range(match.range, in: content) else {
                return nil
            }
            let fullMatch = String(content[swiftRange])
            return ThoughtTagNormalizer.displayPath(String(fullMatch.dropFirst()))
        }

        // 按归一化 key 去重并保持顺序
        var seen = Set<String>()
        return tags.filter { seen.insert(ThoughtTagNormalizer.key($0)).inserted }
    }

    // MARK: - 触发位置判定

    /// # 是否位于合法触发位置：文首，或前一字符为空白/换行/标点
    static func isTriggerPosition(_ hashLocation: Int, in text: String) -> Bool {
        guard hashLocation > 0 else { return true }

        let nsString = text as NSString
        let preceding = nsString.character(at: hashLocation - 1)
        guard let scalar = UnicodeScalar(preceding) else { return false }
        return triggerPrecedingCharacters.contains(scalar)
    }

    // MARK: - 光标位置检测

    /// 检测光标位置是否在标签内
    /// - Returns: 如果在标签内，返回部分标签路径（不含 #）；否则 nil
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

        let hashChar = Character("#").asciiValue ?? 0
        let spaceChar = Character(" ").asciiValue ?? 0
        let newlineChar = Character("\n").asciiValue ?? 0
        let carriageReturnChar = Character("\r").asciiValue ?? 0

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

        // # 必须位于合法触发位置（排除 abc#产品 等）
        guard isTriggerPosition(tagStart, in: content) else { return nil }

        // 检查 # 后面的第一个字符是否为字母（排除 #123 等情况）
        let afterHash = tagStart + 1
        guard afterHash < length else { return nil }
        let firstCharAfterHash = nsString.character(at: afterHash)
        guard let scalar = UnicodeScalar(firstCharAfterHash),
              CharacterSet.letters.contains(scalar) else {
            return nil
        }

        // 从 # 向后搜索标签结束位置（段内字符 + 路径分隔符 /）
        var tagEnd = afterHash + 1
        let validTagChars = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "_/"))
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
