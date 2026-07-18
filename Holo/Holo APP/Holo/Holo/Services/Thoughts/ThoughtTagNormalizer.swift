//
//  ThoughtTagNormalizer.swift
//  Holo
//
//  观点标签归一化：让手动标签、正文 #标签、AI 标签落到同一个标签身份。
//  多级标签采用「路径即名称」：name 存完整路径（工作/Holo），逐段归一化。
//

import Foundation

enum ThoughtTagNormalizer {

    // MARK: - 展示名

    /// 单段展示名（去 #、去首尾空白）
    /// 兼容路径入参：路径请使用 displayPath
    static func displayName(_ rawValue: String) -> String {
        displayPath(rawValue)
    }

    /// 路径展示形式：去 #、逐段 trim、丢弃空段、全角斜杠归一、以 / 连接
    /// 示例："#工作 / Holo／编辑器 " → "工作/Holo/编辑器"
    static func displayPath(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") || value.hasPrefix("＃") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let segments = value
            .replacingOccurrences(of: "／", with: "/")
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return segments.joined(separator: "/")
    }

    // MARK: - 归一化 key

    /// 归一化 key（去重身份）：逐段归一后以 / 连接
    /// 示例："工作 /Holo" 与 "工作/holo" → 同一 key
    static func key(_ rawValue: String) -> String {
        displayPath(rawValue)
            .components(separatedBy: "/")
            .map { segmentKey($0) }
            .joined(separator: "/")
    }

    /// 路径的父级 key（无父级返回 nil）
    static func parentKey(_ rawValue: String) -> String? {
        let pathKey = key(rawValue)
        guard let lastSlash = pathKey.lastIndex(of: "/") else { return nil }
        return String(pathKey[pathKey.startIndex..<lastSlash])
    }

    /// 路径最后一段的展示名（无路径时返回整体）
    static func lastSegment(_ rawValue: String) -> String {
        let path = displayPath(rawValue)
        guard let lastSlash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: lastSlash)...])
    }

    // MARK: - Private

    private static func segmentKey(_ segment: String) -> String {
        segment
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
