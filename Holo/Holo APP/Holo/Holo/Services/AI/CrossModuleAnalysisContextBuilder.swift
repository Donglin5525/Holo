//
//  CrossModuleAnalysisContextBuilder.swift
//  Holo
//
//  跨模块分析上下文构建器
//  从各模块 context 中提取亮点和风险
//

import Foundation

struct CrossModuleAnalysisContextBuilder {

    /// 从各模块 context 中提取亮点和风险
    func build(
        finance: FinanceAnalysisContext?,
        habit: HabitAnalysisContext?,
        task: TaskAnalysisContext?,
        thought: ThoughtAnalysisContext?,
        health: HealthAnalysisContext?,
        goal: GoalAnalysisContext?
    ) -> CrossModuleAnalysisContext {
        var highlights: [String] = []
        var warnings: [String] = []

        // 财务亮点/风险
        if let f = finance, !f.isDataFree {
            if let prev = f.previousPeriodExpense, prev > 0 {
                if f.totalExpense < prev {
                    let saved = prev - f.totalExpense
                    highlights.append("支出较上周期减少 \(NumberFormatter.compactCurrency(saved))")
                } else if f.totalExpense > prev {
                    let extra = f.totalExpense - prev
                    warnings.append("支出较上周期增加 \(NumberFormatter.compactCurrency(extra))")
                }
            } else {
                if f.totalIncome > f.totalExpense {
                    highlights.append("收入大于支出，财务状况健康")
                }
            }

            if let budget = f.budgetPerformance, budget.utilizationRate > 100 {
                warnings.append("预算已超支 \(String(format: "%.0f", budget.utilizationRate))%")
            }
        }

        // 习惯亮点/风险
        if let h = habit, !h.isDataFree {
            if let rate = h.averageCompletionRate, rate >= 0.8 {
                highlights.append(String(format: "习惯完成率 %.0f%%，表现优秀", rate * 100))
            } else if let rate = h.averageCompletionRate, rate < 0.5 {
                warnings.append(String(format: "习惯完成率仅 %.0f%%，需要加油", rate * 100))
            }

            if let topStreak = h.streaks.first, topStreak.currentStreak >= 7 {
                highlights.append("\(topStreak.habitName) 连续打卡 \(topStreak.currentStreak) 天")
            }
        }

        // 任务亮点/风险
        if let t = task, !t.isDataFree {
            if t.completionRate >= 0.8 {
                highlights.append(String(format: "任务完成率 %.0f%%，执行力强", t.completionRate * 100))
            } else if t.completionRate < 0.5 {
                warnings.append(String(format: "任务完成率仅 %.0f%%，有 \(t.overdueCount) 个逾期", t.completionRate * 100))
            }

            if t.overdueCount > 3 {
                warnings.append("逾期任务较多（\(t.overdueCount) 个），建议优先处理")
            }
        }

        // 想法亮点
        if let th = thought, !th.isDataFree {
            if th.totalCount >= 10 {
                highlights.append("记录了 \(th.totalCount) 条想法，保持了良好的思考习惯")
            }
            if let topMood = th.moodDistribution.first {
                highlights.append("最常见的心情是「\(topMood.mood)」")
            }
        }

        // 健康亮点/风险
        if let ht = health, !ht.isDataFree {
            if let score = ht.overallBodyScore {
                if score >= 80 {
                    highlights.append(String(format: "健康体表分 %.0f，状态良好", score))
                } else if score < 50 {
                    warnings.append(String(format: "健康体表分仅 %.0f，需要关注", score))
                }
            }
            if let prevScore = ht.previousPeriodScore, let currScore = ht.overallBodyScore {
                let diff = currScore - prevScore
                if diff > 10 {
                    highlights.append(String(format: "体表分较上期提升 %.0f 分", diff))
                } else if diff < -10 {
                    warnings.append(String(format: "体表分较上期下降 %.0f 分", abs(diff)))
                }
            }
            for anomaly in ht.anomalyNotes {
                warnings.append(anomaly)
            }
        }

        // 目标亮点/风险
        if let g = goal, !g.isDataFree {
            if g.totalActiveGoals > 0 && g.atRiskGoals.isEmpty {
                highlights.append("\(g.totalActiveGoals) 个活跃目标均无风险")
            }
            if !g.atRiskGoals.isEmpty {
                warnings.append("\(g.atRiskGoals.count) 个目标存在风险：\(g.atRiskGoals.joined(separator: "、"))")
            }
            if g.completedGoalsInPeriod > 0 {
                highlights.append("本周期完成了 \(g.completedGoalsInPeriod) 个目标")
            }
        }

        return CrossModuleAnalysisContext(
            highlights: Array(highlights.prefix(7)),
            warnings: Array(warnings.prefix(5))
        )
    }
}
