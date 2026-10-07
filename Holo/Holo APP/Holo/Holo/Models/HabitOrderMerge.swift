//
//  HabitOrderMerge.swift
//  Holo
//
//  今天列表排序合并（2026-10-07 拖拽排序批次）：
//  排序事实源 = Habit.sortOrder 的全量序列（含暂停/归档）。
//  用户重排只作用于本次可见/可排序的习惯集合（今天页两组/排序弹层），
//  落库时保持全量序列的槽位结构——参与集合的槽位依次填入新顺序，
//  未参与的习惯（暂停/归档/被筛选隐藏）位置保持不变。
//

import Foundation

enum HabitOrderMerge {

    /// 把「参与重排集合的新顺序」穿插回全量序列：
    /// 遍历全量（按当前 sortOrder 升序），槽位属于参与集合时依次取新顺序迭代器，
    /// 其余槽位保持原值。全量序列里不在参与集合中的习惯位置与相对顺序不变。
    ///
    /// - Parameters:
    ///   - allIds: 全量习惯 id（按当前 sortOrder 升序）
    ///   - newOrder: 参与重排习惯的新顺序（元素须来自 allIds）
    /// - Returns: 重排后的全量 id 序列（逐位写回 sortOrder = index）
    static func interleaveActive(allIds: [UUID], newActiveOrder: [UUID]) -> [UUID] {
        let participants = Set(newActiveOrder)
        var iterator = newActiveOrder.makeIterator()
        var result: [UUID] = []
        result.reserveCapacity(allIds.count)
        for id in allIds {
            if participants.contains(id), let next = iterator.next() {
                result.append(next)
            } else {
                result.append(id)
            }
        }
        return result
    }
}
