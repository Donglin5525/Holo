import CoreData
import XCTest
@testable import Holo

enum CoreDataTestSupport {
    /// 全量 XCTest 在同一进程运行时复用同一份模型，避免 Core Data 为相同
    /// NSManagedObject 子类注册多份实体描述后产生全局歧义。
    static let sharedModel = CoreDataStack.shared.createDataModel()

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
