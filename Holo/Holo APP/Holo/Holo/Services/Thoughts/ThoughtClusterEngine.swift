//
//  ThoughtClusterEngine.swift
//  Holo
//
//  想法群落：未归类想法的本地语义成簇（冷启动「主题从想法里长出来」的呈现层引擎）。
//  纯逻辑、不依赖 Core Data：输入快照，输出簇。聚类信号用标签共现——
//  已有的 inline / AI / 已确认标签天然是想法的自我描述，无需新增 AI 调用；
//  语义向量增强（P2 实验）将来可作为第二信号接入，接口已按快照设计。
//

import Foundation

nonisolated struct ThoughtClusterEngine {

    /// 单条想法的聚类快照（调用方从 assignment 事实源组装）
    struct ThoughtSnapshot: Equatable {
        let id: UUID
        /// 该想法的全部可见标签名（inline / ai / confirmedAI；路径或叶子词均可）
        let tagNames: [String]
        /// 首行摘要（引用原话用——簇预览要让用户认出自己的字，不发明概括词）
        let firstLine: String
    }

    /// 一个想法群落
    struct Cluster: Equatable {
        /// 簇名 = 簇内最高频标签的叶段名（用户/AI 已用过的词，不是新造词）
        let name: String
        let thoughtIds: [UUID]
        /// 每条想法引用一句原话（最多 sampleLimit 条）
        let samples: [String]
    }

    struct Result: Equatable {
        /// 成形群落（≥ minClusterSize 条）
        let clusters: [Cluster]
        /// 没有可聚信号的想法（无标签或标签太散）
        let scatteredIds: [UUID]

        var isEmpty: Bool { clusters.isEmpty && scatteredIds.isEmpty }
    }

    /// 成簇阈值：2 条即可成簇——冷启动用户想法少，门槛必须低
    static let defaultMinClusterSize = 2

    /// 把未归类想法按标签共现聚簇。
    /// 一条想法有多个标签时，归入「簇更大」的那个（确定性：先按标签频次排序），
    /// 保证每条想法只属于一个簇，呈现不重复。
    static func cluster(
        _ snapshots: [ThoughtSnapshot],
        minClusterSize: Int = defaultMinClusterSize,
        sampleLimit: Int = 3
    ) -> Result {
        // 1. 标签频次统计（双形态身份折叠：#books 与「主题/books」算同一个信号）
        var tagFrequency: [String: Int] = [:]  // key: 归一化身份 key（优先完整路径，退化为叶子）
        for snapshot in snapshots {
            for identity in identityKeys(of: snapshot.tagNames) {
                tagFrequency[identity, default: 0] += 1
            }
        }

        // 2. 按频次降序给标签身份排序（确定性：频次同则按 key 字典序）
        let orderedIdentities = tagFrequency
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map(\.key)

        // 3. 贪心分配：每条想法归入它拥有的、尚未满员冲突的最高频身份
        var assignment: [String: [ThoughtSnapshot]] = [:]
        var scattered: [UUID] = []
        for snapshot in snapshots {
            let identities = Set(identityKeys(of: snapshot.tagNames))
                .intersection(orderedIdentities)
            guard let best = orderedIdentities.first(where: identities.contains) else {
                scattered.append(snapshot.id)
                continue
            }
            assignment[best, default: []].append(snapshot)
        }

        // 4. 分组成形：≥ minClusterSize 的成簇；不够格的成员落回散苗（不能凭空消失）
        var clusters: [Cluster] = []
        for (identity, members) in assignment {
            if members.count >= minClusterSize {
                let name = ThoughtTagNormalizer.lastSegment(identity)
                let samples = members.prefix(sampleLimit)
                    .map { $0.firstLine.isEmpty ? "（无内容）" : $0.firstLine }
                clusters.append(Cluster(
                    name: name,
                    thoughtIds: members.map(\.id),
                    samples: Array(samples)
                ))
            } else {
                scattered.append(contentsOf: members.map(\.id))
            }
        }
        // 簇排序：成员数降序，同数按名稳定排
        clusters.sort { lhs, rhs in
            if lhs.thoughtIds.count != rhs.thoughtIds.count {
                return lhs.thoughtIds.count > rhs.thoughtIds.count
            }
            return lhs.name < rhs.name
        }

        return Result(clusters: clusters, scatteredIds: scattered)
    }

    /// 标签身份 key：完整路径 key 与叶子 key 并集（与 sharesIdentity 同一判定精神）
    private static func identityKeys(of tagNames: [String]) -> [String] {
        var keys: Set<String> = []
        for name in tagNames {
            let path = ThoughtTagNormalizer.displayPath(name)
            guard !path.isEmpty else { continue }
            keys.insert(ThoughtTagNormalizer.key(path))
            keys.insert(ThoughtTagNormalizer.key(ThoughtTagNormalizer.lastSegment(path)))
        }
        return Array(keys)
    }
}
