//
//  HoloAgentJSONStore.swift
//  Holo
//
//  Agent V3.1 — Task 1.2 通用 JSON Store 基类（actor）
//  原子写入 · iso8601 编解码 · 损坏备份
//
//  Holo Agent 稳定执行 — Phase 1（§5.5，修 P0-5）硬化：
//  - load() 改 throws：只有 file-not-found 返回空数组；权限/数据保护/I/O 错误原样上抛
//  - 解码失败 → 隔离备份 + quarantined：此后任何 mutate/save 一律抛错，禁止空数组覆盖原文件
//  - destination 不存在时首次原子创建；replace 失败时同时保留旧文件与 temp，避免丢文件窗口
//  - 显式文件保护 .completeUntilFirstUserAuthentication（§4.2：控制面首次解锁后后台可读）
//

import Foundation

/// Agent store typed error（§5.5）：读/解码/隔离/写四类，调用方可区分处理。
enum HoloAgentStoreError: Error, Equatable {
    /// 读文件失败（权限 / 数据保护 / I/O），underlying 为底层错误描述
    case readFailed(underlying: String)
    /// 解码失败：原文件已隔离备份到 quarantinedAt，store 进入隔离态
    case decodeFailed(quarantinedAt: String)
    /// store 已隔离：禁止任何写入，防止空数组覆盖原文件
    case storeQuarantined
    /// 写盘失败
    case writeFailed(underlying: String)
}

/// Agent 持久化的通用 JSON 仓库基类。
///
/// 设计要点（见 V3.1 方案 Task 1.2 + §5.5 硬化）：
/// - `actor` 串行化读写，保证并发安全
/// - 写入走 temp file + `replaceItemAt`（首次保存直接原子 move），崩溃不留半截文件
/// - 读取仅 file-not-found 返回空；解码失败备份为 `*.backup.json` 并进入隔离态，既不吞数据也不覆盖
/// - 日期统一 `.iso8601`
/// - 文件保护默认 `.completeUntilFirstUserAuthentication`，可注入 nil 关闭（测试用）
actor HoloAgentJSONStore<Element: Codable> {

    private let fileManager: FileManager
    private let fileURL: URL
    private let backupURL: URL
    private let fileProtection: FileProtectionType?
    /// 文件保护应用器：默认 FileManager.setAttributes；测试可注入 spy 验证属性确实被写入
    ///（iOS 模拟器会静默丢弃 protectionKey，无法靠读回验证）。
    private let protectionApplier: (URL, FileProtectionType) throws -> Void
    private let replacementHandler: (URL, URL) throws -> Void

    /// 隔离标记：解码失败后置位，此后 load/mutate/save 全部抛 `storeQuarantined`。
    private var quarantinedAt: URL?

    /// 默认目录：`Application Support/Holo/Memory/Agent/`
    init(fileName: String, fileManager: FileManager = .default,
         fileProtection: FileProtectionType? = .completeUntilFirstUserAuthentication,
         protectionApplier: ((URL, FileProtectionType) throws -> Void)? = nil,
         replacementHandler: ((URL, URL) throws -> Void)? = nil) {
        self.fileManager = fileManager
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo/Memory/Agent", isDirectory: true)
        self.fileURL = dir.appendingPathComponent(fileName)
        self.backupURL = dir.appendingPathComponent(fileName + ".backup.json")
        self.fileProtection = fileProtection
        self.protectionApplier = protectionApplier ?? { url, protection in
            try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
        self.replacementHandler = replacementHandler ?? { destination, temporary in
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        }
    }

    /// 指定目录构造器：用于测试隔离，避免污染真实 Application Support。
    init(fileName: String, directory: URL, fileManager: FileManager = .default,
         fileProtection: FileProtectionType? = .completeUntilFirstUserAuthentication,
         protectionApplier: ((URL, FileProtectionType) throws -> Void)? = nil,
         replacementHandler: ((URL, URL) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.fileURL = directory.appendingPathComponent(fileName)
        self.backupURL = directory.appendingPathComponent(fileName + ".backup.json")
        self.fileProtection = fileProtection
        self.protectionApplier = protectionApplier ?? { url, protection in
            try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
        self.replacementHandler = replacementHandler ?? { destination, temporary in
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        }
    }

    /// 读取全部元素。
    /// - 仅文件不存在返回空数组；
    /// - 权限/数据保护/I/O 错误抛 `readFailed`（不得当空库，P0-5）；
    /// - 解码失败：备份损坏文件 → 置隔离态 → 抛 `decodeFailed`。
    func load() throws -> [Element] {
        if let quarantinedAt {
            throw HoloAgentStoreError.decodeFailed(quarantinedAt: quarantinedAt.path)
        }
        try recoverPendingTempIfNeeded()
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // 与 fileExists 检查之间存在竞态：文件恰好被删仍按空库处理
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return []
            }
            throw HoloAgentStoreError.readFailed(underlying: String(describing: error))
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: data)
        } catch {
            // 解码失败：旧备份先清，再备份当前损坏文件，随后进入隔离态禁止覆盖写
            quarantineCorruptedFile()
            throw HoloAgentStoreError.decodeFailed(quarantinedAt: backupURL.path)
        }
    }

    /// 原子写入：temp file 写盘 → 替换/移入目标位置，崩溃不留半截文件。
    /// destination 存在走 `replaceItemAt`；替换失败时保留原文件和完整 temp，绝不先删原文件。
    func save(_ values: [Element]) throws {
        if quarantinedAt != nil {
            throw HoloAgentStoreError.storeQuarantined
        }
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try applyFileProtection(at: dir)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(values)

            let tempURL = dir.appendingPathComponent(fileURL.lastPathComponent + ".tmp")
            try data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                // replace 失败必须上抛并保留两份文件：旧主文件继续可读，temp 供下次恢复/诊断。
                try replacementHandler(fileURL, tempURL)
            } else {
                // 首次保存：destination 不存在，replaceItemAt 会失败，直接原子 move
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
            try applyFileProtection(at: fileURL)
        } catch let error as HoloAgentStoreError {
            throw error
        } catch {
            // 不清理 temp：Data.write(.atomic) 已保证它是完整候选；保留它才能在目标缺失时恢复。
            throw HoloAgentStoreError.writeFailed(underlying: String(describing: error))
        }
    }

    /// 原子读改写：在同一 actor 隔离内 load → transform → save，
    /// 避免拆调 load/save 造成的 actor 可重入 lost-update。
    /// 闭包返回值原样回传，便于 upsert / updateState / cleanup 取结果。
    /// §5.5：load 抛错时不执行 transform、不写盘，直接上抛。
    func mutate<T>(_ transform: (inout [Element]) throws -> T) throws -> T {
        var all = try load()
        let result = try transform(&all)
        try save(all)
        return result
    }

    // MARK: - 内部

    /// 损坏文件隔离：备份为 `*.backup.json` 并置隔离态（备份失败不掩盖解码错误本身）。
    private func quarantineCorruptedFile() {
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        try? fileManager.copyItem(at: fileURL, to: backupURL)
        quarantinedAt = backupURL
    }

    /// 上次进程若在 temp 完整落盘后、移入主文件前退出，且主文件确实不存在，安全恢复 temp。
    /// 主文件仍存在时绝不自动覆盖：旧数据优先，temp 留作诊断或下一次显式保存处理。
    private func recoverPendingTempIfNeeded() throws {
        let tempURL = temporaryURL
        guard !fileManager.fileExists(atPath: fileURL.path),
              fileManager.fileExists(atPath: tempURL.path) else { return }
        do {
            try fileManager.moveItem(at: tempURL, to: fileURL)
            try applyFileProtection(at: fileURL)
        } catch {
            throw HoloAgentStoreError.readFailed(underlying: "恢复待提交 temp 失败：\(error)")
        }
    }

    private var temporaryURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".tmp")
    }

    /// 显式文件保护（§4.2）：控制面/数据面首次解锁后后台可读，保证锁屏恢复链。
    private func applyFileProtection(at url: URL) throws {
        guard let fileProtection else { return }
        try protectionApplier(url, fileProtection)
    }
}
