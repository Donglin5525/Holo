//
//  HoloAgentJSONStore.swift
//  Holo
//
//  Agent V3.1 — Task 1.2 通用 JSON Store 基类（actor）
//  原子写入 · iso8601 编解码 · 损坏备份
//

import Foundation

/// Agent 持久化的通用 JSON 仓库基类。
///
/// 设计要点（见 V3.1 方案 Task 1.2）：
/// - `actor` 串行化读写，保证并发安全
/// - 写入走 temp file + `replaceItemAt`，崩溃不留半截文件
/// - 读取遇损坏：备份为 `*.backup.json` 后返回空，既不吞数据也不崩
/// - 日期统一 `.iso8601`
actor HoloAgentJSONStore<Element: Codable> {

    private let fileManager: FileManager
    private let fileURL: URL
    private let backupURL: URL

    /// 默认目录：`Application Support/Holo/Memory/Agent/`
    init(fileName: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo/Memory/Agent", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(fileName)
        self.backupURL = dir.appendingPathComponent(fileName + ".backup.json")
    }

    /// 指定目录构造器：用于测试隔离，避免污染真实 Application Support。
    init(fileName: String, directory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = directory.appendingPathComponent(fileName)
        self.backupURL = directory.appendingPathComponent(fileName + ".backup.json")
    }

    /// 读取全部元素；文件不存在或损坏时返回空数组（损坏会先备份）。
    func load() -> [Element] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: data)
        } catch {
            // 损坏：旧备份先清，再备份当前损坏文件，便于事后排查
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try? fileManager.copyItem(at: fileURL, to: backupURL)
            return []
        }
    }

    /// 原子写入：temp file 写盘 → `replaceItemAt` 替换，崩溃不留半截文件。
    func save(_ values: [Element]) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(values)

        let tempURL = dir.appendingPathComponent(fileURL.lastPathComponent + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
    }

    /// 原子读改写：在同一 actor 隔离内 load → transform → save，
    /// 避免拆调 load/save 造成的 actor 可重入 lost-update。
    /// 闭包返回值原样回传，便于 upsert / updateState / cleanup 取结果。
    func mutate<T>(_ transform: (inout [Element]) throws -> T) throws -> T {
        var all = load()
        let result = try transform(&all)
        try save(all)
        return result
    }
}
