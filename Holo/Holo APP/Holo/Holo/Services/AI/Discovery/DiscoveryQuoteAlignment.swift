//
//  DiscoveryQuoteAlignment.swift
//  Holo
//
//  「HoloAI 一个发现」G2：模型引用对齐回原文（02 §2.3）。
//
//  直译 HoloBackend/src/thoughts/quoteAlignment.js（44 行纯函数）：
//  · 精确子串 → 原样返回；
//  · 仅排版差异（空白多少/全角空格/弯引号/中文引号/大小写/CRLF）→ 返回覆盖命中区间的原文精确子串；
//  · 其余 → nil（改写拒绝）。不做任何模糊/相似度匹配，尤其不允许把否定词、人称、
//    数值与时间对不上的句子对齐成证据。
//  · JS 字符串是 UTF-16 码元口径：本实现同样按 UTF-16 码元迭代与建映射，
//    保证与后端行为一致（Swift String 的 Character 索引不可直接当 JS 下标用，02 §2.3 末段）。
//
//  在 JS 版之上按 02 §2.3 补一条消歧规则：同一段相同 quote 出现多次时，结合完整
//  sourceBlock 的原文范围定位；仍无法唯一区分 → 拒绝（nil），不许取第一个。
//

import Foundation

// MARK: - 对齐结果

/// 对齐成功的三态之二（第三态 = 返回 nil）。
/// `exactSubstring` 永远是原文的精确子串，可直接作为展示引用；`sourceUTF16Range`
/// 是它在原文中的 UTF-16 位置（quoteLocator / 失效诊断用，模型不感知）。
struct DiscoveryQuoteAlignmentOutcome: Equatable, Sendable {
    let exactSubstring: String
    let sourceUTF16Range: Range<Int>
}

// MARK: - 对齐器

/// 纯函数，无状态。
enum DiscoveryQuoteAlignment {

    /// quote 对齐到 source。
    /// - Parameters:
    ///   - quote: 模型给出的短原文引用
    ///   - source: 不可变原文（整段，不是切块）
    ///   - sourceBlockUTF16Range: 该 quote 所属 sourceBlock 在 source 中的 UTF-16 范围；
    ///     归一化命中多次时用它消歧（完整落在范围内才算候选）。
    /// - Returns: 三态——精确子串原样 / 仅排版差异→原文精确子串 / nil=改写拒绝（含无法消歧的重复）。
    static func align(
        quote: String,
        source: String,
        sourceBlockUTF16Range: Range<Int>? = nil
    ) -> DiscoveryQuoteAlignmentOutcome? {
        // 与 JS 对齐：空 quote 直接拒绝（!quote.length → null）
        guard !quote.isEmpty else { return nil }

        // 1) 精确子串（字面比较，不折叠、不忽略大小写）。
        //    02 §2.3 消歧规则对两条路径同样生效：多次命中用 sourceBlock 范围定位，
        //    仍无法唯一区分 → 拒绝，不取第一个。
        let exactRanges = source.allUTF16Ranges(of: quote)
        if !exactRanges.isEmpty {
            guard let resolved = resolve(exactRanges, blockRange: sourceBlockUTF16Range) else { return nil }
            return DiscoveryQuoteAlignmentOutcome(exactSubstring: quote, sourceUTF16Range: resolved)
        }

        // 2) 归一化对齐（仅排版差异）
        let normalizedQuote = normalize(quote)
        guard !normalizedQuote.units.isEmpty else { return nil }   // quote 全是空白 → null
        let normalizedSource = normalize(source)
        let hits = occurrences(of: normalizedQuote.units, in: normalizedSource.units)
        guard !hits.isEmpty else { return nil }

        // 归一化命中区间 → 原文 UTF-16 闭区间 [map[hit], map[hit+len-1]]，
        // slice 连续区间天然包住被吞掉的中间空白（与 JS slice(map[hit], map[hit+len-1]+1) 一致）。
        let candidates: [Range<Int>] = hits.map { hit in
            let start = normalizedSource.map[hit]
            let end = normalizedSource.map[hit + normalizedQuote.units.count - 1] + 1
            return start..<end
        }
        guard let resolved = resolve(candidates, blockRange: sourceBlockUTF16Range) else { return nil }

        guard let substring = source.substring(utf16Range: resolved) else { return nil }
        return DiscoveryQuoteAlignmentOutcome(exactSubstring: substring, sourceUTF16Range: resolved)
    }

    /// 消歧：唯一命中直接用；多次命中用 sourceBlock 范围收窄（完整落在范围内才算）；
    /// 仍不唯一 → 拒绝，绝不取第一个。
    private static func resolve(_ candidates: [Range<Int>], blockRange: Range<Int>?) -> Range<Int>? {
        if candidates.count == 1 { return candidates[0] }
        guard let blockRange else { return nil }
        let contained = candidates.filter { range in
            range.lowerBound >= blockRange.lowerBound && range.upperBound <= blockRange.upperBound
        }
        guard contained.count == 1 else { return nil }
        return contained[0]
    }

    // MARK: - 归一化（JS normalizedWithMap 直译）

    /// 归一化键（剥空白 + 折叠引号 + 小写，与对齐同一口径）。
    /// EvidenceBuilder 的「原文高度相似」判定复用本口径，避免两套归一化漂移。
    static func normalizedKey(_ string: String) -> String {
        String(decoding: normalize(string).units, as: UTF16.self)
    }

    /// 归一化文本 + 原文下标映射（归一化串第 i 个码元来自原文 map[i]，UTF-16 口径）。
    struct NormalizedText {
        let units: [UInt16]
        let map: [Int]
    }

    /// 剥全部空白（JS /\s/ 的码元集合）+ 弯引号/中文引号折叠直引号 + 统一小写。
    /// 逐 UTF-16 码元处理：emoji 代理对逐半通过（非空白、不折叠、小写无操作），
    /// 因此 ZWJ 序列原样保留，且映射永不指向代理对中间之外的位置。
    private static func normalize(_ string: String) -> NormalizedText {
        var units: [UInt16] = []
        var map: [Int] = []
        for (index, unit) in string.utf16.enumerated() {
            if isJSWhitespace(unit) { continue }
            let folded = foldQuote(unit) ?? unit
            units.append(lowercaseUnit(folded))
            map.append(index)
        }
        return NormalizedText(units: units, map: map)
    }

    /// ECMAScript \s 的单码元集合（全部 BMP 单码元）：
    /// TAB/LF/VT/FF/CR/SP/NBSP/U+1680/U+2000–200A/LS/PS/NNBSP/MMSP/表意空格/BOM。
    private static func isJSWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        case 0x2000...0x200A:
            return true
        default:
            return false
        }
    }

    /// 弯引号/中文引号归一为直引号（JS FLAT_QUOTES 表直译）：排版差异，非内容差异。
    private static func foldQuote(_ unit: UInt16) -> UInt16? {
        switch unit {
        case 0x201C, 0x201D, 0x300C, 0x300D, 0x300E, 0x300F: return 0x22   // “ ” 「」 『』 → "
        case 0x2018, 0x2019: return 0x27                                    // ‘ ’ → '
        default: return nil
        }
    }

    /// 单码元小写（JS ch.toLowerCase() 的安全子集）：
    /// 仅当小写结果仍是单个 UTF-16 码元时采用（BMP 绝大多数字母成立）；
    /// 小写会展开成多码元的罕见字符（如 U+0130）保持原样——宁可拒绝也不引入错位，
    /// 不产生任何模糊匹配。代理对半区无对应 Unicode 标量，原样通过。
    private static func lowercaseUnit(_ unit: UInt16) -> UInt16 {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return unit }   // 代理半区 → 原样
        let lowered = String(scalar).lowercased()
        guard lowered.utf16.count == 1, let first = lowered.utf16.first else { return unit }
        return first
    }

    // MARK: - 命中查找（全量，不做「取第一个」）

    /// needle 在 haystack 中的全部起始位置（朴素扫描；块长 ≤ 约 400 字，规模无关紧要）。
    private static func occurrences(of needle: [UInt16], in haystack: [UInt16]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var hits: [Int] = []
        let needleCount = needle.count
        let limit = haystack.count - needleCount
        var index = 0
        while index <= limit {
            if haystack[index] == needle[0] {
                var matched = true
                var offset = 1
                while offset < needleCount {
                    if haystack[index + offset] != needle[offset] { matched = false; break }
                    offset += 1
                }
                if matched { hits.append(index) }
            }
            index += 1
        }
        return hits
    }
}

// MARK: - String UTF-16 工具（private）

private extension String {

    /// 精确子串的全部 UTF-16 命中范围（字面比较，不折叠、忽略大小写一律不做）。
    func allUTF16Ranges(of other: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let view = utf16
        var searchStart = startIndex
        while let found = range(of: other, range: searchStart..<endIndex) {
            let start = view.distance(from: view.startIndex, to: found.lowerBound.samePosition(in: view)!)
            ranges.append(start..<(start + other.utf16.count))
            searchStart = found.upperBound
            if other.isEmpty { break }
        }
        return ranges
    }

    /// 按 UTF-16 范围取原文子串（越界/切割代理对时由 String(decoding:) 容错为替换字符，
    /// 但本文件所有范围都来自原文自身的映射，正常不会发生）。
    func substring(utf16Range: Range<Int>) -> String? {
        let view = utf16
        guard let start = view.index(view.startIndex, offsetBy: utf16Range.lowerBound, limitedBy: view.endIndex),
              let end = view.index(start, offsetBy: utf16Range.count, limitedBy: view.endIndex) else { return nil }
        return String(decoding: view[start..<end], as: UTF16.self)
    }
}
