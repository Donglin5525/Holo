//
//  TriggerDetector.swift
//  Holo
//
//  观点模块 - 编辑器 #/@ 触发检测器
//  从光标位置向前扫描当前输入片段，识别标签/引用搜索上下文
//  触发位置规则与 InlineTagDetector 共用（isTriggerPosition），禁止两套判定漂移
//

import Foundation

// MARK: - EditorTriggerContext

/// 编辑器当前触发上下文（候选面板的数据源）
enum EditorTriggerContext: Equatable {
    /// 标签搜索：range 含 # 前缀及已输入关键词，query 为关键词（可为空）
    case tag(range: NSRange, query: String)
    /// 引用搜索：range 含 @ 前缀及已输入关键词，query 为关键词（可为空）
    case reference(range: NSRange, query: String)

    /// 触发区间（用于选中候选项后整体替换为 Token）
    var range: NSRange {
        switch self {
        case .tag(let range, _), .reference(let range, _):
            return range
        }
    }
}

// MARK: - TriggerDetector

/// 触发检测器（纯函数，供单测）
enum TriggerDetector {

    /// 关键词允许字符：字母（含 CJK）、数字、下划线、路径分隔符
    private static let queryCharacters: CharacterSet = {
        CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "_/"))
    }()

    /// 检测光标处的触发上下文
    /// - Parameters:
    ///   - text: 编辑器全文（UTF-16 视角）
    ///   - cursor: 光标位置（UTF-16 offset，即 selectedRange.location）
    /// - Returns: 触发上下文；光标不在触发片段内时返回 nil
    static func detect(text: NSString, cursor: Int) -> EditorTriggerContext? {
        guard cursor > 0, cursor <= text.length else { return nil }

        var scanPos = cursor - 1
        while scanPos >= 0 {
            let char = text.character(at: scanPos)

            if char == UInt16(Character("#").asciiValue ?? 0) {
                return makeContext(kind: .tag, text: text, triggerLocation: scanPos, cursor: cursor)
            }

            if char == UInt16(Character("@").asciiValue ?? 0) {
                return makeContext(kind: .reference, text: text, triggerLocation: scanPos, cursor: cursor)
            }

            guard let scalar = UnicodeScalar(char), queryCharacters.contains(scalar) else {
                // 遇到空白/换行/标点等分隔符，当前片段无触发
                return nil
            }
            scanPos -= 1
        }

        return nil
    }

    // MARK: - Private

    private static func makeContext(
        kind: HoloTokenType,
        text: NSString,
        triggerLocation: Int,
        cursor: Int
    ) -> EditorTriggerContext? {
        // 触发字符必须位于合法位置：文首，或前一字符为空白/换行/标点（与提取规则一致）
        guard InlineTagDetector.isTriggerPosition(triggerLocation, in: text as String) else {
            return nil
        }

        let query = text.substring(with: NSRange(location: triggerLocation + 1, length: cursor - triggerLocation - 1))

        // 关键词非空时首字符必须是字母（排除 #123 等）
        if let first = query.first, !first.isLetter {
            return nil
        }

        let range = NSRange(location: triggerLocation, length: cursor - triggerLocation)
        switch kind {
        case .tag:
            return .tag(range: range, query: query)
        case .reference:
            return .reference(range: range, query: query)
        }
    }
}
