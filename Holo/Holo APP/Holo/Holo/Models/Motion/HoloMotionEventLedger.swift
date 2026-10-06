import Foundation

/// 当天第一次有效记录的展示规则；撤销只改变业务状态，不重置庆祝次数。
nonisolated struct HoloHabitMotionDayPolicy: Codable {
    private var day: Date?
    private var responded: Set<UUID> = []

    mutating func claim(_ habitID: UUID, at date: Date, calendar: Calendar = .current) -> Bool {
        let currentDay = calendar.startOfDay(for: date)
        if day != currentDay {
            day = currentDay
            responded.removeAll()
        }
        return responded.insert(habitID).inserted
    }
}

/// 动效只消费本地明确操作；同步通知和页面刷新不构成操作事件。
nonisolated struct HoloMotionSubject: Hashable {
    enum Domain: String { case finance, thought, habit, task }
    let domain: Domain
    let id: UUID
}

nonisolated struct HoloMotionEvent: Equatable {
    enum Phase { case pending, confirmed, failed, undone }
    let operationID: UUID
    let subject: HoloMotionSubject
    let phase: Phase
    let occurredAt: Date
}

/// 短时、一次性的展示账本，不参与业务保存。终态不能被迟到的 pending 覆盖。
nonisolated struct HoloMotionEventLedger {
    static let lifetime: TimeInterval = 10
    private static let capacity = 128
    private var operations: [UUID: HoloMotionEvent] = [:]
    private var order: [UUID] = []
    private var ready: [HoloMotionSubject: HoloMotionEvent] = [:]

    mutating func record(_ event: HoloMotionEvent) {
        if let previous = operations[event.operationID] {
            guard previous.subject == event.subject,
                  (previous.phase == .pending && event.phase != .pending)
                    || (previous.phase == .confirmed && event.phase == .undone) else { return }
        } else {
            order.append(event.operationID)
        }
        operations[event.operationID] = event
        if event.phase == .confirmed {
            ready[event.subject] = event
        } else if ready[event.subject]?.operationID == event.operationID {
            ready[event.subject] = nil
        }
        ready = ready.filter { event.occurredAt.timeIntervalSince($0.value.occurredAt) <= Self.lifetime }
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            if let removed = operations.removeValue(forKey: oldest),
               ready[removed.subject]?.operationID == oldest {
                ready[removed.subject] = nil
            }
        }
    }

    mutating func discardAll() {
        ready.removeAll()
    }

    mutating func discard(_ subject: HoloMotionSubject) {
        ready[subject] = nil
    }

    /// 后台或被弹层遮住时不消费；关闭动效时消费掉事件，重新开启不会补播。
    mutating func consume(_ subject: HoloMotionSubject, now: Date,
                         enabled: Bool, isVisible: Bool) -> HoloMotionEvent? {
        guard let event = ready[subject] else { return nil }
        let age = now.timeIntervalSince(event.occurredAt)
        guard enabled, age >= 0, age <= Self.lifetime else {
            ready[subject] = nil
            return nil
        }
        guard isVisible else { return nil }
        ready[subject] = nil
        return event
    }
}

/// 只回应打开当天的一小段入场窗口，分组按稳定时段去重；刷新和懒加载不补播。
nonisolated struct HoloReplayMotionLedger {
    private var seen: [UUID: Set<Int>] = [:]
    private var cancelled: Set<UUID> = []
    private var order: [UUID] = []

    mutating func cancel(_ request: UUID) {
        register(request)
        cancelled.insert(request)
    }

    mutating func claim(_ request: UUID, item: Int, requestedAt: Date, now: Date) -> Bool {
        register(request)
        let age = now.timeIntervalSince(requestedAt)
        guard !cancelled.contains(request), age >= 0, age <= 1 else { return false }
        return seen[request, default: []].insert(item).inserted
    }

    private mutating func register(_ request: UUID) {
        guard seen[request] == nil else { return }
        seen[request] = []
        order.append(request)
        if order.count > 64 {
            let removed = order.removeFirst()
            seen[removed] = nil
            cancelled.remove(removed)
        }
    }
}

/// 开关缺省开启；读取系统支持的 Bool 与 YES/NO 启动参数，不能靠对象强转判断。
nonisolated enum HoloMotionPreferencePolicy {
    static func isEnabled(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}
