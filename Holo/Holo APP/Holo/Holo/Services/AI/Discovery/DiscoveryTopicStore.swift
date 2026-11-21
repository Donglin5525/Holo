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
        // v4 洞察卡（2026-11-20 方案 §5.3）：新增可选字段，旧 v3 卡缺省按 3 读取，
        // UserDefaults 编码天然兼容，无需迁移。sourceDomains/evidenceDomains 为
        // 03-I6 卡片 UI（领域 chip + 证据行图标）的展示字段。
        var version: Int?
        var insight: String?
        var evidenceLines: [String]?
        var evidenceDomains: [String]?
        var prompt: String?
        var portraitRefs: [String]?
        var angleKey: String?
        var sourceDomains: [String]?

        var isV4: Bool { version == 4 }
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
    /// v4 优先（2026-11-20 方案 03-I5）：队列里同时有 v3/v4 时先出 v4。
    func todayCard(now: Date = Date(), calendar: Calendar = .current) -> QueuedCard? {
        if consumedToday(now: now, calendar: calendar) { return nil }
        let rejected = rejectedTopics
        let valid = readQueue().filter { card in
            !rejected.contains(card.topicKey) && card.windowEnd >= now
        }
        return valid.first { $0.isV4 } ?? valid.first
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

    // MARK: - v4 首启迁移（2026-11-21 真机实报：库存旧卡把 v4 挡在门外）

    /// 首次启用 v4 时一次性清空 v3 库存队列。
    ///
    /// 背景（真机实报定谳）：补货守卫是「队列空才跑 v4」，而存量 v3 卡（基线打分
    /// 定谳为纯复述垃圾）一张张出会把 v4 挡在门外最长两周，用户每天先吃一张旧垃圾卡。
    /// v3 的兜底角色是「v4 失败时现算一张」（03-I3），不是吃库存——库存一律丢弃；
    /// 已展示/拒绝历史保留（recentTopics 语义不受影响）。
    func discardLegacyQueueIfNeeded() {
        // v2（11-21 二轮）：老代码在被掐断后会走「本机兜底」塞 v3 卡进队列，随键升级再清一次。
        let key = "holo.discovery.insight.v4QueueCleared.v2"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        writeQueue([])
    }

    // MARK: - v4 洞察线（2026-11-20 方案 03-I5：角度记忆 + 当日判定标记）

    private let insightShownAngleKey = "holo.discovery.insight.shownAngles.v1"
    private let insightRejectedAngleKey = "holo.discovery.insight.rejectedAngles.v1"
    // v3（11-21 三轮）：随重装再释放当天尝试（v2 已被 13:39 完整跑完的一次占用）。
    private let insightAttemptDayKey = "holo.discovery.insight.attemptDay.v3"
    private let insightNoneDayKey = "holo.discovery.insight.noneDay.v1"
    private let insightQuotaWallDayKey = "holo.discovery.insight.quotaWallDay.v1"
    /// recentAngleKeys 的回看窗口：30 天（总纲 §5.1 recentTopics 语义）。
    static let angleRecentDays = 30

    private func dayStamp(_ now: Date, calendar: Calendar) -> TimeInterval {
        calendar.startOfDay(for: now).timeIntervalSince1970
    }

    /// v4 今天是否已尝试过（一次/日：任何结果都算，防重复烧 3 次/日配额）。
    func insightV2AttemptedToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let day = defaults.double(forKey: insightAttemptDayKey)
        return day > 0 && day == dayStamp(now, calendar: calendar)
    }

    func markInsightV2Attempted(now: Date = Date(), calendar: Calendar = .current) {
        defaults.set(dayStamp(now, calendar: calendar), forKey: insightAttemptDayKey)
    }

    /// v4 预算墙（2026-11-21）：今天服务端判定每周额度用完（免费 1 条/周、Plus 5 条/周）。
    /// 评审页据此在「今日一条」空位展示升级引导卡；次日首次打开会重新探一次（服务端权威）。
    func isInsightQuotaWalledToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let day = defaults.double(forKey: insightQuotaWallDayKey)
        return day > 0 && day == dayStamp(now, calendar: calendar)
    }

    func markInsightQuotaWalled(now: Date = Date(), calendar: Calendar = .current) {
        defaults.set(dayStamp(now, calendar: calendar), forKey: insightQuotaWallDayKey)
    }

    /// v4 今天是否已判「无值得说的」（宁缺毋滥：当天 v3 也不补卡）。
    func insightV2NoneWorthwhileToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let day = defaults.double(forKey: insightNoneDayKey)
        return day > 0 && day == dayStamp(now, calendar: calendar)
    }

    func markInsightV2NoneWorthwhile(now: Date = Date(), calendar: Calendar = .current) {
        defaults.set(dayStamp(now, calendar: calendar), forKey: insightNoneDayKey)
    }

    /// v4 卡已展示（消费时调用）：angleKey 入近期列表，30 天内模型不得再选。
    func markInsightAngleShown(_ angleKey: String, now: Date = Date()) {
        let cutoff = Int(now.timeIntervalSince1970) - Self.angleRecentDays * 86_400
        let entries = readAngleList(insightShownAngleKey)
            .filter { $0.key == angleKey || $0.shownAt > cutoff }
        let ts = Int(now.timeIntervalSince1970)
        writeAngleList(insightShownAngleKey, entries + [(angleKey, ts)])
    }

    /// v4 卡「不太准」：angleKey 永久拒（30 天窗口由 rejectedAngles 全量上送约束）。
    func markInsightAngleRejected(_ angleKey: String, now: Date = Date()) {
        let entries = readAngleList(insightRejectedAngleKey).filter { $0.key != angleKey }
        let ts = Int(now.timeIntervalSince1970)
        writeAngleList(insightRejectedAngleKey, entries + [(angleKey, ts)])
    }

    /// 近 30 天已展示角度（I2 填入 packet.recentTopics）。
    func recentAngleKeys(now: Date = Date()) -> [String] {
        let cutoff = Int(now.timeIntervalSince1970) - Self.angleRecentDays * 86_400
        return readAngleList(insightShownAngleKey)
            .filter { $0.shownAt > cutoff }
            .map(\.key)
    }

    /// 已拒绝角度（I2 填入 packet.rejectedAngles）。
    var rejectedAngleKeys: [String] {
        readAngleList(insightRejectedAngleKey).map(\.key)
    }

    private func readAngleList(_ key: String) -> [(key: String, shownAt: Int)] {
        (defaults.stringArray(forKey: key) ?? []).compactMap { entry in
            guard let idx = entry.lastIndex(of: "|"),
                  let ts = Int(entry[entry.index(after: idx)...]) else { return nil }
            let angle = String(entry[entry.startIndex..<idx])
            return angle.isEmpty ? nil : (angle, ts)
        }
    }

    private func writeAngleList(_ key: String, _ values: [(key: String, shownAt: Int)], limit: Int = 60) {
        defaults.set(values.suffix(limit).map { "\($0.key)|\($0.shownAt)" }, forKey: key)
    }
}
