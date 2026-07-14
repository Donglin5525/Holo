//
//  HoloMemoryDirtyRegistry.swift
//  Holo
//
//  将高频业务变化压缩为每个领域一个常量空间的 dirty 状态。
//

import Foundation

nonisolated enum HoloMemoryObservationTarget: Codable, Equatable, Hashable, Sendable {
    case domain(HoloMemoryDomain)
    case crossDomain

    var stableKey: String {
        switch self {
        case .domain(let domain): return "domain:\(domain.rawValue)"
        case .crossDomain: return "cross-domain"
        }
    }
}

nonisolated struct HoloMemoryDirtyEntry: Codable, Equatable, Sendable {
    var target: HoloMemoryObservationTarget
    var firstDirtyAt: Date
    var lastDirtyAt: Date
    var combinedSourceDigest: String
    var changeCount: Int
}

nonisolated struct HoloMemoryDirtyRegistry: Codable, Equatable, Sendable {
    private var entries: [HoloMemoryDirtyEntry] = []

    var count: Int { entries.count }

    mutating func markDirty(
        target: HoloMemoryObservationTarget,
        sourceDigest: String,
        now: Date = Date()
    ) {
        if let index = entries.firstIndex(where: { $0.target == target }) {
            var entry = entries[index]
            entry.lastDirtyAt = max(entry.lastDirtyAt, now)
            entry.combinedSourceDigest = Self.combine(
                entry.combinedSourceDigest,
                sourceDigest
            )
            entry.changeCount += 1
            entries[index] = entry
        } else {
            entries.append(HoloMemoryDirtyEntry(
                target: target,
                firstDirtyAt: now,
                lastDirtyAt: now,
                combinedSourceDigest: Self.digest(sourceDigest),
                changeCount: 1
            ))
        }
    }

    func entry(for target: HoloMemoryObservationTarget) -> HoloMemoryDirtyEntry? {
        entries.first { $0.target == target }
    }

    func readyEntries(now: Date, debounce: TimeInterval) -> [HoloMemoryDirtyEntry] {
        entries
            .filter { now.timeIntervalSince($0.lastDirtyAt) >= debounce }
            .sorted { $0.target.stableKey < $1.target.stableKey }
    }

    mutating func consume(_ target: HoloMemoryObservationTarget) {
        entries.removeAll { $0.target == target }
    }

    private static func combine(_ previous: String, _ next: String) -> String {
        digest("\(previous)|\(next)")
    }

    private static func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

nonisolated struct HoloMemoryObservationWindow: Codable, Equatable, Sendable {
    var start: Date
    var end: Date

    static func make(
        target: HoloMemoryObservationTarget,
        dirtySince: Date,
        now: Date,
        catchUpLimit: TimeInterval
    ) -> HoloMemoryObservationWindow {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let alignedStart: Date
        let alignedEnd: Date
        switch target {
        case .domain:
            alignedStart = calendar.startOfDay(for: now)
            alignedEnd = calendar.date(byAdding: .day, value: 1, to: alignedStart)!
        case .crossDomain:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            alignedStart = calendar.date(from: components) ?? calendar.startOfDay(for: now)
            alignedEnd = calendar.date(byAdding: .day, value: 7, to: alignedStart)!
        }
        return HoloMemoryObservationWindow(
            start: max(dirtySince, max(alignedStart, now.addingTimeInterval(-catchUpLimit))),
            end: alignedEnd
        )
    }
}

nonisolated enum HoloMemoryObservationKey {
    static func make(
        target: HoloMemoryObservationTarget,
        window: HoloMemoryObservationWindow,
        sourceDigest: String,
        extractorVersion: Int,
        promptVersion: Int
    ) -> String {
        "\(target.stableKey)|window:\(seconds(window.start))-\(seconds(window.end))|digest:\(sourceDigest)|extractor:\(extractorVersion)|prompt:\(promptVersion)"
    }

    private static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.towardZero))
    }
}
