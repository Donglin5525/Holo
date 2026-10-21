//
//  HoloReportUnderstandingLedger.swift
//  Holo
//
//  报告理解处理台账（§8.1）：本地 JSON 文件，不进 CloudKit。
//  - 设备本地即够：多设备语义单写靠仓库幂等键（observationKey+稳定ID），
//    台账只负责本机的崩溃恢复、重扫去重与失败可解释；
//  - 崩溃窗口补偿：登记与处理之间进程退出 → 冷启动重扫 pending/running 条目
//    按来源档案重扫（R28），已 succeeded 的处理键不重跑（R02）。
//

import Foundation
import OSLog

actor HoloReportUnderstandingLedger {
    private static let logger = Logger(
        subsystem: "com.holo.app",
        category: "ReportUnderstandingLedger"
    )

    /// 台账上限：单设备滚动保留最近 N 条，超出按 updatedAt 淘汰（防无界增长）。
    private static let maxEntries = 500

    private var entries: [String: HoloReportProcessingEntry] = [:]
    private var loaded = false
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appendingPathComponent("Holo/ReportUnderstanding", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("ledger.json")
        }
    }

    // MARK: - 读写

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([HoloReportProcessingEntry].self, from: data) else {
            Self.logger.error("台账解码失败，按空台账启动（文件保留不删）")
            return
        }
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.processingKey, $0) })
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(entries.values)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("台账写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 处理键裁决

    /// 该处理键是否已有终态成功记录（模型调用前必须检查，R02/§8.4）。
    func hasSucceeded(_ processingKey: String) -> Bool {
        loadIfNeeded()
        return entries[processingKey]?.status == .succeeded
    }

    /// 该报告是否已由新链路成功拥有（旧观察器写入权切换依据，§九）。
    func isOwnedReport(canonicalReportID: String) -> Bool {
        loadIfNeeded()
        return entries.values.contains {
            $0.canonicalReportID == canonicalReportID && $0.status == .succeeded
        }
    }

    /// 全部成功条目（删除对账扫描用）。
    func allSucceeded() -> [HoloReportProcessingEntry] {
        loadIfNeeded()
        return entries.values
            .filter { $0.status == .succeeded }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 登记并认领：返回 false = 该键已在处理/已终态成功，调用方不得发起模型或写库。
    @discardableResult
    func claim(
        descriptor: HoloReportDescriptor,
        now: Date = Date()
    ) -> Bool {
        loadIfNeeded()
        if let existing = entries[descriptor.processingKey] {
            switch existing.status {
            case .succeeded, .running, .pending:
                return false
            case .deferred:
                guard now >= retryEligibleAt(existing) else { return false }
            case .rejected, .failed:
                // rejected 不重试；failed 走有限延迟重试（上限 3 次）
                guard existing.attemptCount < 3, now >= retryEligibleAt(existing) else { return false }
            }
        }
        let entry = HoloReportProcessingEntry(
            processingKey: descriptor.processingKey,
            canonicalReportID: descriptor.canonicalReportID,
            sourceKind: descriptor.sourceKind,
            status: .running,
            attemptCount: (entries[descriptor.processingKey]?.attemptCount ?? 0) + 1,
            lastError: nil,
            updatedAt: now,
            shadowStats: nil
        )
        entries[descriptor.processingKey] = entry
        evictIfNeeded()
        save()
        return true
    }

    func markSucceeded(_ processingKey: String, stats: HoloReportShadowStats?, now: Date = Date()) {
        loadIfNeeded()
        guard var entry = entries[processingKey] else { return }
        entry.status = .succeeded
        entry.shadowStats = stats
        entry.lastError = nil
        entry.updatedAt = now
        entries[processingKey] = entry
        save()
    }

    func markRejected(_ processingKey: String, reason: String, now: Date = Date()) {
        loadIfNeeded()
        finish(processingKey, status: .rejected, reason: reason, now: now)
    }

    func markDeferred(_ processingKey: String, reason: String, now: Date = Date()) {
        loadIfNeeded()
        finish(processingKey, status: .deferred, reason: reason, now: now)
    }

    func markFailed(_ processingKey: String, reason: String, now: Date = Date()) {
        loadIfNeeded()
        finish(processingKey, status: .failed, reason: reason, now: now)
    }

    private func finish(
        _ processingKey: String,
        status: HoloReportProcessingStatus,
        reason: String,
        now: Date
    ) {
        guard var entry = entries[processingKey] else { return }
        entry.status = status
        entry.lastError = String(reason.prefix(200))
        entry.updatedAt = now
        entries[processingKey] = entry
        save()
    }

    /// deferred/failed 的重试等待：指数退避 5min/15min/60min（封顶）。
    private func retryEligibleAt(_ entry: HoloReportProcessingEntry) -> Date {
        let intervals: [TimeInterval] = [300, 900, 3_600]
        let index = min(max(entry.attemptCount - 1, 0), intervals.count - 1)
        return entry.updatedAt.addingTimeInterval(intervals[index])
    }

    private func evictIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let doomed = entries.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(entries.count - Self.maxEntries)
        for entry in doomed where entry.status == .succeeded || entry.status == .rejected {
            entries.removeValue(forKey: entry.processingKey)
        }
    }

    // MARK: - 重扫

    /// 冷启动重扫候选：非终态成功、仍在有限重试窗口内的报告。
    func rescanCandidates(now: Date = Date()) -> [HoloReportProcessingEntry] {
        loadIfNeeded()
        return entries.values.filter { entry in
            switch entry.status {
            case .pending, .running:
                return true
            case .deferred, .failed:
                return entry.attemptCount < 3 && now >= retryEligibleAt(entry)
            case .succeeded, .rejected:
                return false
            }
        }
    }
}
