#if DEBUG || INTERNAL_DIAGNOSTICS
import Foundation

struct HoloInternalLogRecord: Codable, Equatable {
    let messageId: UUID
    let requestId: String
    let capturedAt: Date
    let log: LLMLog
}

final class HoloInternalLogStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let directoryURL: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        let applicationSupport = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("HoloInternalDiagnostics", isDirectory: true)
        self.directoryURL = applicationSupport
        self.fileURL = applicationSupport.appendingPathComponent("ai-logs.json")
        self.fileManager = fileManager
        self.now = now
    }

    func save(_ record: HoloInternalLogRecord) throws {
        try prepareDirectory()
        var records = loadRecords().filter { $0.messageId != record.messageId }
        records.append(record)
        try write(records: prune(records))
    }

    func log(for messageId: UUID) -> LLMLog? {
        let records = prune(loadRecords())
        try? writeIfDirectoryExists(records: records)
        return records.last(where: { $0.messageId == messageId })?.log
    }

    func contains(messageId: UUID) -> Bool {
        log(for: messageId) != nil
    }

    func clear() {
        try? fileManager.removeItem(at: directoryURL)
    }

    var createsSharedContainerData: Bool { false }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try mutableDirectoryURL.setResourceValues(values)
    }

    private func loadRecords() -> [HoloInternalLogRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([HoloInternalLogRecord].self, from: data)) ?? []
    }

    private func prune(_ records: [HoloInternalLogRecord]) -> [HoloInternalLogRecord] {
        let cutoff = now().addingTimeInterval(-Self.retention)
        return records.filter { $0.capturedAt >= cutoff }
    }

    private func writeIfDirectoryExists(records: [HoloInternalLogRecord]) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try write(records: records)
    }

    private func write(records: [HoloInternalLogRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
#endif
