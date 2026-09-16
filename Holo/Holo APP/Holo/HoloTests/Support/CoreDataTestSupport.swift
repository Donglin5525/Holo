import CoreData
import XCTest
@testable import Holo

enum CoreDataTestSupport {
    /// 全量 XCTest 在同一进程运行时复用同一份模型，避免 Core Data 为相同
    /// NSManagedObject 子类注册多份实体描述后产生全局歧义。
    static let sharedModel = CoreDataStack.shared.createDataModel()

    /// 进程唯一测试容器（in-memory）。需要独立内存栈的 XCTest 一律从这里取
    /// viewContext，禁止各自 NSPersistentContainer + loadPersistentStores——
    /// 同一 sharedModel 反复 load 跨进程阈值后，NSManagedObject 子类→实体映射
    /// 会发生全局歧义（系统层「模型不兼容 134020」），fetch 失败被 try? 吞成
    /// nil，表现为「刚建的记录查不到」类假失败。
    /// 2026-09-16 R4-1 实证：FinanceReconciliationTests × ChatMessageRepository-
    /// CacheRecoveryTests → ReceiptBookingKernelTests 三测必挂。收编为单容器后
    /// 新增测试类不再增加 load 次数；存量各自建容器的类按域渐进迁入。
    static let sharedTestContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "HoloTests", managedObjectModel: sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { preconditionFailure("测试容器加载失败: \(error)") }
        }
        return container
    }()

    /// 清空指定实体（in-memory store 不支持 batch delete，逐条 fetch+delete）。
    /// 共享容器下每个用例的 setUp 必须清掉自己要用的实体，杜绝用例间串扰。
    static func clearEntities(_ context: NSManagedObjectContext, _ entityNames: [String]) throws {
        for entityName in entityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in try context.fetch(request) {
                context.delete(object)
            }
        }
        try context.save()
    }

    /// hosted XCTest + iOS 26.3 Simulator 在释放部分 MainActor/Core Data 组合对象时
    /// 存在系统层重复释放。仅在测试进程内延长生命周期，生产对象不受影响。
    private static var retainedObjects: [AnyObject] = []

    static func retain(_ objects: AnyObject...) {
        retainedObjects.append(contentsOf: objects)
    }
}

extension NSManagedObjectContext {
    /// 从当前 context 所属模型按实体名创建对象，避免多套内存模型下的全局实体歧义。
    func insertTestObject<Object: NSManagedObject>(_ type: Object.Type) -> Object {
        let entityName = String(describing: type)
        guard let object = NSEntityDescription.insertNewObject(
            forEntityName: entityName,
            into: self
        ) as? Object else {
            preconditionFailure("测试模型缺少实体：\(entityName)")
        }
        return object
    }
}
