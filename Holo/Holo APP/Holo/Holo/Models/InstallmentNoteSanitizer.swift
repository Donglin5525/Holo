//
//  InstallmentNoteSanitizer.swift
//  Holo
//
//  分期序号属于交易元数据，不应写入用户可见的商品名称。
//

import Foundation

enum InstallmentNoteSanitizer {
    private static let legacyPrefixRegex = try! NSRegularExpression(
        pattern: #"^(?:\s*\[\s*分期\s*\d+\s*/\s*\d+\s*\]\s*)+"#
    )

    /// 移除历史版本反复写入名称开头的 `[分期 x/y]`，空名称统一返回 nil。
    static func clean(_ note: String?) -> String? {
        guard let note else { return nil }
        let range = NSRange(note.startIndex..<note.endIndex, in: note)
        let cleaned = legacyPrefixRegex
            .stringByReplacingMatches(in: note, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
