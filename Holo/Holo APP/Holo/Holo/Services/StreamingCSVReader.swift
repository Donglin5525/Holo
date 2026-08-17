//
//  StreamingCSVReader.swift
//  Holo
//
//  流式 CSV 读取器 — 按块读取文件，逐行 yield，内存恒定与文件大小无关
//
//  解决问题：原 readFileContent 用 String(contentsOf:) 把整个文件一次性读进内存，
//  几万条 CSV 会导致内存峰值过高、被系统 jetsman 杀进程。
//
//  本读取器用 FileHandle 按固定大小（64KB）逐块读取，维护一个跨块的"未完成记录"缓冲，
//  每凑齐一条完整记录就回调。同时跟踪引号状态，正确处理引号内的换行符。
//

import Foundation

/// 流式 CSV 读取器
///
/// 使用方式：
/// ```swift
/// try StreamingCSVReader.enumerateLines(in: url) { line in
///     // 每凑齐一条完整记录（可能跨多行）回调一次
/// }
/// ```
final class StreamingCSVReader {

    /// 单次读取的块大小（64KB，平衡 I/O 次数与内存）
    private static let chunkSize = 64 * 1024

    /// 多字节字符可能被块边界截断，最多保留这么多字节等下一块拼接后重试解码
    private static let maxPendingBytes = 8

    // MARK: - 公开入口

    /// 逐行枚举 CSV 记录，自动管理文件句柄
    ///
    /// - 重要：此方法是同步阻塞的，调用方应在后台线程调用。
    ///   "一条记录"指一个完整 CSV 行——如果字段值里有引号包裹的换行符，
    ///   这些换行会被合并到同一条记录，直到引号闭合。
    ///
    /// - Parameters:
    ///   - url: CSV 文件 URL
    ///   - body: 每凑齐一条完整记录时回调（原始字符串，**未做字段拆分**）
    static func enumerateLines(in url: URL, _ body: (String) throws -> Void) throws {
        try enumerateLines(in: url, maxLines: nil, body)
    }

    /// 带 readLimit 的枚举：读满 maxLines 条记录后提前返回（表头探测窗口用）
    static func enumerateLines(in url: URL, maxLines: Int?, _ body: (String) throws -> Void) throws {
        guard let maxLines else {
            try enumerateFullFile(in: url, body)
            return
        }
        var emitted = 0
        do {
            try enumerateFullFile(in: url) { line in
                try body(line)
                emitted += 1
                if emitted >= maxLines {
                    throw EarlyStop.sentinel
                }
            }
        } catch let stop as EarlyStop {
            // 正常的窗口截断，不是错误
            _ = stop
        }
    }

    private enum EarlyStop: Error { case sentinel }

    /// 完整枚举（真正干活的原实现）
    private static func enumerateFullFile(in url: URL, _ body: (String) throws -> Void) throws {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw ImportError.encodingError
        }
        // 确保文件句柄一定被关闭
        defer { try? fileHandle.close() }

        let encoding = try detectEncoding(fileHandle: fileHandle)
        // detectEncoding 读过首块并 seek 回 0，这里从头开始读

        // 跨块的未完成字节缓冲（多字节字符被截断时累积）
        var pendingData = Data()
        // 跨块的未完成记录字符串缓冲（引号未闭合时累积）
        var pendingRecord = ""
        // 是否处于引号内部
        var inQuotes = false
        // 是否已处理首块（用于剥 BOM）
        var firstChunkDone = false

        while true {
            let chunk = fileHandle.readData(ofLength: chunkSize)

            if chunk.isEmpty {
                // 文件结束，刷出缓冲剩余内容
                if !pendingRecord.isEmpty {
                    try body(firstChunkDone ? pendingRecord : stripBOM(from: pendingRecord))
                }
                return
            }

            // 先和上一块遗留的 pendingData 拼接，再尝试整体解码
            pendingData.append(chunk)
            guard let text = String(data: pendingData, encoding: encoding) else {
                // 解码失败：多字节字符在块边界被截断。
                // UTF-8 多字节字符最多 4 字节，从尾部往前去掉 1~4 字节，
                // 找到能成功解码的最长前缀喂给 feed，剩余字节留给下一块。
                // 这样绝不丢弃数据。
                let cut = findDecodablePrefixLength(in: pendingData, encoding: encoding)
                if cut > 0 {
                    let prefixData = pendingData.prefix(cut)
                    if let prefixText = String(data: prefixData, encoding: encoding) {
                        try feed(
                            text: firstChunkDone ? prefixText : stripBOM(from: prefixText),
                            pendingRecord: &pendingRecord,
                            inQuotes: &inQuotes,
                            firstChunkDone: &firstChunkDone,
                            body: body
                        )
                    }
                    pendingData = pendingData.suffix(pendingData.count - cut)
                }
                // cut == 0（整块都是残缺，极少见）→ 整块保留等下一块
                continue
            }

            // 解码成功，清空 pending
            pendingData = Data()

            let cleanText = firstChunkDone ? text : stripBOM(from: text)
            try feed(
                text: cleanText,
                pendingRecord: &pendingRecord,
                inQuotes: &inQuotes,
                firstChunkDone: &firstChunkDone,
                body: body
            )
        }
    }

    // MARK: - 编码探测

    /// 读取首块探测编码，探测后把偏移量重置回文件头
    ///
    /// 编码探测策略（按优先级）：
    /// 1. UTF-8 BOM → UTF-8
    /// 2. 尝试用 UTF-8 解码首块，成功 → UTF-8（覆盖绝大多数中文 CSV）
    /// 3. GBK / GB18030（中国用户从 Excel/Numbers 导出的常见编码）
    /// 编码探测
    ///
    /// 编码探测策略（按优先级）：
    /// 1. UTF-8 BOM → UTF-8
    /// 2. UTF-8（容忍首块尾部多字节字符截断）→ UTF-8
    /// 3. GBK / GB18030（中国用户从 Excel/Numbers 导出的常见编码）
    /// 4. Latin1 兜底（绝不失败，但中文会乱码）
    private static func detectEncoding(fileHandle: FileHandle) throws -> String.Encoding {
        let firstChunk = fileHandle.readData(ofLength: chunkSize)
        try fileHandle.seek(toOffset: 0)

        guard !firstChunk.isEmpty else { return .utf8 }

        // 1. UTF-8 BOM（EF BB BF）
        if firstChunk.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }

        // 2. UTF-8
        //    直接整体解码可能因块尾截断中文而失败，需要容忍尾部残缺。
        if isLikelyUTF8(firstChunk) {
            return .utf8
        }

        // 3. GBK / GB18030
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let gbkEncoding = String.Encoding(rawValue: cfEncoding)
        if String(data: firstChunk, encoding: gbkEncoding) != nil {
            return gbkEncoding
        }

        // 4. Latin1 兜底
        return .isoLatin1
    }

    /// 判断 data 是否大概率是 UTF-8 编码
    ///
    /// 直接 `String(data:encoding:.utf8)` 会因块尾截断多字节字符而失败。
    /// 这里去掉尾部最多 4 字节（UTF-8 最大字符长度）后重试，避免把 UTF-8 中文文件误判成 GBK。
    private static func isLikelyUTF8(_ data: Data) -> Bool {
        // 完整解码成功
        if String(data: data, encoding: .utf8) != nil { return true }
        // 去掉尾部可能残缺的 1~4 字节后重试
        for drop in 1...4 {
            if data.count <= drop { break }
            let candidate = data.prefix(data.count - drop)
            if String(data: candidate, encoding: .utf8) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - 内部

    /// 剥除 UTF-8 BOM
    private static func stripBOM(from string: String) -> String {
        string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string
    }

    /// 在 data 中找到能被 encoding 成功解码的最长前缀的字节长度
    ///
    /// 多字节字符（如 UTF-8 中文 3 字节）可能被块边界截断。
    /// 从尾部往前去掉 1~4 字节，逐个尝试，找到第一个能成功解码的前缀。
    /// UTF-8 最多 4 字节/字符，所以最多回退 4 次。
    private static func findDecodablePrefixLength(in data: Data, encoding: String.Encoding) -> Int {
        let maxTrailingBytes = 4
        for drop in 1...maxTrailingBytes {
            if data.count <= drop { return 0 }
            let candidate = data.prefix(data.count - drop)
            if String(data: candidate, encoding: encoding) != nil {
                return candidate.count
            }
        }
        return 0
    }

    /// 将一段已解码文本喂入引号状态机，切分出完整记录回调
    ///
    /// 不完整的尾部记录留在 `pendingRecord` 中等下一块拼接。
    private static func feed(
        text: String,
        pendingRecord: inout String,
        inQuotes: inout Bool,
        firstChunkDone: inout Bool,
        body: (String) throws -> Void
    ) throws {
        for char in text {
            if char == "\"" {
                inQuotes.toggle()
                pendingRecord.append(char)
            } else if (char == "\n" || char == "\r") && !inQuotes {
                // 记录结束。trim 判断空行（\r\n 会产生一条空记录，跳过）
                let trimmed = pendingRecord.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    try body(pendingRecord)
                }
                pendingRecord = ""
            } else {
                pendingRecord.append(char)
            }
        }
        // 首块处理标记放在 feed 结束，确保 BOM 剥除只对第一段生效
        firstChunkDone = true
    }
}
