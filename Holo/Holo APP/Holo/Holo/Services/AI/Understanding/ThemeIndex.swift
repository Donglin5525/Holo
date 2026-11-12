//
//  ThemeIndex.swift
//  Holo
//
//  理解引擎 M2.2：主题包（07-M2施工图）。
//
//  词法锚点聚类为主（P1-4 约束：embedding 只做补充候选源，不进本文件）。
//  两阶段：①财务/任务等带概念观察先成簇（包含/共享前缀归并）；
//  ②用簇锚词回扫想法原话——原话是照料类命题的关键证据（M1.1 caseA 路径）。
//

import Foundation

/// 一个生活主题（线索组织方式；主题名不证明用户属性——工程稿 §3.1）。
nonisolated struct ObservationTheme: Codable, Sendable, Equatable {
    /// 主题锚 = 簇内最短概念（「猫粮」簇的锚可能是「猫粮」本身）。
    var key: String
    /// 簇内全部概念。
    var concepts: [String]
    /// 成员观察 id（LifeObservation.id）。
    var memberIDs: [String]
    /// 覆盖域（finance/task/thought…，跨域≥2 是关联类候选的前提）。
    var domains: [String]
    /// 成员+概念稳定指纹：变化才触发行为理解通道（预算保护）。
    var fingerprint: String

    var isCrossDomain: Bool { Set(domains).count >= 2 }
}

nonisolated enum ThemeIndex {

    /// 主题指纹：排序成员 id + 概念的 FNV-1a（跨进程稳定）。
    static func fingerprint(memberIDs: [String], concepts: [String]) -> String {
        let canonical = (memberIDs.sorted() + concepts.sorted()).joined(separator: "|")
        return ThoughtObservationInput.stableHash(canonical)
    }

    /// 构建主题：带概念观察聚类（两级锚：全词 + 首字锚连通「猫粮」「猫砂」）→
    /// 想法原话回扫入簇 → 过滤单观察噪声。
    static func buildThemes(from observations: [LifeObservation]) -> [ObservationTheme] {
        // ① 概念两级锚注册：全词 key + 首字锚 key（≥2 字概念才拆锚，防单字概念自伴）。
        var keyOwners: [String: [String]] = [:]       // key(全词或首字锚) -> [observationID]
        var conceptKeys: [String: Set<String>] = [:]  // 概念 -> 其注册的 keys
        for obs in observations {
            for concept in obs.concepts {
                var keys = [concept]
                if concept.count >= 2, let first = concept.first {
                    keys.append(String(first))
                }
                conceptKeys[concept] = Set(keys)
                for key in keys {
                    keyOwners[key, default: []].append(obs.id)
                }
            }
        }
        let allConcepts = Array(conceptKeys.keys)
        guard !allConcepts.isEmpty else { return [] }

        // ② union-find：共享任一 key 的概念连通（单字锚不作为概念输出，仅作桥）。
        var parent: [String: String] = [:]
        func root(_ c: String) -> String {
            var current = c
            while parent[current] != current { current = parent[current]! }
            return current
        }
        for c in allConcepts { parent[c] = c }
        var keyToConcept: [String: [String]] = [:]
        for c in allConcepts {
            for key in conceptKeys[c] ?? [] { keyToConcept[key, default: []].append(c) }
        }
        for concepts in keyToConcept.values {
            guard let first = concepts.first else { continue }
            for other in concepts.dropFirst() {
                parent[root(first)] = root(other)
            }
        }
        var clusters: [String: [String]] = [:]        // 代表概念 -> 簇内全词概念
        for c in allConcepts { clusters[root(c), default: []].append(c) }

        // ③ 每簇：成员=含簇概念的所有观察 + 簇概念回扫想法原话
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        var themes: [ObservationTheme] = []
        for (_, clusterConcepts) in clusters {
            // 主题身份 = 稳定强锚：优先簇自身挂 ≥2 概念的首字锚（成员增减不换代表词，
            // 防「猫粮→猫砂」身份漂移——工程稿 §6.1：主题名不能作去重键，身份必须稳定）；
            // 无强锚的弱簇回退最短全词概念（可漂移，接受为探索态）。
            let clusterAnchors = Set(clusterConcepts.compactMap { $0.first.map(String.init) })
            let strongAnchors = clusterAnchors.filter { (keyToConcept[$0]?.count ?? 0) >= 2 }
            let anchor = strongAnchors.sorted().first
                ?? clusterConcepts.sorted { ($0.count, $0) < ($1.count, $1) }.first ?? ""
            var memberIDs = Set<String>()
            var domains = Set<String>()
            for concept in clusterConcepts {
                for oid in keyOwners[concept] ?? [] {
                    memberIDs.insert(oid)
                    if let obs = byID[oid] { domains.insert(obs.domain.rawValue) }
                }
            }

            for obs in observations where obs.domain == .thought && obs.businessState == .quote {
                guard let quote = obs.quote else { continue }
                // 全词概念走字数门槛；强单字锚已由「挂≥2概念」自证强度，直接包含判断。
                let hit = clusterConcepts.contains { containsAnchor(quote: quote, anchor: $0) }
                    || strongAnchors.contains { quote.contains($0) }
                if hit {
                    memberIDs.insert(obs.id)
                    domains.insert(obs.domain.rawValue)
                }
            }
            // 噪声过滤：单观察主题不成线索包（探索通道另行处理未归类概念）。
            guard memberIDs.count >= 2 else { continue }
            let sortedMembers = memberIDs.sorted()
            themes.append(ObservationTheme(
                key: anchor,
                concepts: clusterConcepts.sorted(),
                memberIDs: sortedMembers,
                domains: domains.sorted(),
                fingerprint: fingerprint(memberIDs: sortedMembers, concepts: clusterConcepts)
            ))
        }
        return themes.sorted { $0.key < $1.key }
    }

    /// 锚词回扫：锚至少 2 字且原话包含锚（「猫」1 字太宽不回扫——防『猫』『描写』类误命中）。
    static func containsAnchor(quote: String, anchor: String) -> Bool {
        anchor.count >= 2 && quote.contains(anchor)
    }

    // MARK: - 变化检测（指纹不同才触发处理——预算保护）

    struct ThemeChange: Equatable, Sendable {
        var key: String
        var kind: Kind
        enum Kind: String, Equatable { case added, updated, unchanged, removed }
    }

    static func detectChanges(old: [ObservationTheme], new: [ObservationTheme]) -> [ThemeChange] {
        let oldBy = Dictionary(uniqueKeysWithValues: old.map { ($0.key, $0) })
        let newBy = Dictionary(uniqueKeysWithValues: new.map { ($0.key, $0) })
        var changes: [ThemeChange] = []
        for (key, newTheme) in newBy {
            if oldBy[key] == nil {
                changes.append(ThemeChange(key: key, kind: .added))
            } else {
                changes.append(ThemeChange(key: key,
                    kind: oldBy[key]?.fingerprint == newTheme.fingerprint ? .unchanged : .updated))
            }
        }
        for key in oldBy.keys where newBy[key] == nil {
            changes.append(ThemeChange(key: key, kind: .removed))
        }
        return changes.sorted { $0.key < $1.key }
    }
}
