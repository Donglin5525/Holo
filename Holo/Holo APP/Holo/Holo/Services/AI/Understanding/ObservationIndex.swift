//
//  ObservationIndex.swift
//  Holo
//
//  理解引擎 M2.1：观察索引（本机可重建，不进 CloudKit）。
//
//  合并语义：
//  - merge（增量）：新观察按 sourceRef 替换旧修订（updated）或新增；不删除未出现的来源。
//  - replaceDomain（域全量重投影）：该域未在新批次出现的 sourceRef 被移除（来源删除的失效扇出）。
//

import Foundation

nonisolated struct IndexDelta: Equatable, Sendable {
    var added = 0
    var updated = 0
    var removed = 0
    var unchanged = 0

    var isEmpty: Bool { added == 0 && updated == 0 && removed == 0 }
}

nonisolated struct ObservationIndex: Codable, Sendable, Equatable {
    /// key = LifeObservation.id（domain:sourceRef:revision）。
    private(set) var observations: [String: LifeObservation]
    var schemaVersion: Int

    init(schemaVersion: Int = 1) {
        self.observations = [:]
        self.schemaVersion = schemaVersion
    }

    // MARK: - 合并

    /// 增量合并：同 sourceRef 的新修订替换旧修订；不删除本次未出现的来源。
    @discardableResult
    mutating func merge(_ newObservations: [LifeObservation]) -> IndexDelta {
        var delta = IndexDelta()
        var newByRef: [String: LifeObservation] = [:]
        for observation in newObservations {
            newByRef[observation.sourceRef] = observation
        }
        // 旧条目中将被新修订替换的 → removed（计入 updated）。
        let refsByDomainOld = Dictionary(grouping: observations.values, by: \.sourceRef)
        for (ref, obs) in newByRef {
            if let existing = refsByDomainOld[ref]?.first {
                if existing.id == obs.id {
                    delta.unchanged += 1
                } else {
                    observations[existing.id] = nil
                    observations[obs.id] = obs
                    delta.updated += 1
                }
            } else {
                observations[obs.id] = obs
                delta.added += 1
            }
        }
        return delta
    }

    /// 域全量替换：重投影整域后调用——本次未出现的 sourceRef 视为来源已删除，移除。
    @discardableResult
    mutating func replaceDomain(_ domain: ObservationDomain, with newObservations: [LifeObservation]) -> IndexDelta {
        var delta = merge(newObservations)
        let newRefs = Set(newObservations.map(\.sourceRef))
        for (key, observation) in observations where observation.domain == domain && !newRefs.contains(observation.sourceRef) {
            observations[key] = nil
            delta.removed += 1
        }
        return delta
    }

    func observations(in domain: ObservationDomain) -> [LifeObservation] {
        observations.values.filter { $0.domain == domain }.sorted { $0.id < $1.id }
    }

    // MARK: - 持久化（本机 JSON，原子写）

    static func load(directory: URL) -> ObservationIndex {
        let url = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(ObservationIndex.self, from: data) else {
            return ObservationIndex()
        }
        return index
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
