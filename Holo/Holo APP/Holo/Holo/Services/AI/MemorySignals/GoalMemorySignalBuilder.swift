//
//  GoalMemorySignalBuilder.swift
//  Holo
//
//  从目标数据生成记忆信号（纯规则，不涉及 LLM）
//

import Foundation

/// 目标进度输入（从 Goal Core Data 实体提取的轻量级结构）
struct GoalProgressInput {
    var id: String
    var title: String
    var deadline: Date?
    var createdAt: Date
    var completedAt: Date?
    var status: String  // GoalStatus rawValue
    var taskTotal: Int
    var taskCompleted: Int

    /// 进度百分比 [0.0, 1.0]
    var progress: Double {
        guard taskTotal > 0 else { return completedAt != nil ? 1.0 : 0.0 }
        return Double(taskCompleted) / Double(taskTotal)
    }

    /// 预期进度（基于创建时间到 deadline 的线性进度）
    var expectedProgress: Double {
        guard let deadline else {
            // 无 deadline 时按创建天数 30 天为周期
            let daysSinceCreation = Calendar.current.dateComponents([.day], from: createdAt, to: Date()).day ?? 0
            return min(Double(daysSinceCreation) / 30.0, 1.0)
        }
        let total = Calendar.current.dateComponents([.day], from: createdAt, to: deadline).day ?? 1
        let elapsed = Calendar.current.dateComponents([.day], from: createdAt, to: Date()).day ?? 0
        guard total > 0 else { return 1.0 }
        return min(Double(elapsed) / Double(total), 1.0)
    }

    var isCompleted: Bool { completedAt != nil || status == "completed" }

    var daysRemaining: Int? {
        guard let deadline else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: deadline).day
    }
}

struct GoalMemorySignalBuilder {

    /// 从目标进度数据生成记忆信号
    /// - Parameter goals: 目标进度输入列表（由上层从 GoalRepository 提取）
    /// - Returns: 高密度信号列表
    static func buildSignals(from goals: [GoalProgressInput]) -> [HoloMemorySignal] {
        var signals: [HoloMemorySignal] = []
        let now = Date()

        for goal in goals {
            // 触发条件 4：已完成
            if goal.isCompleted {
                signals.append(HoloMemorySignal(
                    id: "goal-completed-\(goal.id)",
                    title: "\(goal.title)目标已完成",
                    detail: "共 \(goal.taskTotal) 个任务，完成 \(goal.taskCompleted) 个",
                    polarity: .positive,
                    confidence: 0.9,
                    sourceModule: .goals,
                    evidenceRefs: ["goal:\(goal.id):completed:\(goal.taskCompleted)/\(goal.taskTotal)"],
                    generatedAt: now
                ))
                continue
            }

            let ratio = goal.expectedProgress > 0 ? goal.progress / goal.expectedProgress : 1.0

            // 触发条件 1：进度 < 预期 × 0.5（严重落后）
            if ratio < 0.5 {
                signals.append(HoloMemorySignal(
                    id: "goal-severe-\(goal.id)",
                    title: "\(goal.title)目标严重落后",
                    detail: "进度 \(String(format: "%.0f%%", goal.progress * 100))，预期 \(String(format: "%.0f%%", goal.expectedProgress * 100))，完成 \(goal.taskCompleted)/\(goal.taskTotal) 个任务",
                    polarity: .negative,
                    confidence: 0.8,
                    sourceModule: .goals,
                    evidenceRefs: ["goal:\(goal.id):progress:\(String(format: "%.2f", goal.progress))"],
                    generatedAt: now
                ))
                continue
            }

            // 触发条件 2：进度 < 预期 × 0.7（偏慢）
            if ratio < 0.7 {
                signals.append(HoloMemorySignal(
                    id: "goal-slow-\(goal.id)",
                    title: "\(goal.title)目标进度偏慢",
                    detail: "进度 \(String(format: "%.0f%%", goal.progress * 100))，预期 \(String(format: "%.0f%%", goal.expectedProgress * 100))",
                    polarity: .negative,
                    confidence: 0.6,
                    sourceModule: .goals,
                    evidenceRefs: ["goal:\(goal.id):progress:\(String(format: "%.2f", goal.progress))"],
                    generatedAt: now
                ))
            }

            // 触发条件 3：剩余 < 7 天且未完成
            if let remaining = goal.daysRemaining, remaining < 7, remaining >= 0 {
                signals.append(HoloMemorySignal(
                    id: "goal-deadline-\(goal.id)",
                    title: "\(goal.title)目标即将到期",
                    detail: "剩余 \(remaining) 天，进度 \(String(format: "%.0f%%", goal.progress * 100))",
                    polarity: .mixed,
                    confidence: 0.7,
                    sourceModule: .goals,
                    evidenceRefs: ["goal:\(goal.id):daysRemaining:\(remaining)"],
                    generatedAt: now
                ))
            }
        }

        return signals.filter { $0.confidence > 0.4 }
    }
}
