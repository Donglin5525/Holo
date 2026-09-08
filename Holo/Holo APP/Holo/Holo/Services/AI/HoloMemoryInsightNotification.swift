//
//  HoloMemoryInsightNotification.swift
//  Holo
//
//  MemoryInsight 生成通知契约（回放/周期洞察共用）。
//  原长期记忆候选观察者已随旧记忆架构下线，仅保留通知名。
//

import Foundation

extension Notification.Name {
    static let memoryInsightDidGenerate = Notification.Name("memoryInsightDidGenerate")
}
