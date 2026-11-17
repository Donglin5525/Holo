//
//  GalleryFeaturedRecordPolicy.swift
//  Holo
//
//  长廊「日代表记录」的确定性选择规则（2026-11-16 方案 04 §2.1，fixtures C01–C09）：
//  手选 active/pending 保持手选身份（图片未到显示占位不偷换）；手选 deleted 回退自动；
//  自动按 手选(无效时) > hero > legacyPhoto > text > other，同级业务时间倒序、
//  事件键升序 tie-break；count 按去重原事件键计（不因贴纸多处使用而增加）；
//  loadState = loadedEmpty / loaded / partial。纯函数：不访问网络、不运行 AI。
//

import Foundation

enum GalleryCandidateKind: Int, Comparable {
    case hero = 0          // 有显式头图的想法
    case legacyPhoto = 1   // 有有效旧附件的想法
    case text = 2          // 有可读原文的想法
    case other = 3         // 其他有可靠时刻的真实事件（含各模块图标身份）

    static func < (lhs: GalleryCandidateKind, rhs: GalleryCandidateKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct GalleryCandidateEvent: Equatable {
    /// 身份键 (module, sourceRecordUUID)
    let key: String
    let kind: GalleryCandidateKind
    /// 业务发生时间序（大 = 晚）；不可靠时间由调用方预先归到 reliableTime=false
    let occurredOrder: Int
    let visible: Bool
    let reliableTime: Bool
    let deleted: Bool
}

enum GalleryManualAvailability: String, Equatable {
    case active
    case pending
    case deleted
}

struct GalleryManualSelection: Equatable {
    let key: String
    let availability: GalleryManualAvailability
}

enum GalleryDayLoadState: String, Equatable {
    case loadedEmpty
    case loaded
    case partial
    case failed
}

struct GalleryFeaturedOutcome: Equatable {
    /// 选中的日代表事件键；nil = 无代表（空日）
    let featured: String?
    /// 去重后的原事件总数（含已删除的历史事件；不含素材/位置写入本身）
    let count: Int
    let state: GalleryDayLoadState
}

enum GalleryFeaturedRecordPolicy {

    /// 纯函数主体；events 的 occurredOrder 不可靠者按 other 且 order=0 处理
    static func select(events: [GalleryCandidateEvent],
                       loadComplete: Bool,
                       manual: GalleryManualSelection?) -> GalleryFeaturedOutcome {
        // count：去重原事件键（含 deleted——历史记录存在过）
        let distinctKeys = Set(events.map(\.key))
        let count = distinctKeys.count

        guard !distinctKeys.isEmpty || manual != nil else {
            return .init(featured: nil, count: count,
                         state: loadComplete ? .loadedEmpty : .partial)
        }

        // 手选：active/pending 保持身份（图片未到占位，不偷换）；deleted 回退自动
        var featured: String?
        if let manual {
            switch manual.availability {
            case .active, .pending:
                featured = manual.key
            case .deleted:
                featured = nil
            }
        }

        if featured == nil {
            // 自动：可见、未删、可靠时间优先参与；不可靠时间者垫底（04 §2.1 第 6 级）
            let candidates = events.filter { $0.visible && !$0.deleted }
            let ranked = candidates.sorted { a, b in
                let ra = (kind: a.kind, reliable: a.reliableTime)
                let rb = (kind: b.kind, reliable: b.reliableTime)
                if ra != rb {
                    // kind 优先，再可靠时间
                    if a.kind != b.kind { return a.kind < b.kind }
                    return a.reliableTime && !b.reliableTime
                }
                if a.occurredOrder != b.occurredOrder { return a.occurredOrder > b.occurredOrder }
                return a.key < b.key
            }
            // 其他模块事件只作身份标记，不抢图片代表（04 §1 注：首版图片候选仅想法）
            featured = ranked.first(where: { $0.kind != .other })?.key ?? ranked.first?.key
        }

        let state: GalleryDayLoadState
        if !loadComplete {
            state = .partial
        } else if let manual, manual.availability != .deleted, !distinctKeys.contains(manual.key) {
            // 手选记录尚未到达（所属模块未同步完）：部分载入，不伪装完整（04 §2.2）
            state = .partial
        } else {
            state = distinctKeys.isEmpty ? .loadedEmpty : .loaded
        }
        return .init(featured: featured, count: count, state: state)
    }

    /// 日键规范编码（04 §3.3）：identifier+era+year+month+isLeapMonth+day+timeZone
    static func dayKey(for date: Date, calendar: Calendar, timeZone: TimeZone) -> String {
        var local = calendar
        local.timeZone = timeZone
        let comps = local.dateComponents([.year, .month, .day, .era], from: date)
        let leap = comps.isLeapMonth ?? false
        return "\(local.identifier)|e\(comps.era ?? 1)|\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)\(leap ? "L" : "")|\(timeZone.identifier)"
    }
}
