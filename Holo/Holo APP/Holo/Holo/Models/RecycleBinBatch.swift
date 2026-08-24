//
//  RecycleBinBatch.swift
//  Holo
//
//  回收站「清空事件」批次实体
//
//  每次模块清空 / 清空所有数据创建一条批次记录，业务实体的 deletedBatchId 指向它。
//  回收站 UI 以批次为展示单元（按删除事件分组，而非平铺条目）。
//  随主库 CloudKit 同步——A 设备清空，B 设备回收站同样可见可恢复。
//  批次内全部条目物理清除后，批次记录自身一并删除。
//

import Foundation
import CoreData

@objc(RecycleBinBatch)
final class RecycleBinBatch: NSManagedObject {
    /// 批次唯一标识（对应各业务实体的 deletedBatchId）
    @NSManaged var id: UUID
    /// 清空执行时刻
    @NSManaged var createdAt: Date
    /// 批次范围：module = 单模块清空；global = 清空所有数据
    @NSManaged var scope: String
    /// 涉及模块码，逗号分隔（RecycleBinModule.rawValue，见 RecycleBinService）
    @NSManaged var modules: String
    /// 展示摘要（如「清空财务数据 · 仅交易」/「清空所有数据」）
    @NSManaged var summary: String?

    var moduleList: [String] {
        modules.split(separator: ",").map(String.init)
    }
}
