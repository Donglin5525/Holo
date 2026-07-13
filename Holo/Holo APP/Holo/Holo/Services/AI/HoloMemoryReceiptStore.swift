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

struct HoloMemoryReceipt: Codable, Identifiable, Equatable {
    var id: String
    var kind: HoloMemoryReceiptKind
    var channel: HoloMemoryReceiptChannel
    var memoryIDs: [String]
    var message: String
    var createdAt: Date
}

enum HoloMemoryReceiptStore {
    private static let queue = DispatchQueue(label: "com.holo.memoryReceiptStore")
    private static let maxCount = 200

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
        now: Date = Date()
    ) {
        guard !memoryIDs.isEmpty else { return }
        queue.sync {
            var receipts: [HoloMemoryReceipt]
            if let data = try? Data(contentsOf: storeURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                receipts = (try? decoder.decode([HoloMemoryReceipt].self, from: data)) ?? []
            } else {
                receipts = []
            }
            receipts.insert(HoloMemoryReceipt(
                id: UUID().uuidString,
                kind: kind,
                channel: channel,
                memoryIDs: memoryIDs,
                message: message,
                createdAt: now
            ), at: 0)
            if receipts.count > maxCount {
                receipts = Array(receipts.prefix(maxCount))
            }
            try? write(receipts)
        }
    }

    static func receipts(for memoryID: String) -> [HoloMemoryReceipt] {
        load().filter { $0.memoryIDs.contains(memoryID) }
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
