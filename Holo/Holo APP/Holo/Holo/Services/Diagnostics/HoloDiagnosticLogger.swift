//
//  HoloDiagnosticLogger.swift
//  Holo
//
//  诊断日志文件管理：按天写文件、自动清理过期日志、导出汇总。
//

import Foundation

/// 诊断日志文件管理器。按天一个文件，保留 7 天，自动清理过期。
final class HoloDiagnosticLogger {

    static let shared = HoloDiagnosticLogger()

    /// 最多保留天数。
    private let retentionDays = 7

    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    // MARK: - 目录

    /// 日志根目录：Application Support/diagnostics/
    private var directoryURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support.appendingPathComponent("diagnostics", isDirectory: true)
    }

    private func ensureDirectory() throws -> URL {
        let url = directoryURL
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: - 写入

    /// 追加一条诊断记录到当天的日志文件。
    func append(category: String, _ content: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(content)\n"

        do {
            let dir = try ensureDirectory()
            let fileURL = dir.appendingPathComponent("holo-diagnostic-\(dateFormatter.string(from: Date())).txt")

            if fileManager.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    try? handle.seekToEnd()
                    if let data = line.data(using: .utf8) {
                        try? handle.write(contentsOf: data)
                    }
                    try? handle.close()
                }
            } else {
                try line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // 日志写入失败不能影响主流程，静默忽略
        }
    }

    // MARK: - 清理

    /// 删除超过保留期的日志文件。启动时调用一次。
    func cleanExpiredLogs() {
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let cutoffKey = dateFormatter.string(from: cutoff)

        for filename in filenames where filename.hasPrefix("holo-diagnostic-") {
            // 文件名格式 holo-diagnostic-2026-08-07.txt，取日期部分比较
            let datePart = filename
                .replacingOccurrences(of: "holo-diagnostic-", with: "")
                .replacingOccurrences(of: ".txt", with: "")
            if datePart < cutoffKey {
                let fileURL = directoryURL.appendingPathComponent(filename)
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - 导出

    /// 汇总所有日志文件内容，供邮件附件导出。
    /// 返回 (合并文本, 临时文件 URL)。临时文件用完由系统清理。
    func exportAllLogs() -> (summary: String, fileURL: URL?)? {
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path),
              !filenames.isEmpty else {
            return ("（暂无诊断日志）", nil)
        }

        let sorted = filenames.sorted()
        var combined = ""

        for filename in sorted where filename.hasPrefix("holo-diagnostic-") {
            let fileURL = directoryURL.appendingPathComponent(filename)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                combined += "========== \(filename) ==========\n\(content)\n\n"
            }
        }

        if combined.isEmpty {
            combined = "（诊断日志为空）"
        }

        // 写到临时文件供邮件附件使用
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("holo-diagnostic-export.txt")
        do {
            try combined.write(to: tempURL, atomically: true, encoding: .utf8)
            return (combined, tempURL)
        } catch {
            return (combined, nil)
        }
    }
}
