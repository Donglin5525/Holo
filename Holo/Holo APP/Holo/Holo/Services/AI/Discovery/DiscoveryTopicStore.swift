import Foundation

/// 「一个发现」v3 展示队列（2026-11-08 方案 §5.3，东林拍板节奏）。
///
/// 观察池本身由确定性挖掘器每次实时重算（可重算中间态不落库）；本类型只持久化
/// 不可重算的轻量状态（UserDefaults，单设备，不上 CloudKit）：
/// - 展示队列：已选题的卡（快照+模板+槽位值），每天消费一张；
/// - 已展示命题：服务端 recentTopics 的输入（避免连日同类重复）；
/// - 否定命题：「不太准确」永不再现；冷却命题：「先放一放」7 天后回池；
/// - 每日消费标记（用户本地自然日）。
nonisolated final class DiscoveryTopicStore {

    static let shared = DiscoveryTopicStore()

    /// 「先放一放」冷却天数（东林拍板默认 7，可调）。
    static let deferCooldownDays = 7

    private let defaults: UserDefaults
    private let queueKey = "holo.discovery.topic.queue.v1"
    private let shownKey = "holo.discovery.topic.shownTopics.v1"
    private let rejectedKey = "holo.discovery.topic.rejectedTopics.v1"
    private let deferredKey = "holo.discovery.topic.deferredTopics.v1"
    private let lastShownDayKey = "holo.discovery.topic.lastShownDay.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 队列卡片

    /// 一张已选题待展示的卡：文案已回填终审（或降级模板），证据引用走命题快照。
    struct QueuedCard: Codable, Equatable, Sendable {
        var observationId: String
        var topicKey: String
        var title: String
        var body: String
        var isModelCopy: Bool
        var selectedAt: Date
        /// 观察源窗口结束日（时效复核：过期即弃，展示真实过期事实不硬撑）。
        var windowEnd: Date
    }

    private func readQueue() -> [QueuedCard] {
        guard let data = defaults.data(forKey: queueKey),
              let cards = try? JSONDecoder().decode([QueuedCard].self, from: data) else { return [] }
        return cards
    }

    private func writeQueue(_ cards: [QueuedCard]) {
        defaults.set((try? JSONEncoder().encode(cards)) ?? Data(), forKey: queueKey)
    }

    var queue: [QueuedCard] { readQueue() }

    func enqueue(_ card: QueuedCard, limit: Int = 14) {
        var cards = readQueue()
        cards.removeAll { $0.topicKey == card.topicKey }
        cards.append(card)
        if cards.count > limit { cards.removeFirst(cards.count - limit) }
        writeQueue(cards)
    }

    /// 展示当日时效复核：今天已消费过一张就不再出（东林拍板「每天最多一张」，
    /// 存量卡留给后面的日子）；未消费时跳过已否定与过期卡取下一张。
    func todayCard(now: Date = Date(), calendar: Calendar = .current) -> QueuedCard? {
        if consumedToday(now: now, calendar: calendar) { return nil }
        let rejected = rejectedTopics
        for card in readQueue() {
            if rejected.contains(card.topicKey) { continue }
            if card.windowEnd < now { continue }
            return card
        }
        return nil
    }

    /// 消费今日卡（用户看过/操作过），记录命题入「已展示」，清队列队首。
    func consumeToday(now: Date = Date(), calendar: Calendar = .current) {
        guard let card = todayCard(now: now, calendar: calendar) else { return }
        var cards = readQueue()
        cards.removeAll { $0.observationId == card.observationId && $0.selectedAt == card.selectedAt }
        writeQueue(cards)
        markShown(card.topicKey)
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        defaults.set(day, forKey: lastShownDayKey)
    }

    var lastShownDay: TimeInterval? {
        let v = defaults.double(forKey: lastShownDayKey)
        return v > 0 ? v : nil
    }

    /// 今天是否已有当日卡被消费（自然日比较，与习惯结算同口径）。
    func consumedToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let last = lastShownDay else { return false }
        return last == calendar.startOfDay(for: now).timeIntervalSince1970
    }

    /// 今天是否还该出卡：没消费过 + 队列还有效卡。
    func shouldRevealToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        !consumedToday(now: now, calendar: calendar) && todayCard(now: now, calendar: calendar) != nil
    }

    // MARK: - 命题记忆（已展示 / 否定 / 冷却）

    private func readList(_ key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    private func writeList(_ key: String, _ values: [String], limit: Int = 60) {
        var unique = Array(values.reversed().reduce(into: Set()) { $0.insert($1) }.reversed())
        if unique.count > limit { unique.removeFirst(unique.count - limit) }
        defaults.set(unique, forKey: key)
    }

    var shownTopics: [String] { readList(shownKey) }
    private func markShown(_ key: String) { writeList(shownKey, readList(shownKey) + [key]) }

    var rejectedTopics: [String] { readList(rejectedKey) }

    /// 「不太准确」：同命题永不再现（不连坐其他命题）。
    func markRejected(_ key: String) {
        writeList(rejectedKey, readList(rejectedKey) + [key])
        var cards = readQueue()
        cards.removeAll { $0.topicKey == key }
        writeQueue(cards)
    }

    var deferredTopics: [(key: String, until: Date)] {
        readList(deferredKey).compactMap { entry in
            guard let idx = entry.lastIndex(of: "|") else { return nil }
            let key = String(entry[entry.startIndex..<idx])
            let ts = Double(entry[entry.index(after: idx)...]) ?? 0
            return ts > 0 ? (key, Date(timeIntervalSince1970: ts)) : nil
        }
    }

    /// 「先放一放」：冷却 N 天后回池。
    func markDeferred(_ key: String, now: Date = Date()) {
        let until = now.addingTimeInterval(TimeInterval(Self.deferCooldownDays) * 86_400)
        let entries = deferredTopics.filter { $0.key != key }.map { "\($0.key)|\(Int($0.until.timeIntervalSince1970))" }
        writeList(deferredKey, entries + ["\(key)|\(Int(until.timeIntervalSince1970))"])
    }

    /// 冷却中的命题（选题输入过滤用）。
    func deferredActiveKeys(now: Date = Date()) -> Set<String> {
        Set(deferredTopics.filter { $0.until > now }.map(\.key))
    }
}
