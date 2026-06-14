//
//  HoloWidgetSnapshotStore.swift
//  Holo
//
//  主 App 与 Widget Extension 共享的 JSON 快照读写。
//

import Foundation

struct HoloWidgetSnapshotStore {
    let directoryURL: URL

    init(directoryURL: URL = HoloWidgetSnapshotStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func writeQuickActions(_ snapshot: HoloWidgetQuickActionsSnapshot) throws {
        try write(snapshot, fileName: HoloWidgetSharedContainer.quickActionsFileName)
    }

    func writeFinance(_ snapshot: HoloWidgetFinanceSnapshot) throws {
        try write(snapshot, fileName: HoloWidgetSharedContainer.financeFileName)
    }

    func writeThoughtMemory(_ snapshot: HoloWidgetThoughtMemorySnapshot) throws {
        try write(snapshot, fileName: HoloWidgetSharedContainer.thoughtMemoryFileName)
    }

    func readQuickActions() -> HoloWidgetQuickActionsSnapshot? {
        read(HoloWidgetQuickActionsSnapshot.self, fileName: HoloWidgetSharedContainer.quickActionsFileName)
    }

    func readFinance() -> HoloWidgetFinanceSnapshot? {
        read(HoloWidgetFinanceSnapshot.self, fileName: HoloWidgetSharedContainer.financeFileName)
    }

    func readThoughtMemory() -> HoloWidgetThoughtMemorySnapshot? {
        read(HoloWidgetThoughtMemorySnapshot.self, fileName: HoloWidgetSharedContainer.thoughtMemoryFileName)
    }

    private func write<T: Encodable>(_ value: T, fileName: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        try data.write(to: directoryURL.appendingPathComponent(fileName), options: [.atomic])
    }

    private func read<T: Decodable>(_ type: T.Type, fileName: String) -> T? {
        let url = directoryURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    static func defaultDirectoryURL() -> URL {
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: HoloWidgetSharedContainer.appGroupIdentifier
        ) {
            return appGroupURL.appendingPathComponent(HoloWidgetSharedContainer.directoryName, isDirectory: true)
        }

        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return supportURL.appendingPathComponent(HoloWidgetSharedContainer.directoryName, isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

