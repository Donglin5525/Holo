//
//  HoloMemoryReceiptStore.swift
//  Holo
//
//  用户可见的记忆写入/使用回执
//

import Foundation

enum HoloMemoryReceiptKind: String, Codable {
    case write
    case use
}

enum HoloMemoryReceiptChannel: String, Codable {
    case insight
    case chat
    case analysis
    case agent
}

enum HoloMemoryReceiptAdoptionKind: String, Codable, Sendable {
    case automaticallyAdopted
    case needsConfirmation
    case historicalMigration
}

struct HoloMemoryReceipt: Codable, Identifiable, Equatable {
    var id: String
    var kind: HoloMemoryReceiptKind
    var channel: HoloMemoryReceiptChannel
    var memoryIDs: [String]
    var message: String
    var createdAt: Date
    var adoptionKind: HoloMemoryReceiptAdoptionKind?
    var batchKey: String?
    var readAt: Date?
    var handledAt: Date?

    init(
        id: String,
        kind: HoloMemoryReceiptKind,
        channel: HoloMemoryReceiptChannel,
        memoryIDs: [String],
        message: String,
        createdAt: Date,
        adoptionKind: HoloMemoryReceiptAdoptionKind? = nil,
        batchKey: String? = nil,
        readAt: Date? = nil,
        handledAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.channel = channel
        self.memoryIDs = memoryIDs
        self.message = message
        self.createdAt = createdAt
        self.adoptionKind = adoptionKind
        self.batchKey = batchKey
        self.readAt = readAt
        self.handledAt = handledAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, channel, memoryIDs, message, createdAt
        case adoptionKind, batchKey, readAt, handledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(HoloMemoryReceiptKind.self, forKey: .kind)
        channel = try container.decode(HoloMemoryReceiptChannel.self, forKey: .channel)
        memoryIDs = try container.decode([String].self, forKey: .memoryIDs)
        message = try container.decode(String.self, forKey: .message)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        adoptionKind = try container.decodeIfPresent(
            HoloMemoryReceiptAdoptionKind.self,
            forKey: .adoptionKind
        )
        batchKey = try container.decodeIfPresent(String.self, forKey: .batchKey)
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        handledAt = try container.decodeIfPresent(Date.self, forKey: .handledAt)
    }
}

struct HoloMemoryInboxSnapshot: Equatable, Sendable {
    var newMemoryCount: Int
    var pendingConfirmationCount: Int
    var hasUnreadMigrationSummary: Bool

    var isEmpty: Bool {
        newMemoryCount == 0 && pendingConfirmationCount == 0 && !hasUnreadMigrationSummary
    }

    var summaryText: String {
        var parts: [String] = []
        if newMemoryCount > 0 { parts.append("新记住 \(newMemoryCount) 件") }
        if pendingConfirmationCount > 0 { parts.append("待确认 \(pendingConfirmationCount) 件") }
        if parts.isEmpty, hasUnreadMigrationSummary { return "已整理原有记忆" }
        return parts.joined(separator: " · ")
    }
}

extension Notification.Name {
    static let holoMemoryReceiptsDidChange = Notification.Name("holoMemoryReceiptsDidChange")
}

enum HoloMemoryReceiptStore {
    private static let queue = DispatchQueue(label: "com.holo.memoryReceiptStore")
    private static let maxCount = 200
    private static let lastPresentedAtKey = "holo_memory_summary_last_presented_at"

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Holo", isDirectory: true)
            .appendingPathComponent("HoloMemoryReceipts.json")
    }

    static func load() -> [HoloMemoryReceipt] {
        queue.sync {
            guard let data = try? Data(contentsOf: storeURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([HoloMemoryReceipt].self, from: data)) ?? []
        }
    }

    static func record(
        kind: HoloMemoryReceiptKind,
        channel: HoloMemoryReceiptChannel,
        memoryIDs: [String],
        message: String,
        adoptionKind: HoloMemoryReceiptAdoptionKind? = nil,
        batchKey: String? = nil,
        now: Date = Date()
    ) {
        let normalizedIDs = Array(Set(memoryIDs)).sorted()
        guard !normalizedIDs.isEmpty else { return }
        var didChange = false
        queue.sync {
            var receipts: [HoloMemoryReceipt]
            if let data = try? Data(contentsOf: storeURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                receipts = (try? decoder.decode([HoloMemoryReceipt].self, from: data)) ?? []
            } else {
                receipts = []
            }
            if let batchKey,
               receipts.contains(where: {
                   $0.batchKey == batchKey &&
                   $0.kind == kind &&
                   $0.adoptionKind == adoptionKind &&
                   $0.memoryIDs == normalizedIDs
               }) {
                return
            }
            receipts.insert(HoloMemoryReceipt(
                id: UUID().uuidString,
                kind: kind,
                channel: channel,
                memoryIDs: normalizedIDs,
                message: message,
                createdAt: now,
                adoptionKind: adoptionKind,
                batchKey: batchKey
            ), at: 0)
            if receipts.count > maxCount {
                receipts = Array(receipts.prefix(maxCount))
            }
            try? write(receipts)
            didChange = true
        }
        if didChange {
            NotificationCenter.default.post(name: .holoMemoryReceiptsDidChange, object: nil)
        }
    }

    static func receipts(for memoryID: String) -> [HoloMemoryReceipt] {
        load().filter { $0.memoryIDs.contains(memoryID) }
    }

    static func unreadWriteReceipts() -> [HoloMemoryReceipt] {
        load().filter {
            $0.kind == .write && $0.readAt == nil && $0.adoptionKind != nil
        }
    }

    static func markWriteReceiptsRead(now: Date = Date()) {
        mutate { receipts in
            for index in receipts.indices where receipts[index].kind == .write {
                if receipts[index].readAt == nil { receipts[index].readAt = now }
            }
        }
    }

    static func markHandled(memoryID: String, now: Date = Date()) {
        mutate { receipts in
            for index in receipts.indices where receipts[index].memoryIDs.contains(memoryID) {
                receipts[index].handledAt = now
                receipts[index].readAt = receipts[index].readAt ?? now
            }
        }
    }

    static func shouldPresentSummary(now: Date = Date()) -> Bool {
        guard !unreadWriteReceipts().isEmpty else { return false }
        guard let last = UserDefaults.standard.object(forKey: lastPresentedAtKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(last) >= 86_400
    }

    static func markSummaryPresented(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: lastPresentedAtKey)
    }

    #if !HOLO_MEMORY_STANDALONE
    @MainActor
    static func inboxSnapshot() async -> HoloMemoryInboxSnapshot {
        let unread = unreadWriteReceipts()
        let newIDs = Set(unread.filter {
            $0.adoptionKind == .automaticallyAdopted
        }.flatMap(\.memoryIDs))
        let migrationUnread = unread.contains { $0.adoptionKind == .historicalMigration }
        let pendingCount: Int
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            pendingCount = try await repository.query(.all).filter {
                $0.state == .candidate && $0.userDecision == .none
            }.count
        } catch {
            pendingCount = 0
        }
        return HoloMemoryInboxSnapshot(
            newMemoryCount: newIDs.count,
            pendingConfirmationCount: pendingCount,
            hasUnreadMigrationSummary: migrationUnread
        )
    }
    #endif

    private static func mutate(_ mutation: (inout [HoloMemoryReceipt]) -> Void) {
        queue.sync {
            var receipts = loadWithoutLock()
            mutation(&receipts)
            try? write(receipts)
        }
        NotificationCenter.default.post(name: .holoMemoryReceiptsDidChange, object: nil)
    }

    private static func loadWithoutLock() -> [HoloMemoryReceipt] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HoloMemoryReceipt].self, from: data)) ?? []
    }

    private static func write(_ receipts: [HoloMemoryReceipt]) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipts).write(to: storeURL, options: .atomic)
    }
}
