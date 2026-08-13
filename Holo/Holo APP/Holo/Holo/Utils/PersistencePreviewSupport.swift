//
//  PersistencePreviewSupport.swift
//  Holo
//
//  SwiftUI Preview 专用的内存型 Core Data 上下文。
//  使用 NSInMemoryStoreType，数据不落盘，Preview 结束即销毁。
//  仅在 DEBUG 下编译。
//

#if DEBUG
import CoreData

enum PersistencePreviewSupport {
    /// 内存型预览上下文（单例，懒加载）
    static var previewContext: NSManagedObjectContext {
        if let existing = _storedContext {
            return existing
        }
        let container = NSPersistentContainer(
            name: "HoloPreviewModel",
            managedObjectModel: CoreDataStack.shared.persistentContainer.managedObjectModel
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error {
                print("Preview context 加载失败：\(error)")
            }
        }
        let context = container.viewContext
        _storedContext = context
        return context
    }

    nonisolated(unsafe) private static var _storedContext: NSManagedObjectContext?
}
#endif
