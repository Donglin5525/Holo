//
//  HealthNightSleepResolver.swift
//  Holo
//
//  按晚睡眠还原器（健康分析方案 2026-11-17 第一步）：
//  把一段读取窗口内的 HealthKit 睡眠样本还原成按「睡眠结束日」归属的一晚结果。
//
//  与既有模块的关系：
//  - 会话聚类沿用 HealthSleepSessionSplitter 的 3 小时间隔与 60 分钟尾巴口径；
//  - 区间归并复用 HealthSleepSampleAggregator，时间轴段形复用 HealthSleepSegment；
//  - 自然日合计（fetchSleepStrict）与按晚明细（fetchSleepDetailRange）既有入口
//    口径不变，本模块是新增的第三条按晚入口，不悄悄替换任何既有查询。
//
//  规则真源：docs/health/plans/2026-11-17-Holo健康分析实施方案.md 第一步规则表。
//  多来源时间差、主睡眠识别的数值为试用默认值，真实样本覆盖待实施阶段校准。
//  纯函数，供 Repository 与测试共用；不访问健康数据库。
//

import Foundation
import HealthKit

// MARK: - 输入模型

/// 睡眠记录来源（供用户核对）。name 如 "Watch" / "AutoSleep"。
struct HealthSleepSource: Hashable, Sendable {
    let name: String
    let bundleID: String?
    let deviceName: String?
}

/// 带来源信息的睡眠样本（按晚还原输入）。value = HKCategoryValueSleepAnalysis.rawValue。
nonisolated struct HealthNightSample: Sendable, Equatable {
    let value: Int
    let start: Date
    let end: Date
    let sourceName: String
    let sourceBundleID: String?
    let deviceName: String?
    /// 样本自带的时区线索（HKMetadataKeyTimeZone）
    let timezoneID: String?

    var source: HealthSleepSource {
        HealthSleepSource(name: sourceName, bundleID: sourceBundleID, deviceName: deviceName)
    }
}

// MARK: - 结果模型

/// 还原出的一段睡眠（主睡眠/小睡/其他睡眠/睡眠记录共用形状）。
/// 「入睡 start」与「记录结束 asleepEnd」是可信睡着区间的首尾；
/// 在床、起床等生活事实由 bedStart / sessionEnd 分开标注。
struct HealthNightSession: Equatable, Sendable {
    enum Kind: String, Sendable {
        case main        // 主睡眠
        case nap         // 小睡（整段落在白天窗口且短于阈值）
        case otherSleep  // 其他睡眠
        case record      // 孤立短记录（样本不足，不推断主睡眠）
    }

    /// 分期状态（决定时长/分期能否被消费）
    enum StageStatus: String, Sendable {
        /// 已证实分期（采纳来源的 core/deep/REM）
        case staged
        /// 有睡着证据、无细分（未分期）
        case unstaged
        /// 多来源相互印证了时长、分期无法裁决（时长可用，分期待确认）
        case corroboratedPending
        /// 来源之间时间偏差明显，无法裁决（整段待确认并退出趋势）
        case conflicting
    }

    /// 来源裁决未通过时的候选记录（按来源各一条，供展示与核对）
    struct Candidate: Equatable, Sendable {
        let source: HealthSleepSource
        let start: Date
        let asleepEnd: Date
        let asleepSeconds: TimeInterval
        let staged: Bool
    }

    var kind: Kind
    /// 入睡：首段可信睡着区间的开始
    let start: Date
    /// 记录结束：末段可信睡着区间的结束（归属日与钟点趋势的锚点）
    let asleepEnd: Date
    /// 在床起点（与入睡分开标注；无可链到会话的在床记录为 nil）
    let bedStart: Date?
    /// 会话整体结束（含在床/清醒尾巴）
    let sessionEnd: Date
    /// 实际睡着时长（秒）＝可信睡着区间并集，缺样本空隙不累加
    let asleepSeconds: TimeInterval
    /// 时间轴（与摘要来自同一批整理后的样本；段间空隙＝无样本）
    let timeline: [HealthSleepSegment]
    /// 已证实分期时长（小时）；未分期/待确认为 nil，不得当 0 解读
    let stageHours: HealthNightStageHours?
    /// 夜醒次数（可信睡着区间内清醒 ≥2 分钟；无清醒记录为 nil）
    let awakeInterruptions: Int?
    let sources: [HealthSleepSource]
    let stageStatus: StageStatus
    /// 候选记录（仅 .conflicting 有内容）
    var candidates: [Candidate]
    /// 退出全部趋势（来源冲突）
    var excludedFromTrends: Bool
    /// 退出钟点趋势、保留时长趋势（时区无法核实）
    var excludedFromClockTrends: Bool
    /// 连接读取边界且补读后仍无法确认（记录可能不完整）
    var possiblyIncomplete: Bool
    /// 样本一致时区的标识；无线索或线索不一致为 nil（展示用查询本地时区）
    let timezoneID: String?

    var asleepHours: Double { asleepSeconds / 3600 }
    var stagePending: Bool { stageStatus == .corroboratedPending || stageStatus == .conflicting }
}

/// 已证实的分期时长（小时）
struct HealthNightStageHours: Equatable, Sendable {
    var core: Double
    var deep: Double
    var rem: Double
}

/// 按「睡眠结束日」归属的一晚结果
struct HealthNightSleepRecord: Equatable, Sendable {
    /// 归属日期（最后一段可信睡着记录结束时刻的当地日，startOfDay）
    let endDate: Date
    /// 主睡眠（可信睡着时长最长的一段；并列时为 nil）
    var mainSession: HealthNightSession?
    /// 额外睡眠段（小睡/其他睡眠/睡眠记录/待确认候选）
    var extraSessions: [HealthNightSession]
    /// 两段均 ≥2 小时且相差 <60 分钟，暂缓主睡眠对比
    var mainAmbiguous: Bool
    /// 展示用基准时区（主睡眠核实时区或查询本地时区）
    let presentationTimezoneID: String
    /// 主睡眠时区是否经样本核实
    let timezoneVerified: Bool
}

// MARK: - 还原器

nonisolated enum HealthNightSleepResolver {

    typealias Interval = HealthSleepSampleAggregator.Interval

    // MARK: 试用默认值（方案 §第一步；真实样本覆盖待实施阶段校准）

    /// 首尾各相差不超过该值视为「记录可以相互印证」
    static let boundaryTolerance: TimeInterval = 30 * 60
    /// 候选之间可信睡着区间至少重叠该值才视为描述同一段睡眠
    static let overlapMatchMinimum: TimeInterval = 30 * 60
    /// 主睡眠并列：两段均至少 2 小时
    static let mainAmbiguityMinimum: TimeInterval = 2 * 3600
    /// 主睡眠并列：两段相差不到 60 分钟
    static let mainAmbiguityWindow: TimeInterval = 60 * 60
    /// 低于该时长的孤立短记录不推断主睡眠
    static let mainSleepFloor: TimeInterval = 30 * 60
    /// 小睡判定：整段落在当地 09:00–21:00
    static let napWindowStartHour = 9
    static let napWindowEndHour = 21
    /// 小睡判定：短于 3 小时
    static let napMaximum: TimeInterval = 3 * 3600
    /// 夜醒：可信睡着区间内清醒 ≥ 2 分钟（沿用既有口径）
    static let wakeMinimum: TimeInterval = 120
    /// 会话连接读取边界的判定余量
    static let boundaryEpsilon: TimeInterval = 60

    private static let asleepRawValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue
    ]

    /// 来源内已解决冲突的原子段（相邻同样已合并）
    private struct Atom: Equatable {
        enum Stage: Equatable {
            case core, deep, rem, unspecified, awake, inBed, conflict
        }
        let stage: Stage
        let start: Date
        let end: Date
    }

    /// 来源内的候选会话（还原阶段产物，尚未跨来源裁决）
    private struct SourceCandidate {
        let source: HealthSleepSource
        /// 可信睡着区间（已归并）
        let trusted: [Interval]
        let start: Date
        let asleepEnd: Date
        let asleepSeconds: TimeInterval
        /// 分期覆盖秒数（core+deep+REM 归并总量），裁决「分期更完整」用
        let stagedSeconds: TimeInterval
        /// 会话相关的全部原子段（睡着/清醒/在床/冲突，含 60 分钟可链尾巴）
        let atoms: [Atom]
        let timezoneIDs: Set<String>
    }

    // MARK: - 入口

    /// 还原读取窗口内的样本为按结束日归属的一晚结果。
    /// - readWindow：本次实际读取的范围，会话触及其首尾时标 possiblyIncomplete
    ///   （调用方负责补读后重算；纯函数不感知读取次数）。
    /// - fallbackTimezoneID：样本无时区线索时的展示时区（本次查询的本地时区）。
    /// 返回窗口内出现的全部归属日（可能落在调用方请求范围之外，由调用方筛选）。
    static func resolve(
        samples: [HealthNightSample],
        readWindow: Interval,
        calendar: Calendar = .current,
        fallbackTimezoneID: String
    ) -> [HealthNightSleepRecord] {

        // 1. 来源内还原：同源同类合并 + 冲突解决 → 原子段 → 候选会话
        var candidatesBySource: [HealthSleepSource: [SourceCandidate]] = [:]
        let bySource: [HealthSleepSource: [HealthNightSample]] = Dictionary(
            grouping: samples.filter { $0.end > $0.start },
            by: \.source
        )
        for (source, sourceSamples) in bySource {
            candidatesBySource[source] = sourceCandidates(from: sourceSamples, source: source)
        }
        let allCandidates = candidatesBySource.flatMap(\.value)
        guard !allCandidates.isEmpty else { return [] }

        // 2. 跨来源对照：重叠成组 → 组内裁决 → 会话
        let sessions = adjudicate(matchGroups(of: allCandidates), readWindow: readWindow)

        // 3. 按结束日归属 + 主睡眠/小睡定类
        var byEndDate: [Date: [HealthNightSession]] = [:]
        for session in sessions {
            let endDay = calendar.startOfDay(for: session.asleepEnd)
            byEndDate[endDay, default: []].append(session)
        }

        return byEndDate.keys.sorted().map { endDay -> HealthNightSleepRecord in
            let daySessions = byEndDate[endDay]!
            var main: HealthNightSession?
            var extras: [HealthNightSession] = []
            var ambiguous = false

            // 主睡眠只从可裁决的会话里选；来源冲突的候选壳不参与
            let clean = daySessions
                .filter { $0.stageStatus != .conflicting }
                .sorted { $0.asleepSeconds > $1.asleepSeconds }

            if let top = clean.first {
                let second = clean.dropFirst().first
                if top.asleepSeconds >= mainAmbiguityMinimum,
                   let second, second.asleepSeconds >= mainAmbiguityMinimum,
                   top.asleepSeconds - second.asleepSeconds < mainAmbiguityWindow {
                    // 两段都至少 2 小时且相差不到 60 分钟：都展示，暂缓主睡眠对比
                    ambiguous = true
                } else if top.asleepSeconds >= mainSleepFloor {
                    main = retag(top, kind: .main)
                }
                // 低于 30 分钟的孤立短记录：样本不足，不推断主睡眠
            }

            func isSameSession(_ a: HealthNightSession, _ b: HealthNightSession) -> Bool {
                a.start == b.start && a.asleepEnd == b.asleepEnd && a.sources == b.sources
            }

            for session in daySessions {
                if let main, isSameSession(session, main) { continue }
                let kind: HealthNightSession.Kind
                if session.asleepSeconds < mainSleepFloor {
                    kind = .record
                } else if isNap(session, calendar: calendar, timezoneID: session.timezoneID ?? fallbackTimezoneID) {
                    kind = .nap
                } else {
                    kind = .otherSleep
                }
                extras.append(retag(session, kind: kind))
            }

            return HealthNightSleepRecord(
                endDate: endDay,
                mainSession: main,
                extraSessions: extras.sorted { $0.start < $1.start },
                mainAmbiguous: ambiguous,
                presentationTimezoneID: main?.timezoneID ?? fallbackTimezoneID,
                timezoneVerified: main?.timezoneID != nil
            )
        }
    }

    // MARK: - 来源内还原

    /// 同一来源的样本 → 解决同源冲突的原子段。
    /// 原子段 = 相邻样本边界切出的最小时间片，逐片按规则表裁决：
    /// 睡着∩清醒 → 冲突；多种分期并盖 → 未分期；单一分期覆盖笼统睡着 → 分期；
    /// 仅在床 → 在床（睡着/清醒优先于在床轨道）。
    private static func atoms(from samples: [HealthNightSample]) -> [Atom] {
        let valid = samples.filter { $0.end > $0.start }
        guard !valid.isEmpty else { return [] }
        let boundaries = Set(valid.flatMap { [$0.start, $0.end] }).sorted()
        guard boundaries.count >= 2 else { return [] }

        var result: [Atom] = []
        var index = 0
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard end > start else { continue }
            var core = false, deep = false, rem = false, unspecified = false, awake = false, inBed = false
            for sample in valid where sample.start < end && sample.end > start {
                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .asleepCore: core = true
                case .asleepDeep: deep = true
                case .asleepREM: rem = true
                case .asleepUnspecified: unspecified = true
                case .awake: awake = true
                case .inBed: inBed = true
                default: break
                }
            }
            let asleepCovered = core || deep || rem || unspecified
            let stage: Atom.Stage
            if asleepCovered && awake {
                stage = .conflict
            } else if core && (deep || rem) || (deep && rem) {
                stage = .unspecified   // 多种分期并盖，细分冲突记为未分期
            } else if core { stage = .core }
            else if deep { stage = .deep }
            else if rem { stage = .rem }
            else if unspecified { stage = .unspecified }
            else if awake { stage = .awake }
            else if inBed { stage = .inBed }
            else { continue }

            let atom = Atom(stage: stage, start: start, end: end)
            if result.indices.contains(index - 1), result[index - 1].stage == atom.stage,
               result[index - 1].end == atom.start {
                result[index - 1] = Atom(stage: atom.stage, start: result[index - 1].start, end: atom.end)
            } else {
                result.append(atom)
                index += 1
            }
        }
        return result
    }

    /// 来源内候选会话：可信睡着原子（core/deep/rem/unspecified，不含冲突/清醒/在床）
    /// 归并后按 3 小时间隔聚类（沿用切分器口径），每簇带上可链的尾巴原子段。
    private static func sourceCandidates(from samples: [HealthNightSample], source: HealthSleepSource) -> [SourceCandidate] {
        let resolved = atoms(from: samples)
        let trustedAtoms = resolved.filter { atom in
            switch atom.stage {
            case .core, .deep, .rem, .unspecified: return true
            default: return false
            }
        }
        let trustedIntervals = HealthSleepSampleAggregator.merged(
            trustedAtoms.map { Interval(start: $0.start, end: $0.end) }
        )
        guard !trustedIntervals.isEmpty else { return [] }

        // 3 小时间隔聚类
        var clusters: [[Interval]] = [[trustedIntervals[0]]]
        for interval in trustedIntervals.dropFirst() {
            let gap = interval.start.timeIntervalSince(clusters[clusters.count - 1].last!.end)
            if gap < HealthSleepSessionSplitter.sessionGapThreshold {
                clusters[clusters.count - 1].append(interval)
            } else {
                clusters.append([interval])
            }
        }

        let tailChain = HealthSleepSessionSplitter.tailChainGapThreshold
        let timezoneIDs = Set(samples.compactMap(\.timezoneID))

        return clusters.map { cluster in
            let start = cluster.first!.start
            let asleepEnd = cluster.last!.end
            let spanStart = start.addingTimeInterval(-tailChain)
            let spanEnd = asleepEnd.addingTimeInterval(tailChain)
            let sessionAtoms = resolved.filter { $0.end > spanStart && $0.start < spanEnd }
            let stagedSeconds = sessionAtoms
                .filter { $0.stage == .core || $0.stage == .deep || $0.stage == .rem }
                .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            let asleepSeconds = cluster.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            return SourceCandidate(
                source: source,
                trusted: cluster,
                start: start,
                asleepEnd: asleepEnd,
                asleepSeconds: asleepSeconds,
                stagedSeconds: stagedSeconds,
                atoms: sessionAtoms,
                timezoneIDs: timezoneIDs
            )
        }
    }

    // MARK: - 跨来源对照

    /// 候选按「可信睡着区间重叠 ≥ overlapMatchMinimum」并查集成组：
    /// 同组候选视为在描述同一段睡眠。
    private static func matchGroups(of candidates: [SourceCandidate]) -> [[SourceCandidate]] {
        var parent = Array(candidates.indices)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var current = i
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            parent[rb] = ra
        }
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                if overlapSeconds(candidates[i].trusted, candidates[j].trusted) >= overlapMatchMinimum {
                    union(i, j)
                }
            }
        }
        var groups: [Int: [SourceCandidate]] = [:]
        for i in candidates.indices {
            groups[find(i), default: []].append(candidates[i])
        }
        return Array(groups.values)
    }

    /// 两组区间的重叠总秒数
    private static func overlapSeconds(_ a: [Interval], _ b: [Interval]) -> TimeInterval {
        var total: TimeInterval = 0
        for ia in a {
            for ib in b {
                let start = max(ia.start, ib.start)
                let end = min(ia.end, ib.end)
                if end > start { total += end.timeIntervalSince(start) }
            }
        }
        return total
    }

    /// 组内裁决 → 会话列表。
    /// 单候选直接产出；多候选先看首尾是否都在 30 分钟内（相互印证）：
    /// 印证则优先采纳分期覆盖更完整的整段候选；分期难分伯仲时取时长并集、
    /// 分期待确认；偏差明显则产出带候选列表的待确认壳并退出趋势。
    private static func adjudicate(_ groups: [[SourceCandidate]], readWindow: Interval) -> [HealthNightSession] {
        groups.flatMap { group -> [HealthNightSession] in
            let sorted = group.sorted {
                $0.asleepSeconds != $1.asleepSeconds
                    ? $0.asleepSeconds > $1.asleepSeconds
                    : $0.source.name < $1.source.name
            }
            guard let longest = sorted.first else { return [] }
            let others = sorted.dropFirst()

            // 边界完整性：可信区间触到读取窗口首尾
            func touchesBoundary(_ candidate: SourceCandidate) -> Bool {
                candidate.trusted.first!.start.timeIntervalSince(readWindow.start) <= boundaryEpsilon
                    || readWindow.end.timeIntervalSince(candidate.trusted.last!.end) <= boundaryEpsilon
            }

            func timezone(of candidate: SourceCandidate) -> (id: String?, verified: Bool) {
                switch candidate.timezoneIDs.count {
                case 1: return (candidate.timezoneIDs.first!, true)
                default: return (nil, false)   // 无线索或线索不一致：保留时长，暂停钟点比较
                }
            }

            func sources(_ list: [SourceCandidate]) -> [HealthSleepSource] {
                var seen: Set<String> = []
                return list.compactMap { candidate in
                    seen.insert(candidate.source.name).inserted ? candidate.source : nil
                }.sorted { $0.name < $1.name }
            }

            let boundary = group.contains { touchesBoundary($0) }

            // 多来源：相互印证判定（所有候选首尾与最长者相差 ≤ boundaryTolerance）
            if !others.isEmpty {
                let corroborated = others.allSatisfy { other in
                    abs(other.start.timeIntervalSince(longest.start)) <= boundaryTolerance
                        && abs(other.asleepEnd.timeIntervalSince(longest.asleepEnd)) <= boundaryTolerance
                }
                if corroborated {
                    // 分期覆盖更完整者优先（并列取时长最长者，sorted 已保证稳定）
                    let bestIndex = sorted.indices.max { a, b in
                        sorted[a].stagedSeconds != sorted[b].stagedSeconds
                            ? sorted[a].stagedSeconds < sorted[b].stagedSeconds
                            : sorted[a].asleepSeconds < sorted[b].asleepSeconds
                    }!
                    let best = sorted[bestIndex]
                    let runnerUpStaged = sorted.enumerated()
                        .filter { $0.offset != bestIndex }
                        .map(\.element.stagedSeconds)
                        .max() ?? 0
                    let decisive = best.stagedSeconds > 0 && best.stagedSeconds > runnerUpStaged
                    if decisive {
                        // 同一时刻只采用一套分期：整段采纳该候选
                        return [session(
                            from: best,
                            kind: .otherSleep,
                            status: best.stagedSeconds > 0 ? .staged : .unstaged,
                            allSources: sources(sorted),
                            boundary: boundary,
                            excluded: false
                        )]
                    }
                    // 只有时长一致且分期难以裁决：时长用并集，分期待确认
                    let union = HealthSleepSampleAggregator.merged(sorted.flatMap(\.trusted))
                    return [pendingSession(
                        trusted: union,
                        status: .corroboratedPending,
                        allSources: sources(sorted),
                        boundary: boundary,
                        timezone: (id: nil, verified: false),
                        clockExcluded: false,
                        trendExcluded: false,
                        candidates: []
                    )]
                }
                // 时间偏差明显且无可信优先依据：展示候选，待确认并退出趋势
                return [pendingSession(
                    trusted: longest.trusted,
                    status: .conflicting,
                    allSources: sources(sorted),
                    boundary: boundary,
                    timezone: timezone(of: longest),
                    clockExcluded: true,
                    trendExcluded: true,
                    candidates: sorted.map { candidate in
                        HealthNightSession.Candidate(
                            source: candidate.source,
                            start: candidate.start,
                            asleepEnd: candidate.asleepEnd,
                            asleepSeconds: candidate.asleepSeconds,
                            staged: candidate.stagedSeconds > 0
                        )
                    }
                )]
            }

            // 单来源
            let status: HealthNightSession.StageStatus = longest.stagedSeconds > 0 ? .staged : .unstaged
            return [session(
                from: longest,
                kind: .otherSleep,
                status: status,
                allSources: sources(sorted),
                boundary: boundary,
                excluded: false
            )]
        }
    }

    // MARK: - 会话组装

    private static func session(
        from candidate: SourceCandidate,
        kind: HealthNightSession.Kind,
        status: HealthNightSession.StageStatus,
        allSources: [HealthSleepSource],
        boundary: Bool,
        excluded: Bool
    ) -> HealthNightSession {
        let tz = candidate.timezoneIDs.count == 1 ? candidate.timezoneIDs.first : nil
        let timeline = candidate.atoms.compactMap { atom -> HealthSleepSegment? in
            let stage: HealthSleepSegment.Stage
            switch atom.stage {
            case .core: stage = .asleepCore
            case .deep: stage = .asleepDeep
            case .rem: stage = .asleepREM
            case .unspecified: stage = .asleepUnspecified
            case .awake: stage = .awake
            case .inBed: stage = .inBedAwake
            case .conflict: stage = .conflict
            }
            return HealthSleepSegment(stage: stage, start: atom.start, end: atom.end)
        }
        .sorted { $0.start < $1.start }

        let stageHours: HealthNightStageHours? = {
            guard candidate.stagedSeconds > 0 else { return nil }
            func hours(_ stage: Atom.Stage) -> Double {
                candidate.atoms
                    .filter { $0.stage == stage }
                    .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
            }
            return HealthNightStageHours(core: hours(.core), deep: hours(.deep), rem: hours(.rem))
        }()

        let wakeCount = candidate.atoms
            .filter { $0.stage == .awake && $0.end.timeIntervalSince($0.start) >= wakeMinimum && $0.start < candidate.asleepEnd }
            .count

        let bedStart = candidate.atoms
            .filter { $0.stage == .inBed && $0.end > candidate.start }
            .map(\.start)
            .min()
        let sessionEnd = candidate.atoms.map(\.end).max() ?? candidate.asleepEnd

        return HealthNightSession(
            kind: kind,
            start: candidate.start,
            asleepEnd: candidate.asleepEnd,
            bedStart: bedStart,
            sessionEnd: sessionEnd,
            asleepSeconds: candidate.asleepSeconds,
            timeline: timeline,
            stageHours: stageHours,
            awakeInterruptions: candidate.atoms.contains { $0.stage == .awake } ? wakeCount : nil,
            sources: allSources,
            stageStatus: status,
            candidates: [],
            excludedFromTrends: excluded,
            excludedFromClockTrends: candidate.timezoneIDs.count > 1,
            possiblyIncomplete: boundary,
            timezoneID: tz
        )
    }

    /// 印证但分期待裁决 / 来源冲突的壳会话
    private static func pendingSession(
        trusted: [Interval],
        status: HealthNightSession.StageStatus,
        allSources: [HealthSleepSource],
        boundary: Bool,
        timezone: (id: String?, verified: Bool),
        clockExcluded: Bool,
        trendExcluded: Bool,
        candidates: [HealthNightSession.Candidate]
    ) -> HealthNightSession {
        let start = trusted.first!.start
        let asleepEnd = trusted.last!.end
        let asleepSeconds = trusted.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        // 来源冲突时只展示候选记录，不合成一条看似可信的时间轴
        let timeline: [HealthSleepSegment] = status == .conflicting ? [] : trusted.map {
            HealthSleepSegment(stage: .asleepUnspecified, start: $0.start, end: $0.end)
        }
        return HealthNightSession(
            kind: .otherSleep,
            start: start,
            asleepEnd: asleepEnd,
            bedStart: nil,
            sessionEnd: asleepEnd,
            asleepSeconds: asleepSeconds,
            timeline: timeline,
            stageHours: nil,
            awakeInterruptions: nil,
            sources: allSources,
            stageStatus: status,
            candidates: candidates,
            excludedFromTrends: trendExcluded,
            excludedFromClockTrends: clockExcluded,
            possiblyIncomplete: boundary,
            timezoneID: timezone.id
        )
    }

    // MARK: - 定类辅助

    /// 小睡：整段落在当地 09:00–21:00 且睡着短于 3 小时（试用口径）
    private static func isNap(_ session: HealthNightSession, calendar: Calendar, timezoneID: String) -> Bool {
        guard session.asleepSeconds < napMaximum,
              let tz = TimeZone(identifier: timezoneID) else { return false }
        var tzCalendar = calendar
        tzCalendar.timeZone = tz
        let startHour = tzCalendar.component(.hour, from: session.start)
        let startMinute = Double(startHour) + Double(tzCalendar.component(.minute, from: session.start)) / 60
        let endHour = tzCalendar.component(.hour, from: session.asleepEnd)
        let endMinute = Double(endHour) + Double(tzCalendar.component(.minute, from: session.asleepEnd)) / 60
        return startMinute >= Double(napWindowStartHour) && endMinute <= Double(napWindowEndHour)
    }

    /// 重打 kind（会话来自裁决时统一 otherSleep，归属分型时再定）
    private static func retag(_ session: HealthNightSession, kind: HealthNightSession.Kind) -> HealthNightSession {
        var updated = session
        updated.kind = kind
        return updated
    }
}
