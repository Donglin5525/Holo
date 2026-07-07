//
//  EffectiveRecordDayModels.swift
//  Holo
//
//  本周观察「有效记录日」聚合模型与纯逻辑聚合器
//  见 docs/_common/plans/2026-07-07-Holo本周观察-最终实施方案.md §3.3 / §4.3
//
//  设计：纯逻辑核心（本文件）不依赖 Core Data，可被 standalone test 覆盖；
//  Service 层（EffectiveRecordDayService）负责从各 Repository 取数 + 缓存。
//

import Foundation

// MARK: - Module

/// 有效记录日来源模块（V1 四类，方案 §3.3）
enum EffectiveRecordModule: String, Codable, CaseIterable {
    case finance   // 新增记账记录
    case todo      // 新增或完成待办
    case habit     // 完成习惯打卡
    case thought   // 新增想法/观点记录
}

// MARK: - Eligibility

/// 本周观察触发资格（基于有效记录日 + 跨模块覆盖）
enum ObservationEligibility: Equatable, Codable, Sendable {
    /// 养成期：有效记录日不足，胶囊提示「Holo 正在认识你」
    case nurturing
    /// ≥3 个有效记录日 且 累计覆盖 ≥2 模块 → 可生成 light3d（方案 §3.4）
    case lightReady
    /// ≥7 个有效记录日 且 累计覆盖 ≥2 模块 → 可生成 full7d（G6 窗口级跨模块门槛）
    case fullReady

    /// 对应观察阶段的 rawValue，与 MemoryInsightObservationStage.rawValue 对齐（light3d / full7d）。
    /// 纯逻辑层不引用数据层枚举以保证可独立测试；Service 层负责构造 MemoryInsightObservationStage。
    var observationStageRawValue: String? {
        switch self {
        case .nurturing: return nil
        case .lightReady: return "light3d"
        case .fullReady: return "full7d"
        }
    }
}

// MARK: - Result

/// 有效记录日聚合结果（不可变值类型）
struct EffectiveRecordDayResult: Equatable, Codable, Sendable {
    /// 有效记录日（startOfDay 去重，仅含今天及之前）
    let recordDays: Set<Date>
    /// 累计覆盖的模块（窗口级，方案 G6：累计覆盖 ≥2 模块，非每天 ≥2 模块）
    let coveredModules: Set<EffectiveRecordModule>
    /// 触发资格
    let eligibility: ObservationEligibility

    var recordDayCount: Int { recordDays.count }

    /// 胶囊养成期口径文案（方案 §2.1）
    var nurturingHint: String {
        switch eligibility {
        case .nurturing:
            // 天数够但累计模块不足 → 提示多样化；模块够但天数不足 → 提示继续记录
            if recordDayCount >= EffectiveRecordDayAggregator.lightThreshold
                && coveredModules.count < EffectiveRecordDayAggregator.moduleThreshold {
                return "再记录一种内容，观察会更准"
            }
            let remaining = max(1, EffectiveRecordDayAggregator.lightThreshold - recordDayCount)
            return "再记录 \(remaining) 天生成观察"
        case .lightReady:
            let remaining = max(1, EffectiveRecordDayAggregator.fullThreshold - recordDayCount)
            return "再记录 \(remaining) 天，观察会更完整"
        case .fullReady:
            return "本周观察已准备好"
        }
    }
}

// MARK: - Aggregator（纯逻辑）

/// 有效记录日纯逻辑聚合器（无 Core Data 依赖，可 standalone test）
enum EffectiveRecordDayAggregator {

    /// 触发轻量观察的最少有效记录日（方案 §3.4）
    static let lightThreshold = 3
    /// 触发完整观察的最少有效记录日（方案 §3.4）
    static let fullThreshold = 7
    /// 跨模块覆盖门槛（G6 窗口级，累计 ≥2 模块）
    static let moduleThreshold = 2

    /// 聚合四模块的有效记录日，输出触发资格
    /// - Parameters:
    ///   - financeDays: 记账有效记录日（每个元素为 startOfDay）
    ///   - todoDays: 待办有效记录日
    ///   - habitDays: 习惯打卡有效记录日
    ///   - thoughtDays: 想法有效记录日
    ///   - today: 参考今日（截断未来日期；测试可注入）
    /// - Note: 同一天多个模块有记录，只计 1 个有效记录日（Set 天然去重）。
    ///         跨模块门槛是累计（窗口级），不是每天 ≥2 模块（G6，避免误伤单模块新用户）。
    static func aggregate(
        financeDays: Set<Date>,
        todoDays: Set<Date>,
        habitDays: Set<Date>,
        thoughtDays: Set<Date>,
        today: Date
    ) -> EffectiveRecordDayResult {
        var allDays = Set<Date>()
        var modules = Set<EffectiveRecordModule>()

        func merge(_ days: Set<Date>, _ module: EffectiveRecordModule) {
            guard !days.isEmpty else { return }
            modules.insert(module)
            allDays.formUnion(days)
        }
        merge(financeDays, .finance)
        merge(todoDays, .todo)
        merge(habitDays, .habit)
        merge(thoughtDays, .thought)

        // 仅保留今天及之前的有效记录日（未来日期不计入养成进度）
        let todayStart = Calendar.current.startOfDay(for: today)
        allDays = allDays.filter { $0 <= todayStart }

        let eligibility: ObservationEligibility
        if allDays.count >= fullThreshold && modules.count >= moduleThreshold {
            eligibility = .fullReady
        } else if allDays.count >= lightThreshold && modules.count >= moduleThreshold {
            eligibility = .lightReady
        } else {
            eligibility = .nurturing
        }

        return EffectiveRecordDayResult(
            recordDays: allDays,
            coveredModules: modules,
            eligibility: eligibility
        )
    }
}
