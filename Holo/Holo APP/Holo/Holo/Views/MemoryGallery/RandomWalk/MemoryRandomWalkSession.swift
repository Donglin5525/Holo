//
//  MemoryRandomWalkSession.swift
//  Holo
//
//  随机漫步的会话控制（暖光规格 §3）：
//  - 阶段 loading → traveling → landing → arrived（可恢复 empty / failed）
//  - 动画输入不可变（requestID / departureDay / destination / motionMode），
//    每帧只算进度，开始/取消/交接/收尾全在这里，叶子视图只收只读参数
//  - 连点/重开/后台回来都按 requestID 比对，旧任务回调不污染新会话
//  - 抵达提交点 = 主段过场交接（1450ms/850ms 处）：日期、记录、解读一起提交
//

import Foundation
import SwiftUI
import Combine
import CoreData
import os.log

@MainActor
final class MemoryRandomWalkSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case traveling
        case landing
        case arrived
        /// 还没有可漫步的旧日（库里确无更早记录）。
        case empty
        /// 取数失败（区分「未载入」与「确实空」）。
        case failed(String)

        var isTerminalFailure: Bool {
            switch self {
            case .empty, .failed: return true
            default: return false
            }
        }
    }

    /// 一次漫步的不可变输入与结果快照。
    struct Arrival: Equatable {
        let requestID: UUID
        /// 出发日（首次=今天；后续=上一站）。展示标签由距离今天推断。
        let departureDay: Date
        /// 抵达日（startOfDay）。
        let day: Date
        let distanceDays: Int
        /// 当日全部事件（已按索引滤掉跨日副本）。
        let events: [CalendarEvent]
        let echo: MemoryWalkEcho?
        let excerpt: String?
        let excerptEventID: UUID?
        let isDepartureToday: Bool
    }

    // MARK: - 状态

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var arrival: Arrival?
    /// 本轮候选已全部看完（左侧动作换「重新漫步」）。
    @Published private(set) var allSeen = false
    /// 历史索引有模块失败（抵达页底部文案降级用）。
    @Published private(set) var indexIncomplete = false

    private(set) var visited: Set<Date> = []
    private var index: MemoryRandomWalkDayIndex?

    /// 索引已知的有记录日总数（历史只有一天时左侧动作隐藏）。
    var knownDayCount: Int { index?.days.count ?? 0 }
    private var requestID: UUID?
    private var lifecycleTask: Task<Void, Never>?
    /// 过场开始的单调时刻；叶子视图经 elapsedProvider 读取。
    private(set) var travelStartedAt: ContinuousClock.Instant?
    private var pendingRoundReset = false

    private let provider: CalendarEventProvider
    private let sampler: MemoryRandomWalkSampler
    private let now: () -> Date
    private let calendar: Calendar
    private var saveObserver: NSObjectProtocol?

    private static let logger = Logger(subsystem: "com.holo.app", category: "RandomWalk")

    init(provider: CalendarEventProvider? = nil,
         sampler: MemoryRandomWalkSampler = .production,
         now: @escaping () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.provider = provider ?? CalendarEventProvider(context: CoreDataStack.shared.viewContext)
        self.sampler = sampler
        self.now = now
        self.calendar = calendar
        // 主动保存（删除/归档/编辑）让索引与已看候选立即失效；下次漫步重建。
        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.index = nil }
        }
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    // MARK: - 叶子视图输入

    /// 暖光叶子视图的 elapsed 闭包（单调秒）。
    var elapsedProvider: (() -> TimeInterval)? {
        guard phase == .traveling || phase == .landing, let startedAt = travelStartedAt else {
            return nil
        }
        return { [clock = ContinuousClock()] in
            let d = clock.now - startedAt
            return TimeInterval(d.components.seconds) + TimeInterval(d.components.attoseconds) / 1e18
        }
    }

    var reduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }

    // MARK: - 动作

    /// 点「随机漫步」/「再走一天」/「重新漫步」统一入口。
    /// - Parameter fromToday: 首次漫步从今天出发；再走一天以上一站为出发点。
    func start() {
        let id = UUID()
        requestID = id
        lifecycleTask?.cancel()
        phase = .loading
        travelStartedAt = nil

        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let arrival = try await self.prepareArrival(requestID: id)
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                self.arrival = arrival
                self.beginTravel(requestID: id)
            } catch is CancellationError {
                // 请求被替换或关闭：不落任何终态，新请求自己接管。
            } catch {
                guard self.requestID == id else { return }
                Self.logger.error("漫步取数失败：\(String(describing: error))")
                self.phase = .failed(String(localized: "暂时无法载入旧日记录"))
            }
        }
    }

    /// 关闭（随时可用）：取消任务；本轮已看集合保留，重开面板继续同一轮。
    func close() {
        requestID = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        travelStartedAt = nil
        if phase == .traveling || phase == .landing || phase == .loading {
            phase = .idle
        }
    }

    /// 漫步面板整体消失（长廊会话结束）：清本轮集合。
    func resetSession() {
        close()
        visited = []
        allSeen = false
        arrival = nil
        pendingRoundReset = false
        phase = .idle
    }

    /// 场景失活/回前台：后台时停止绘制；回来有有效快照就静态落到该日。
    func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active, self.phase == .traveling || self.phase == .landing else { return }
        commitArrival()
    }

    /// 结果列表里点开一条记录后回到漫步（不消耗轮次，状态原样）。
    func restoreAfterSourceView() {
        // 状态未销毁，无需恢复；保留给后续「返回偏移/焦点」扩展。
    }

    // MARK: - 取数与抽样

    private func ensureIndex() async throws -> MemoryRandomWalkDayIndex {
        if let index { return index }
        let now = now()
        let calendar = calendar
        let coordinator = CoreDataStack.shared.viewContext.persistentStoreCoordinator
        let built = await Task.detached(priority: .userInitiated) {
            MemoryRandomWalkDayIndexBuilder.build(coordinator: coordinator,
                                                  calendar: calendar,
                                                  now: now)
        }.value
        index = built
        indexIncomplete = !built.failedModules.isEmpty
        return built
    }

    private func prepareArrival(requestID: UUID) async throws -> Arrival {
        let index = try await ensureIndex()
        let today = calendar.startOfDay(for: now())
        var candidates = index.candidateDays(before: now(), calendar: calendar)

        // 首次漫步没有任何旧日：区分「确实空」与「来源未读完」。
        if candidates.isEmpty {
            if indexIncomplete && index.failedModules.count >= 4 {
                throw NSError(domain: "RandomWalk", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "sources unavailable"])
            }
            allSeen = false
            phase = .empty
            throw CancellationError()
        }

        let isRoundStart = visited.isEmpty || pendingRoundReset
        var lastErrorDraw = false
        var chosen: Date?
        // 候选加载成功但已无可见记录时移除该候选继续抽；有效候选耗尽为止。
        for _ in 0..<max(1, candidates.count) {
            try Task.checkCancellation()
            guard self.requestID == requestID else { throw CancellationError() }
            guard let day = sampler.draw(candidates: candidates,
                                         excluding: visited,
                                         today: now(),
                                         calendar: calendar,
                                         isFirstOfRound: isRoundStart,
                                         lastSeen: arrival?.day) else {
                lastErrorDraw = true
                break
            }
            let range = CalendarRangeBuilder.dayRange(day)
            let result = await provider.fetchEvents(in: range)
            // 同 ID 跨日副本守卫：只保留与全历史索引同日的记录。
            let events = result.events.filter { event in
                index.isConsistent(CalendarEventKey(module: event.module, id: event.id), with: day)
            }
            if events.isEmpty {
                candidates.removeAll { $0 == day }
                continue
            }
            chosen = day
            return try buildArrival(requestID: requestID, day: day, today: today, events: events)
        }
        // 候选全部失效或抽完：如实区分空态与失败。
        if lastErrorDraw, candidates.isEmpty {
            phase = .empty
        } else if candidates.isEmpty {
            phase = .empty
        }
        throw CancellationError()
    }

    private func buildArrival(requestID: UUID, day: Date, today: Date,
                              events: [CalendarEvent]) throws -> Arrival {
        let distance = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        // 结果区预览：可靠时刻升序、无可靠时刻置后，最多 3 条；
        // 带正文想法若按时序落在前三之外，替换最后一条无该想法的预览。
        let ordered = Self.orderedPreviews(for: events)
        let previews = ordered.prefix(3).map(\.title)
        let excerptPair = MemoryWalkEchoBuilder.excerpt(for: events)
        let echo = MemoryWalkEchoBuilder.echo(for: events, visiblePreviews: previews)
        return Arrival(requestID: requestID,
                       departureDay: arrival?.day ?? today,
                       day: day,
                       distanceDays: distance,
                       events: events,
                       echo: echo,
                       excerpt: excerptPair?.text,
                       excerptEventID: excerptPair?.sourceEventID,
                       isDepartureToday: arrival == nil)
    }

    /// 抵达页与回看共用的排序：可靠时刻升序在前，无可靠时刻置后（稳定按日期）。
    /// 摘句来源想法若落在前三之外，与前三里最后一条换位——光里的句子抵达后能直接找到。
    static func orderedPreviews(for events: [CalendarEvent]) -> [CalendarEvent] {
        let timed = events.filter(\.hasReliableTime).sorted { $0.date < $1.date }
        let untimed = events.filter { !$0.hasReliableTime }.sorted { $0.date < $1.date }
        var merged = timed + untimed
        guard let excerpt = MemoryWalkEchoBuilder.excerpt(for: events),
              let sourceIndex = merged.firstIndex(where: { $0.id == excerpt.sourceEventID }),
              sourceIndex >= 3,
              let replaceIndex = merged.prefix(3).lastIndex(where: { $0.id != excerpt.sourceEventID })
        else { return merged }
        merged.swapAt(replaceIndex, sourceIndex)
        return merged
    }

    // MARK: - 过场与提交

    private func beginTravel(requestID: UUID) {
        travelStartedAt = ContinuousClock.now
        phase = .traveling
        announce(String(localized: "正在回到那一天"))

        let timeline = WarmLightTimeline(reduceMotion: reduceMotion)
        // 未设置过的 rollout 键默认开：bool(forKey:) 对缺省返回 false 会把动画整个跳过
        // （冒烟实抓：没动过动效开关的用户永远看不到暖光）。
        let replayEnabled = (UserDefaults.standard.object(forKey: HoloMotionRollout.replayKey) as? Bool) ?? true
        // App 内动效开关关闭：直接展示已加载结果（§4.3）。
        guard replayEnabled else {
            commitArrival()
            finishTravel(requestID: requestID)
            return
        }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(Int(timeline.handoffElapsed * 1000)))
            guard !Task.isCancelled, self.requestID == requestID else { return }
            self.commitArrival()
            self.phase = .landing
            try? await Task.sleep(for: .milliseconds(Int(timeline.fadeDuration * 1000)))
            guard !Task.isCancelled, self.requestID == requestID else { return }
            self.finishTravel(requestID: requestID)
        }
    }

    private func finishTravel(requestID: UUID) {
        guard self.requestID == requestID else { return }
        travelStartedAt = nil
        phase = .arrived
    }

    /// 抵达提交：日期、记录、解读一起落位；已看集合只在此时写入。
    private func commitArrival() {
        guard let arrival, phase == .traveling || phase == .landing else { return }
        if pendingRoundReset {
            visited = []
            pendingRoundReset = false
        }
        visited.insert(arrival.day)
        let candidates = index?.candidateDays(before: now(), calendar: calendar) ?? []
        allSeen = candidates.allSatisfy { visited.contains($0) }
        phase = .landing
    }

    /// 「重新漫步」：新目标成功抵达后再清空旧轮集合（失败/关闭保留原轮）。
    func requestRestart() {
        pendingRoundReset = true
        start()
    }
}
