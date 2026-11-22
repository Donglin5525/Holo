import Foundation

// 往期发现存档（2026-11-21 Plus 分层 I4b）：用户点过「对，记住」或「先放一放」的 v4 卡留在这里；
// 「不太准确」的不进存档。免费与 Plus 一样可看（01 D5）。
// 存储与 DiscoveryTopicStore 同口径：UserDefaults、单设备、不上 CloudKit。
nonisolated final class DiscoveryInsightArchive {
    static let shared = DiscoveryInsightArchive()
    static let limit = 100

    enum Outcome: String, Codable, Sendable {
        case confirmed
        case deferred
    }

    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var body: String
        var sourceDomains: [String]
        var evidenceLines: [String]
        var consumedAt: Date
        var outcome: Outcome
    }

    private let defaults: UserDefaults
    private let key = "holo.discovery.insight.archive.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 新的在前。
    var entries: [Entry] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list.sorted { $0.consumedAt > $1.consumedAt }
    }

    var latest: Entry? { entries.first }

    func append(card: DiscoveryTopicStore.QueuedCard, outcome: Outcome, now: Date = Date()) {
        guard card.isV4 else { return }
        var list = entries.filter { $0.id != card.topicKey }
        // v4 正文在 body（CardBuilder 58/59 行：body 即 selected.insight，卡视图显示 card.body）。
        list.insert(Entry(
            id: card.topicKey,
            title: card.title,
            body: card.body,
            sourceDomains: card.sourceDomains ?? [],
            evidenceLines: card.evidenceLines ?? [],
            consumedAt: now,
            outcome: outcome
        ), at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        defaults.set((try? JSONEncoder().encode(list)) ?? Data(), forKey: key)
    }
}
