//
//  HoloContextSourceReader.swift
//  Holo
//
//  通用个人情境的来源读取（实施方案 §6）。
//
//  - 分页以 (updatedAt, sourceID) 稳定排序；固定批次 watermark，批次期间新修改进下一批。
//  - 长文切分：按段落聚合，段上限可配（默认 1,800 字符），跨段引用只算同一来源。
//  - 富文本统一转纯文本；不可解析附件标记覆盖缺口，不编造内容。
//  - 读取前检查权限、学习基线（基线之前的来源不补建）与 suppression。
//  - 本文件为纯逻辑核心；Core Data 分页与变更队列的接线由调用方实现
//    HoloContextSourcePaging 协议注入。
//

import Foundation

// MARK: - 长文切分

nonisolated struct HoloContextSegment: Equatable, Sendable {
    var sourceID: String
    var revision: String
    /// 规范化纯文本内的 UTF-16 范围（location + length）。
    var utf16Location: Int
    var utf16Length: Int
    var text: String

    var utf16RangeEnd: Int { utf16Location + utf16Length }
}

nonisolated enum HoloContextSegmenter {
    /// 段上限与包预算的默认值（方案 §6：段 1,800 字符、每包 12 段、合计 12,000 字符）。
    static let defaultSegmentCharacterLimit = 1_800
    static let defaultPackageSegmentLimit = 12
    static let defaultPackageCharacterLimit = 12_000
    /// 相邻段之间的重叠字符数：保留跨段上下文，不引入新语义。
    static let overlapCharacters = 0

    /// 按段落聚合切分：空行/换行分段，段聚合不超过 limit；超长单段硬切。
    /// 段边界取整到换行；UTF-16 位置相对规范化纯文本。
    static func segments(
        for snapshot: HoloContextSourceSnapshot,
        segmentLimit: Int = defaultSegmentCharacterLimit
    ) -> [HoloContextSegment] {
        let plain = snapshot.plainText
        let total = plain.utf16.count
        guard total > 0 else { return [] }

        // 按换行切段（保留换行在段内），聚合相邻段直到超限。
        var lines: [String] = []
        var lineStart = plain.startIndex
        for index in plain.indices {
            if plain[index] == "\n" {
                lines.append(String(plain[lineStart...index]))
                lineStart = plain.index(after: index)
            }
        }
        if lineStart < plain.endIndex {
            lines.append(String(plain[lineStart...]))
        }
        if lines.isEmpty { lines.append(plain) }

        var pieces: [(text: String, location: Int)] = []
        var cursor = 0 // UTF-16 计数
        var buffer = ""
        var bufferStart = 0
        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            pieces.append((buffer, bufferStart))
            buffer = ""
        }
        for line in lines {
            let lineUTF16 = line.utf16.count
            if lineUTF16 > segmentLimit {
                // 超长单段硬切。
                flushBuffer()
                var offset = 0
                let chars = Array(line)
                while offset < chars.count {
                    let chunkLength = min(segmentLimit, chars.count - offset)
                    let chunk = String(chars[offset..<(offset + chunkLength)])
                    pieces.append((chunk, cursor + offset))
                    offset += chunkLength
                }
                cursor += lineUTF16
                bufferStart = cursor
                continue
            }
            if buffer.utf16.count + lineUTF16 > segmentLimit {
                flushBuffer()
                bufferStart = cursor
            }
            if buffer.isEmpty { bufferStart = cursor }
            buffer += line
            cursor += lineUTF16
        }
        flushBuffer()

        return pieces.map { piece in
            HoloContextSegment(
                sourceID: snapshot.sourceID,
                revision: snapshot.revisionDigest,
                utf16Location: piece.location,
                utf16Length: piece.text.utf16.count,
                text: piece.text
            )
        }
    }

    /// 组装萃取输入包：多来源段合并，受包预算约束（段数/字符数），返回剩余段供下一包。
    static func packageSegments(
        _ segments: [HoloContextSegment],
        packageSegmentLimit: Int = defaultPackageSegmentLimit,
        packageCharacterLimit: Int = defaultPackageCharacterLimit
    ) -> (package: [HoloContextSegment], remainder: [HoloContextSegment]) {
        var selected: [HoloContextSegment] = []
        var used = 0
        for (index, segment) in segments.enumerated() {
            if selected.count >= packageSegmentLimit { return (selected, Array(segments[index...])) }
            let length = segment.text.utf16.count
            if !selected.isEmpty && used + length > packageCharacterLimit {
                return (selected, Array(segments[index...]))
            }
            selected.append(segment)
            used += length
        }
        return (selected, [])
    }
}

// MARK: - 富文本规范化（纯逻辑部分）

/// 统一富文本 → 纯文本：剥离 Markdown 标记，附件只标记覆盖缺口不编造内容。
nonisolated enum HoloContextPlainTextNormalizer {
    static func normalize(_ raw: String) -> (plainText: String, coverageGaps: [String]) {
        var gaps: [String] = []
        var text = raw
        // 附件占位：现有想法富文本用 [[attachment:…]] 风格占位符；无法解析的媒体只记缺口。
        if text.contains("[[attachment:") {
            text = text.replacingOccurrences(of: #"\[\[attachment:[^\]]*\]\]"#, with: " ", options: .regularExpression)
            gaps.append("attachment-not-transcribed")
        }
        if text.contains("[[image") || text.contains("[[file") {
            text = text.replacingOccurrences(of: #"\[\[(image|file)[^\]]*\]\]"#, with: " ", options: .regularExpression)
            gaps.append("media-not-transcribed")
        }
        // 常见 Markdown 装饰剥离（保留语义文本）。
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\w)\*([^*\n]+)\*(?!\w)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"~~([^~]+)~~"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // 折叠连续空白（保留换行结构）。
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), gaps)
    }
}

// MARK: - 分页协议（接线由调用方实现）

/// 来源分页：以 (updatedAt, sourceID) 稳定排序的游标分页。
/// Core Data / 业务仓库适配器实现本协议后注入萃取编排器。
nonisolated protocol HoloContextSourcePaging: Sendable {
    /// 读取一页来源快照。
    /// - Parameters:
    ///   - after: 上一页末尾的游标（nil 表示从头）。
    ///   - limit: 页大小（方案默认 50）。
    ///   - baseline: 学习基线；基线之前的来源不返回（用户清空后不得偷偷读回）。
    func fetchContextSourcePage(
        after cursor: HoloContextSourceCursor?,
        limit: Int,
        baseline: Date?
    ) async throws -> (sources: [HoloContextSourceSnapshot], nextCursor: HoloContextSourceCursor?)
}

/// 稳定游标：(updatedAt, sourceID)。
nonisolated struct HoloContextSourceCursor: Equatable, Sendable, Codable {
    var updatedAt: Date
    var sourceID: String
}

/// 内存分页实现（standalone 测试与预检用）。
nonisolated struct HoloContextInMemorySourcePaging: HoloContextSourcePaging {
    var sources: [HoloContextSourceSnapshot]

    func fetchContextSourcePage(
        after cursor: HoloContextSourceCursor?,
        limit: Int,
        baseline: Date?
    ) async throws -> (sources: [HoloContextSourceSnapshot], nextCursor: HoloContextSourceCursor?) {
        var eligible: [HoloContextSourceSnapshot] = []
        for source in sources {
            if let baseline, source.sourceUpdatedAt < baseline { continue }
            eligible.append(source)
        }
        eligible.sort { lhs, rhs in
            if lhs.sourceUpdatedAt == rhs.sourceUpdatedAt {
                return lhs.sourceID < rhs.sourceID
            }
            return lhs.sourceUpdatedAt < rhs.sourceUpdatedAt
        }
        var startIndex = 0
        if let cursor {
            if let cursorIndex = eligible.firstIndex(where: { source in
                source.sourceUpdatedAt == cursor.updatedAt && source.sourceID == cursor.sourceID
            }) {
                startIndex = cursorIndex + 1
            }
        }
        let endIndex = min(startIndex + limit, eligible.count)
        let page = startIndex < endIndex ? Array(eligible[startIndex..<endIndex]) : []
        let next = page.last.map {
            HoloContextSourceCursor(updatedAt: $0.sourceUpdatedAt, sourceID: $0.sourceID)
        }
        let hasMore = endIndex < eligible.count
        return (page, hasMore ? next : nil)
    }
}
