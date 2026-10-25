//
//  GlobalExportService.swift
//  Holo
//
//  全局数据导出 —— 把三个本地库（主库 / 敏感记忆库 / Discovery 库）的全部实体
//  打包为一个 ZIP 备份文件（2026-10-25 方案：一期只导出，含敏感记忆）
//
//  结构性保证：
//  · 实体清单动态取自 managedObjectModel —— 模型加新实体导出自动覆盖，不手写清单
//  · 逐实体 fetchBatchSize 分批、逐行流式写 JSON，内存占用 ≈ 单条记录
//  · 二进制列落 blobs/ 独立文件（缩略图等派生数据除外），JSON 行内记相对路径
//  · 关系只导对端行键（优先 id 属性），自引用 / 多对多环在导出侧无嵌套风险
//
//  产物结构（Holo备份_日期_时间.zip）：
//    manifest.json   格式版本 / App 版本 / 各来源实体计数 / 跳过项说明
//    data/<来源>/<实体>.json
//    blobs/<来源>/<实体>/<行键>/<属性>.bin
//    finance.csv     复用财务导出（人类可读）
//    README.txt
//

import Foundation
import CoreData
import ZIPFoundation

// MARK: - 数据源与进度

/// 一个待导出的物理库。容器本身线程安全（NSPersistentContainer），
/// 具体读写全部在各自 backgroundContext 的队列上执行。
struct GlobalExportSource: @unchecked Sendable {
    /// ZIP 内目录名兼 manifest 键：main / sensitive / discovery
    let name: String
    /// 进度 UI 展示名
    let displayName: String
    let container: NSPersistentContainer
}

struct GlobalExportProgress: Sendable {
    enum Phase: Sendable { case exporting, packaging }

    let phase: Phase
    let sourceIndex: Int
    let sourceCount: Int
    /// 进度文案用（「正在导出：敏感记忆」），不展示实体技术名
    let sourceDisplayName: String
    /// 导出阶段为全局实体序（跨来源累计），打包阶段无意义
    let fraction: Double
}

// MARK: - GlobalExportService

nonisolated final class GlobalExportService {

    struct ExportResult: Sendable {
        let fileURL: URL
        /// 来源名 → 实体名 → 行数
        let entityCounts: [String: [String: Int]]
        let exportedBytes: Int
    }

    /// 财务 CSV 提供方（默认复用既有财务导出；测试注入假实现避免触真栈）
    typealias FinanceCSVProvider = @Sendable () async throws -> String?

    private let sources: [GlobalExportSource]
    private let financeCSVProvider: FinanceCSVProvider

    init(
        sources: [GlobalExportSource],
        financeCSVProvider: @escaping FinanceCSVProvider = {
            try await DataExportService.shared.exportToCSV()
        }
    ) {
        self.sources = sources
        self.financeCSVProvider = financeCSVProvider
    }

    /// 生产数据源：主库（CloudKit 同步的 63 实体）+ 敏感记忆库（仅本机）+ Discovery 库。
    /// Discovery 库打不开时跳过（非核心数据不阻塞全局导出），manifest 如实缺席。
    static func liveSources() async throws -> [GlobalExportSource] {
        await CoreDataStack.shared.waitUntilReady()
        var sources: [GlobalExportSource] = [
            GlobalExportSource(
                name: "main",
                displayName: "主数据",
                container: CoreDataStack.shared.persistentContainer
            )
        ]
        // 敏感记忆不上 iCloud，导出是带走这批数据的唯一途径（2026-10-25 东林拍板：包含）
        let memoryController = try await HoloMemoryRuntime.shared.persistenceController()
        sources.append(
            GlobalExportSource(
                name: "sensitive",
                displayName: "敏感记忆",
                container: memoryController.sensitiveContainer
            )
        )
        if let discovery = try? DiscoveryStore() {
            sources.append(
                GlobalExportSource(
                    name: "discovery",
                    displayName: "发现数据",
                    container: discovery.persistentContainer
                )
            )
        }
        return sources
    }

    // MARK: - 主流程

    func exportAll(
        progress: (@Sendable (GlobalExportProgress) -> Void)? = nil
    ) async throws -> ExportResult {
        try Task.checkCancellation()

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-global-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let totalEntities = sources.reduce(0) { $0 + $1.container.managedObjectModel.entities.count }
        var processedEntities = 0
        var entityCounts: [String: [String: Int]] = [:]
        var exportedBytes = 0

        for (sourceIndex, source) in sources.enumerated() {
            let entities = source.container.managedObjectModel.entities
                .compactMap { $0.name }
                .sorted()
            for (entityIndex, entityName) in entities.enumerated() {
                try Task.checkCancellation()
                progress?(GlobalExportProgress(
                    phase: .exporting,
                    sourceIndex: sourceIndex,
                    sourceCount: sources.count,
                    sourceDisplayName: source.displayName,
                    fraction: Double(processedEntities) / Double(max(totalEntities, 1))
                ))
                let (count, bytes) = try await exportEntity(
                    entityName: entityName,
                    source: source,
                    workDirPath: workDir.path
                )
                entityCounts[source.name, default: [:]][entityName] = count
                exportedBytes += bytes
                processedEntities += 1
            }
        }

        try Task.checkCancellation()
        progress?(GlobalExportProgress(
            phase: .packaging,
            sourceIndex: sources.count - 1,
            sourceCount: sources.count,
            sourceDisplayName: "",
            fraction: 0.97
        ))

        try await writeFinanceCSV(to: workDir)
        try writeManifest(entityCounts: entityCounts, to: workDir)
        try Self.writeReadme(to: workDir)

        let zipURL = try packageZIP(workDir: workDir)
        return ExportResult(fileURL: zipURL, entityCounts: entityCounts, exportedBytes: exportedBytes)
    }

    // MARK: - 单实体导出

    /// 逐实体流式导出：`[` + 逗号分隔的行 JSON（行间换行，便于人工 diff）+ `]`。
    /// 返回 (行数, JSON 字节数)；blob 字节数不计入（单独落文件）。
    private func exportEntity(
        entityName: String,
        source: GlobalExportSource,
        workDirPath: String
    ) async throws -> (count: Int, bytes: Int) {
        let dataDir = URL(fileURLWithPath: workDirPath)
            .appendingPathComponent("data/\(source.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let fileURL = dataDir.appendingPathComponent("\(entityName).json")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        let writer = RowWriter(handle: handle)

        let context = source.container.newBackgroundContext()
        let sourceName = source.name
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.fetchBatchSize = 500
            let objects = try context.fetch(request)

            try writer.write(Data("[".utf8))
            var count = 0
            var bytes = 0
            for object in objects {
                let row = try Self.rowJSON(
                    for: object,
                    sourceName: sourceName,
                    workDirPath: workDirPath
                )
                let data = try JSONSerialization.data(
                    withJSONObject: row,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
                if count > 0 { try writer.write(Data(",".utf8)) }
                try writer.write(data)
                try writer.write(Data("\n".utf8))
                count += 1
                bytes += data.count
            }
            try writer.write(Data("]".utf8))
            return (count, bytes)
        }
    }

    // MARK: - 行序列化

    private struct RowWriter: @unchecked Sendable {
        let handle: FileHandle
        func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
        }
    }

    /// 一行 → JSON 字典。属性按类型转换；binary 落 blobs/ 后在行内记引用；
    /// 关系取对端行键（to-many 排序保证输出稳定）。
    private static func rowJSON(
        for object: NSManagedObject,
        sourceName: String,
        workDirPath: String
    ) throws -> [String: Any] {
        let entity = object.entity
        guard let entityName = entity.name else {
            throw ExportError.entityWithoutName
        }
        let key = rowKey(of: object)
        var row: [String: Any] = [:]

        for (attrName, attr) in entity.attributesByName {
            if attr.attributeType == .binaryDataAttributeType {
                // 缩略图可由原图再生，跳过以控制备份体积（manifest 有说明）
                guard attrName != "thumbnailData" else { continue }
                guard let data = object.value(forKey: attrName) as? Data, !data.isEmpty else { continue }
                let relative = "blobs/\(sourceName)/\(entityName)/\(key)/\(attrName).bin"
                let url = URL(fileURLWithPath: workDirPath).appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url)
                row[attrName] = ["__file": relative, "bytes": data.count]
            } else {
                row[attrName] = jsonValue(object.value(forKey: attrName)) ?? NSNull()
            }
        }

        for (relName, rel) in entity.relationshipsByName {
            if rel.isToMany {
                let targets = (object.value(forKey: relName) as? Set<NSManagedObject>) ?? []
                row[relName] = targets
                    .map { rowKey(of: $0) }
                    .sorted()
            } else if let target = object.value(forKey: relName) as? NSManagedObject {
                row[relName] = rowKey(of: target)
            } else {
                row[relName] = NSNull()
            }
        }
        return row
    }

    /// 行键：优先 id 属性（UUID / String），兜底 objectID URI（无 id 的技术实体）。
    /// 关系引用与 blob 目录共用，保证一键一义。
    private static func rowKey(of object: NSManagedObject) -> String {
        if object.entity.attributesByName["id"] != nil {
            let value = object.value(forKey: "id")
            if let uuid = value as? UUID { return uuid.uuidString }
            if let string = value as? String, !string.isEmpty { return safeFilename(string) }
        }
        return safeFilename(object.objectID.uriRepresentation().absoluteString)
    }

    private static func safeFilename(_ string: String) -> String {
        String(string.map { character in
            (character.isLetter || character.isNumber || character == "-" || character == "_")
                ? character : "_"
        })
    }

    /// 属性值 → JSON 可序列化值。Date 用 ISO8601（毫秒）；NSArray/NSDictionary 递归
    /// （transformable 的 tags 等）；无法表达的类型记 `__unknown` 诊断信息不静默丢。
    private static func jsonValue(_ value: Any?) -> Any? {
        switch value {
        case nil:
            return nil
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let date as Date:
            return isoFormatter.string(from: date)
        case let uuid as UUID:
            return uuid.uuidString
        case let url as URL:
            return url.absoluteString
        case let array as NSArray:
            return array.map { jsonValue($0) ?? NSNull() }
        case let dict as NSDictionary:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[String(describing: k)] = jsonValue(v) ?? NSNull()
            }
            return out
        default:
            return [
                "__unknown": String(describing: type(of: value)),
                "value": String(describing: value),
            ]
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - 附属文件

    private func writeFinanceCSV(to workDir: URL) async throws {
        guard let csv = try await financeCSVProvider() else { return }
        let bom = "\u{FEFF}"
        guard let data = (bom + csv).data(using: .utf8) else { return }
        try data.write(to: workDir.appendingPathComponent("finance.csv"))
    }

    private struct Manifest: Codable {
        let formatVersion: Int
        let appVersion: String
        let buildNumber: String
        let exportedAt: String
        let includesSensitiveMemory: Bool
        let sources: [String: [String: Int]]
        let skipped: [String: String]
    }

    private func writeManifest(
        entityCounts: [String: [String: Int]],
        to workDir: URL
    ) throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let manifest = Manifest(
            formatVersion: 1,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info["CFBundleVersion"] as? String ?? "",
            exportedAt: Self.isoFormatter.string(from: Date()),
            includesSensitiveMemory: entityCounts["sensitive"] != nil,
            sources: entityCounts,
            skipped: [
                "thumbnailData": "缩略图可由原图再生，未包含",
                "keychain": "API 密钥出于安全考虑不导出",
                "healthKit": "健康数据在系统健康 App 中，不在 App 数据库内",
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: workDir.appendingPathComponent("manifest.json"))
    }

    private static func writeReadme(to workDir: URL) throws {
        let readme = """
        Holo 全量备份
        ==============

        这是你主动导出的全部 App 数据，包含：
        · data/ 目录：财务、任务、想法、习惯、目标、纪念日、聊天、记忆等全部模块数据（JSON 格式）
        · blobs/ 目录：附件图片、头像、记忆正文等二进制文件
        · finance.csv：账单的人类可读版（可用 Excel 打开）
        · manifest.json：导出清单（时间、版本、各模块条数）

        注意：
        · 本文件包含「敏感记忆」（仅存在本机、不参与 iCloud 同步的那部分），请妥善保管
        · 健康数据在系统健康 App 中，不在本备份里；API 密钥出于安全不导出
        · 当前版本（一期）仅支持导出，暂不支持从本文件恢复导入

        生成时间与详细清单见 manifest.json。
        """
        try readme.data(using: .utf8)!.write(to: workDir.appendingPathComponent("README.txt"))
    }

    // MARK: - 打包

    private func packageZIP(workDir: URL) throws -> URL {
        let timestamp = Self.fileTimestampFormatter.string(from: Date())
        let zipName = "Holo备份_\(timestamp).zip"
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(zipName)

        // 覆盖同名产物；顺带清掉更早的备份 ZIP，防临时目录堆积
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        let previousBackups = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for stale in previousBackups
        where stale.lastPathComponent.hasPrefix("Holo备份_") && stale.pathExtension == "zip" {
            try? FileManager.default.removeItem(at: stale)
        }

        let archive = try Archive(url: zipURL, accessMode: .create)
        let enumerator = FileManager.default.enumerator(
            at: workDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let root = workDir.path + "/"
        while let next = enumerator?.nextObject() as? URL {
            guard (try? next.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            let relative = next.path.replacingOccurrences(of: root, with: "")
            try archive.addEntry(with: relative, relativeTo: workDir)
        }
        return zipURL
    }

    /// 备份文件名时间戳（本地时区 yyyyMMdd_HHmm）
    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    enum ExportError: Error {
        case entityWithoutName
    }
}
