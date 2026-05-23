//
//  MemoryInsightDebugLogService.swift
//  Holo
//
//  洞察反馈 dataWrong 事件本地日志
//  保留最近 50 条，不进入偏好画像
//

import Foundation
import os.log

struct InsightDebugEntry: Codable, Identifiable {
    let id: UUID
    let insightId: UUID
    let cardId: String?
    let userCorrection: String?
    let module: String?
    let createdAt: Date
}

final class MemoryInsightDebugLogService {
    static let shared = MemoryInsightDebugLogService()

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightDebugLog")

    private let maxEntries = 50
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo", isDirectory: true)
        return dir.appendingPathComponent("InsightDebugLog.json")
    }()

    private var entries: [InsightDebugEntry] = []

    private init() {
        load()
    }

    /// 记录 dataWrong 事件
    func logDataWrong(
        insightId: UUID,
        cardId: String?,
        userCorrection: String?,
        module: String?
    ) {
        let entry = InsightDebugEntry(
            id: UUID(),
            insightId: insightId,
            cardId: cardId,
            userCorrection: userCorrection,
            module: module,
            createdAt: Date()
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries = entries.suffix(maxEntries)
        }
        save()
        Self.logger.info("dataWrong 日志已记录：insightId=\(insightId)")
    }

    /// 读取所有日志
    func fetchAll() -> [InsightDebugEntry] {
        entries
    }

    /// 清除所有日志
    func clearAll() {
        entries = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([InsightDebugEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
