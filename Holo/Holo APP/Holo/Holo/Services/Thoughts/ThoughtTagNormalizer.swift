//
//  ThoughtTagNormalizer.swift
//  Holo
//
//  观点标签归一化：让手动标签、正文 #标签、AI 标签落到同一个标签身份。
//

import Foundation

enum ThoughtTagNormalizer {
    static func displayName(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") || value.hasPrefix("＃") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func key(_ rawValue: String) -> String {
        displayName(rawValue)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
