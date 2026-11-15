//
//  MemoryRandomWalkSampler.swift
//  Holo
//
//  随机漫步的日期抽样（暖光规格 §5.2）：
//  - 候选日等权随机；首抽有「距今天 ≥30 天」候选时优先从那部分抽
//  - 已抵达才计入本轮已看集合；重开一轮首站尽量避开刚看过的日子
//  - 随机源注入，测试可写死序列验证去重与 176 天样例
//

import Foundation

struct MemoryRandomWalkSampler {
    /// 返回 [0,1) 均匀随机数；生产注入 SystemRandomNumberGenerator。
    let next: () -> Double

    static let production = MemoryRandomWalkSampler(next: { Double.random(in: 0..<1) })

    /// 抽一个候选日。
    ///
    /// - Parameters:
    ///   - candidates: 有记录的本地日（已剔除今天与未来）。
    ///   - visited: 本轮已抵达的日子。
    ///   - today: 本地今天（按日差算距离）。
    ///   - isFirstOfRound: 本轮首抽（含「重新漫步」后的新首站）——满足 ≥30 天的候选优先。
    ///   - lastSeen: 刚看过的日子（重新漫步首站尽量避开）。
    /// - Returns: 抽中的日；候选耗尽返回 nil。
    func draw(candidates: [Date],
              excluding visited: Set<Date>,
              today: Date,
              calendar: Calendar = .current,
              isFirstOfRound: Bool,
              lastSeen: Date?) -> Date? {
        let eligible = candidates.filter { !visited.contains($0) }
        guard !eligible.isEmpty else { return nil }

        var pool = eligible
        if isFirstOfRound {
            let startOfToday = calendar.startOfDay(for: today)
            let distant = eligible.filter { day in
                guard let days = calendar.dateComponents([.day], from: day, to: startOfToday).day else {
                    return false
                }
                return days >= 30
            }
            if !distant.isEmpty { pool = distant }
            // 首站避开刚看过的日子（候选多于一个时）。
            if pool.count > 1, let lastSeen {
                pool.removeAll { $0 == lastSeen }
            }
        }
        guard !pool.isEmpty else { return nil }
        let index = min(pool.count - 1, Int(next() * Double(pool.count)))
        return pool[index]
    }
}
