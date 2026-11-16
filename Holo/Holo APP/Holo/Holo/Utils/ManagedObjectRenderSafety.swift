//
//  ManagedObjectRenderSafety.swift
//  Holo
//
//  ForEach 数据源安全过滤（2026-11-16 主题删除真机崩溃根治件）
//
//  背景：页面用 @State 数组直接持有 NSManagedObject 做 ForEach 数据源，
//  删除落库（context.delete + save）后到页面 reload 之间存在时序窗口，
//  body 重算时 ForEach 会读死对象的 \.id（@NSManaged 非可选 UUID 底层为 nil）
//  → UUID._unconditionallyBridgeFromObjectiveC 直接崩溃。
//  实锤：Holo-2026-11-16-215553.ips（1.1.9(57) 删除想法主题），
//  堆栈 = ForEachState.update → key path getter for Topic.id → UUID 桥接。
//
//  根治：所有渲染托管对象数组的 ForEach 一律经 renderable 过滤，
//  已删除/已失效对象在任何时序下都进不了渲染管线。
//

import CoreData

extension NSManagedObject {
    /// 对象是否仍可安全渲染：已删除或已从 context 失效则不可。
    /// 仅读 isDeleted / managedObjectContext（NSManagedObject 自身属性，
    /// 不触发数据 fault 加载），对已删对象调用本身安全。
    var isRenderable: Bool { !isDeleted && managedObjectContext != nil }
}

extension Array where Element: NSManagedObject {
    /// ForEach 数据源过滤器：剔除已删除/已失效的托管对象
    var renderable: [Element] { filter(\.isRenderable) }
}
