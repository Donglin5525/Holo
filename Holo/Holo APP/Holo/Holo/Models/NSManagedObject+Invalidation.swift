import CoreData

extension NSManagedObject {
    /// 对象是否已死：被 delete 且 save 后（或所在上下文已注销）。
    ///
    /// 已死对象的任何持久属性访问都会抛 "could not fulfill a fault" 直接闪退，
    /// 而删除操作的完成广播（`xxxDataDidChange`）会唤醒屏幕上还挂着的行/详情视图做异步刷新——
    /// 这些刷新入口必须先用本属性守卫，且守卫分支不得写入 `@State`（写入会重算 body，
    /// body 读已死属性同样闪退），直接返回让视图随数据源重取自然退场。
    ///
    /// 本属性只访问元数据（不触发 faulting），对已死对象调用是安全的。
    var isInvalidated: Bool {
        managedObjectContext == nil || isDeleted
    }
}
