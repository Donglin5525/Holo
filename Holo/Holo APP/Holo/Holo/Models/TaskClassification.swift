//
//  TaskClassification.swift
//  Holo
//
//  任务轻重缓急两个独立分类维度（2026-10-06 任务重构方案 §3/§8.1）：
//  重要性由用户判断（未判断进待整理），紧急程度按日期自动折算、可手动锁定。
//  2026-10-07 东林拍板 P 档体系：两轴各 P1/P2/P3 三档，组合出「紧急分」
//  （重要×2＋紧急，3–9 分）作为列表排序的硬通货。
//  raw 分配沿用 10-06 两值（1=重要→P1，2=不重要→P3；紧急 1=手动紧急→P1，
//  2=手动不紧急→P3），新增档一律挂 raw=3——旧数据零迁移直读。
//  与旧 priority 字段并存互不映射；不持久化象限与分数，均随日期实时解析。
//

import Foundation
import os.log

// MARK: - 重要性

/// 任务重要性：用户对「这件事重不重要」的判断；unknown 表示尚未判断（进待整理）。
nonisolated enum TaskImportance: Int16, CaseIterable, Equatable, Sendable {
    /// 暂未判断（进入待整理）
    case unknown = 0
    /// P1：重要
    case p1 = 1
    /// P3：不重要（沿用 10-06 notImportant 的 raw=2）
    case p3 = 2
    /// P2：一般（10-07 新增档）
    case p2 = 3

    var displayTitle: String {
        switch self {
        case .unknown: return String(localized: "暂未判断")
        case .p1: return "P1"
        case .p2: return "P2"
        case .p3: return "P3"
        }
    }

    /// P 档语义（列表摘要/无障碍用）
    var meaning: String {
        switch self {
        case .unknown: return String(localized: "暂未判断")
        case .p1: return String(localized: "重要")
        case .p2: return String(localized: "一般")
        case .p3: return String(localized: "不重要")
        }
    }

    /// 紧急分权重：P1=3 / P2=2 / P3=1（unknown 无分，见 TaskQuadrantResolver.urgencyScore）
    var scoreValue: Int? {
        switch self {
        case .unknown: return nil
        case .p1: return 3
        case .p2: return 2
        case .p3: return 1
        }
    }

    /// 滑杆档位（0=P3 → 1=P2 → 2=P1，从轻到重）；unknown 为 nil
    var leverIndex: Int? {
        switch self {
        case .unknown: return nil
        case .p3: return 0
        case .p2: return 1
        case .p1: return 2
        }
    }

    init?(leverIndex: Int) {
        switch leverIndex {
        case 0: self = .p3
        case 1: self = .p2
        case 2: self = .p1
        default: return nil
        }
    }
}

// MARK: - 紧急方式

/// 紧急程度的判断方式：auto 按截止日期自动折算 P 档，其余为用户手动锁定。
/// 「当前折算到哪一档」随日期变化，不落库（方案 §3.1）。
nonisolated enum TaskUrgencyMode: Int16, CaseIterable, Equatable, Sendable {
    /// 按截止日期自动折算
    case auto = 0
    /// 手动锁定 P1（紧急；沿用 10-06 urgent 的 raw=1）
    case p1 = 1
    /// 手动锁定 P3（不紧急；沿用 10-06 notUrgent 的 raw=2）
    case p3 = 2
    /// 手动锁定 P2（一般急；10-07 新增档）
    case p2 = 3

    var displayTitle: String {
        switch self {
        case .auto: return String(localized: "按日期")
        case .p1: return "P1"
        case .p2: return "P2"
        case .p3: return "P3"
        }
    }

    var isManual: Bool { self != .auto }

    /// 滑杆档位（0=P3 → 1=P2 → 2=P1）；auto 为 nil
    var leverIndex: Int? {
        switch self {
        case .auto: return nil
        case .p3: return 0
        case .p2: return 1
        case .p1: return 2
        }
    }

    init?(leverIndex: Int) {
        switch leverIndex {
        case 0: self = .p3
        case 1: self = .p2
        case 2: self = .p1
        default: return nil
        }
    }
}

// MARK: - 象限（只读派生值）

/// 四象限分组结果 + 待整理；由 TaskQuadrantResolver 实时解析，不持久化。
nonisolated enum TaskQuadrant: Equatable, CaseIterable, Sendable {
    /// 重要 × 紧急：优先处理
    case doFirst
    /// 重要 × 不紧急：留出时间
    case scheduleTime
    /// 不重要 × 紧急：集中处理
    case batchHandle
    /// 不重要 × 不紧急：稍后再看
    case reviewLater
    /// 重要性未判断：待整理
    case unclassified

    var displayTitle: String {
        switch self {
        case .doFirst: return String(localized: "优先处理")
        case .scheduleTime: return String(localized: "留出时间")
        case .batchHandle: return String(localized: "集中处理")
        case .reviewLater: return String(localized: "稍后再看")
        case .unclassified: return String(localized: "待整理")
        }
    }

    /// 象限一行引导（方案 §3.2 表）
    var guidance: String {
        switch self {
        case .doFirst: return String(localized: "先推进这些事")
        case .scheduleTime: return String(localized: "安排具体执行时段")
        case .batchHandle: return String(localized: "合并处理零碎事项")
        case .reviewLater: return String(localized: "按需要保留或归档")
        case .unclassified: return String(localized: "判断这件事是否重要")
        }
    }

    /// 重要×紧急的坐标描述（无障碍/详情用）
    var axisDescription: String {
        switch self {
        case .doFirst: return String(localized: "重要不紧急程度：重要且紧急")
        case .scheduleTime: return String(localized: "重要不紧急程度：重要、不紧急")
        case .batchHandle: return String(localized: "重要不紧急程度：不重要但紧急")
        case .reviewLater: return String(localized: "重要不紧急程度：不重要、不紧急")
        case .unclassified: return String(localized: "重要性尚未判断")
        }
    }

    /// 首页四格固定显示顺序（待整理单独一行入口，不在此序内）
    static let overviewOrder: [TaskQuadrant] = [.doFirst, .scheduleTime, .batchHandle, .reviewLater]
}

// MARK: - TodoTask 桥接（raw 集中转换，未知值容错不崩溃）

extension TodoTask {

    private static let classificationLogger = Logger(
        subsystem: "com.holo.app", category: "TaskClassification"
    )

    /// 重要性（未知 raw 读取为 unknown 并记诊断日志，不批量改写）
    var importance: TaskImportance {
        get {
            let raw = TaskImportance(rawValue: importanceRaw)
            if raw == nil {
                Self.classificationLogger.notice(
                    "未知重要性 raw=\(self.importanceRaw, privacy: .public)，按暂未判断读取（任务 \(self.id.uuidString, privacy: .public)）"
                )
            }
            return raw ?? .unknown
        }
        set { importanceRaw = newValue.rawValue }
    }

    /// 紧急方式（未知 raw 读取为 auto 并记诊断日志）
    var urgencyMode: TaskUrgencyMode {
        get {
            let raw = TaskUrgencyMode(rawValue: urgencyModeRaw)
            if raw == nil {
                Self.classificationLogger.notice(
                    "未知紧急方式 raw=\(self.urgencyModeRaw, privacy: .public)，按日期自动折算读取（任务 \(self.id.uuidString, privacy: .public)）"
                )
            }
            return raw ?? .auto
        }
        set { urgencyModeRaw = newValue.rawValue }
    }
}
