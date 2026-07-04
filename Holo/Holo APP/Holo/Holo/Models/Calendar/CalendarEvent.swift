//
//  CalendarEvent.swift
//  Holo
//
//  日历视图统一事件模型（单条，1:1 对应一条原始记录）
//

import Foundation
import CoreData

/// 日历视图的单条事件（一条记账 / 一条习惯打卡 / 一条待办 / 一条想法）
///
/// 设计为单条 1:1 实体（非聚合）：月历的色阶/色条由渲染层从 [CalendarEvent] 计算。
/// 不复用 MemoryItem——它是去模块化的展示 struct，丢失了模块身份与原始实体引用。
struct CalendarEvent: Identifiable, Equatable {
    let id: UUID
    let module: CalendarModule

    /// 带时刻，时间轴定位锚点
    let date: Date

    /// 列表/详情主标题
    let title: String

    /// 金额 / 数值 / 摘要等副信息
    let detail: String?

    /// P3：相关观点标题（仅想法模块，经 Thought.topics 间接体现观点维度）
    let relatedTopics: [String]?

    /// 原始实体对象 ID（跨线程安全，用于「在 X 模块打开」回查实体；UI 不直接消费）
    let originID: NSManagedObjectID

    init(id: UUID = UUID(),
         module: CalendarModule,
         date: Date,
         title: String,
         detail: String? = nil,
         relatedTopics: [String]? = nil,
         originID: NSManagedObjectID) {
        self.id = id
        self.module = module
        self.date = date
        self.title = title
        self.detail = detail
        self.relatedTopics = relatedTopics
        self.originID = originID
    }

    /// 按 id 判等（同一条原始记录即同一事件）
    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.id == rhs.id
    }
}
