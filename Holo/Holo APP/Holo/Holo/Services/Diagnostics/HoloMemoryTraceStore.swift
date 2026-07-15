#if DEBUG
//
//  HoloMemoryTraceStore.swift
//  Holo
//
//  Debug-only 记忆诊断轨迹。只保存元数据，不保存问题或记忆正文。
//

import Foundation

nonisolated enum HoloMemoryTraceCategory: String, Codable, Sendable {
    case querySelection
    case domainPipeline
}

nonisolated struct HoloMemoryTraceEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var category: HoloMemoryTraceCategory
    var queryFingerprint: String?
    var route: String?
    var selectedMemoryIDs: [String]
    var refreshDecision: String?
    var requiresDetailData: Bool?
    var domain: String?
    var signalCount: Int?
    var packageRecordCount: Int?
    var validatorAcceptedCount: Int?
    var plannedMutationCount: Int?
}

actor HoloMemoryTraceStore {
    static let shared = HoloMemoryTraceStore()

    private let maximumEntries: Int
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [HoloMemoryTraceEntry] = []

    init(
        maximumEntries: Int = 500,
        retention: TimeInterval = 7 * 86_400,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.retention = max(0, retention)
        self.now = now
    }

    func appendSelection(
        _ trace: HoloMemorySelectionTrace,
        question: String
    ) {
        append(HoloMemoryTraceEntry(
            id: UUID(),
            createdAt: now(),
            category: .querySelection,
            queryFingerprint: Self.fingerprint(question),
            route: trace.route,
            selectedMemoryIDs: trace.selectedMemoryIDs,
            refreshDecision: trace.refreshDecision,
            requiresDetailData: trace.requiresDetailData,
            domain: nil,
            signalCount: nil,
            packageRecordCount: nil,
            validatorAcceptedCount: nil,
            plannedMutationCount: nil
        ))
    }

    func appendDomainPipeline(
        domain: HoloMemoryDomain,
        signalCount: Int,
        packageRecordCount: Int,
        validatorAcceptedCount: Int,
        plannedMutationCount: Int
    ) {
        append(HoloMemoryTraceEntry(
            id: UUID(),
            createdAt: now(),
            category: .domainPipeline,
            queryFingerprint: nil,
            route: nil,
            selectedMemoryIDs: [],
            refreshDecision: nil,
            requiresDetailData: nil,
            domain: domain.rawValue,
            signalCount: max(0, signalCount),
            packageRecordCount: max(0, packageRecordCount),
            validatorAcceptedCount: max(0, validatorAcceptedCount),
            plannedMutationCount: max(0, plannedMutationCount)
        ))
    }

    func snapshot() -> [HoloMemoryTraceEntry] {
        prune(referenceDate: now())
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func redactedExportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot())
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private func append(_ entry: HoloMemoryTraceEntry) {
        entries.append(entry)
        prune(referenceDate: entry.createdAt)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    private func prune(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-retention)
        entries.removeAll { $0.createdAt < cutoff }
    }

    private nonisolated static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "q:\(String(hash, radix: 16)):len:\(value.count)"
    }
}
#endif
