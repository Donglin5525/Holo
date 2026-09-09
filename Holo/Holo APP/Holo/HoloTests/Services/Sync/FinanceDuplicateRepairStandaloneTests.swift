import CoreData
import Foundation

@main
struct FinanceDuplicateRepairStandaloneTests {
    static func check(_ condition: Bool) { precondition(condition) }

    static func main() throws {
        try flatEntityScenario()
        try relationalScenario()
        print("PASS: 精确副本、正常同额消费、内容冲突、删除冲突、同步身份延迟、未保存编辑、重复执行、账户副本合并、挂副本账单改挂、关系冲突")
    }

    // MARK: - 场景一：无关系的单表副本

    static func flatEntityScenario() throws {
        let entity = NSEntityDescription()
        entity.name = "Transaction"
        entity.managedObjectClassName = "NSManagedObject"
        for (name, type) in [("id", NSAttributeType.UUIDAttributeType), ("amount", .decimalAttributeType), ("note", .stringAttributeType), ("updatedAt", .dateAttributeType), ("deletedAt", .dateAttributeType)] {
            let attr = NSAttributeDescription()
            attr.name = name; attr.attributeType = type; attr.isOptional = true
            entity.properties.append(attr)
        }
        let model = NSManagedObjectModel(); model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var names: [NSManagedObjectID: String] = [:]
        func add(_ id: UUID, _ amount: Int, _ name: String, updated: Date = Date(timeIntervalSince1970: 1), deleted: Bool = false) throws -> NSManagedObject {
            let row = NSManagedObject(entity: entity, insertInto: context)
            row.setValue(id, forKey: "id"); row.setValue(NSDecimalNumber(value: amount), forKey: "amount")
            row.setValue("同额消费", forKey: "note"); row.setValue(updated, forKey: "updatedAt")
            if deleted { row.setValue(updated, forKey: "deletedAt") }
            try context.obtainPermanentIDs(for: [row]); names[row.objectID] = name
            return row
        }
        let id = UUID()
        let latest = Date(timeIntervalSince1970: 99)
        let survivor = try add(id, 999, "A")
        _ = try add(id, 999, "B", updated: latest)
        _ = try add(UUID(), 999, "C") // 同额但不同 ID，必须保留。
        let conflict = UUID()
        _ = try add(conflict, 40, "D"); _ = try add(conflict, 41, "E")
        let deletion = UUID()
        _ = try add(deletion, 50, "F"); _ = try add(deletion, 50, "G", deleted: true)
        let waiting = UUID()
        _ = try add(waiting, 60, "H")
        let unknown = try add(waiting, 60, "I"); names.removeValue(forKey: unknown.objectID)
        // 未保存编辑不能被修复顺带提交。
        try check(FinanceDuplicateRepair.repair(in: context, recordName: { names[$0] }).removed == 0)
        try context.save()
        let result = try FinanceDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(result.removed == 1 && result.conflictingGroups == 2 && result.deferredGroups == 1)
        precondition(survivor.value(forKey: "updatedAt") as? Date == latest)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Transaction")) == 8)
        try check(FinanceDuplicateRepair.repair(in: context, recordName: { names[$0] }).removed == 0)
        names[unknown.objectID] = "I"
        try check(FinanceDuplicateRepair.repair(in: context, recordName: { names[$0] }).removed == 1)
    }

    // MARK: - 场景二：账户副本合并 + 挂副本账单改挂

    /// 重复导入的真实形态：账单原件指向账户原件，账单副本指向账户副本。
    /// 关系必须按目标 id 判等；删除账户副本前，引用它的普通账单（本身不重复）要改挂保留项。
    static func relationalScenario() throws {
        let model = makeRelationalModel()
        guard let accountEntity = model.entities.first(where: { $0.name == "Account" }),
              let transactionEntity = model.entities.first(where: { $0.name == "Transaction" }) else {
            fatalError("关系型测试模型缺实体")
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var names: [NSManagedObjectID: String] = [:]
        @discardableResult
        func insert(_ entity: NSEntityDescription, _ name: String, _ values: [String: Any]) throws -> NSManagedObject {
            let row = NSManagedObject(entity: entity, insertInto: context)
            for (key, value) in values { row.setValue(value, forKey: key) }
            try context.obtainPermanentIDs(for: [row]); names[row.objectID] = name
            return row
        }
        let accountId = UUID()
        let txnId = UUID()
        let accountA = try insert(accountEntity, "acct-a", ["id": accountId, "name": "现金", "updatedAt": Date(timeIntervalSince1970: 1)])
        let accountB = try insert(accountEntity, "acct-b", ["id": accountId, "name": "现金", "updatedAt": Date(timeIntervalSince1970: 2)])
        let txnA = try insert(transactionEntity, "txn-a", ["id": txnId, "amount": NSDecimalNumber(value: 10), "updatedAt": Date(timeIntervalSince1970: 1), "account": accountA])
        _ = try insert(transactionEntity, "txn-b", ["id": txnId, "amount": NSDecimalNumber(value: 10), "updatedAt": Date(timeIntervalSince1970: 2), "account": accountB])
        // 本身不重复、却挂在将被删除的账户副本上的普通账单：必须改挂，不能跟副本陪葬。
        let bystander = try insert(transactionEntity, "txn-c", ["id": UUID(), "amount": NSDecimalNumber(value: 5), "updatedAt": Date(timeIntervalSince1970: 3), "account": accountB])
        let conflictId = UUID()
        _ = try insert(transactionEntity, "txn-d", ["id": conflictId, "amount": NSDecimalNumber(value: 7), "updatedAt": Date(timeIntervalSince1970: 1), "account": accountA])
        _ = try insert(transactionEntity, "txn-e", ["id": conflictId, "amount": NSDecimalNumber(value: 8), "updatedAt": Date(timeIntervalSince1970: 1), "account": accountA])
        try context.save()

        let result = try FinanceDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(result.removed == 2 && result.remapped == 2 && result.conflictingGroups == 1 && result.deferredGroups == 0)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Account")) == 1)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Transaction")) == 4)
        // 记录名排序决定保留项："acct-a" 与 "txn-a" 存活。
        let survivingAccount = try fetchSingle(context, entityName: "Account")
        let survivingTxn = try fetchSingle(context, entityName: "Transaction", id: txnId)
        precondition(accountA.objectID == survivingAccount.objectID)
        precondition(txnA.objectID == survivingTxn.objectID)
        // 改挂后的账单都指向保留的账户。
        precondition((bystander.value(forKey: "account") as? NSManagedObject)?.objectID == accountA.objectID)
        precondition((txnA.value(forKey: "account") as? NSManagedObject)?.objectID == accountA.objectID)
        // 再跑一遍必须无动作（幂等）。
        let again = try FinanceDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(again.removed == 0 && again.remapped == 0 && again.conflictingGroups == 1)
    }

    static func makeRelationalModel() -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true
            return a
        }
        let account = NSEntityDescription()
        account.name = "Account"; account.managedObjectClassName = "NSManagedObject"
        let transaction = NSEntityDescription()
        transaction.name = "Transaction"; transaction.managedObjectClassName = "NSManagedObject"
        transaction.properties = [attr("id", .UUIDAttributeType), attr("amount", .decimalAttributeType), attr("updatedAt", .dateAttributeType)]
        account.properties = [attr("id", .UUIDAttributeType), attr("name", .stringAttributeType), attr("updatedAt", .dateAttributeType)]

        let txnAccount = NSRelationshipDescription()
        txnAccount.name = "account"; txnAccount.destinationEntity = account
        txnAccount.minCount = 0; txnAccount.maxCount = 1; txnAccount.isOptional = true
        txnAccount.deleteRule = .nullifyDeleteRule
        let accountTxns = NSRelationshipDescription()
        accountTxns.name = "transactions"; accountTxns.destinationEntity = transaction
        accountTxns.minCount = 0; accountTxns.maxCount = 0; accountTxns.isOptional = true
        accountTxns.deleteRule = .nullifyDeleteRule
        txnAccount.inverseRelationship = accountTxns
        accountTxns.inverseRelationship = txnAccount
        transaction.properties = transaction.properties + [txnAccount]
        account.properties = account.properties + [accountTxns]

        let model = NSManagedObjectModel()
        model.entities = [account, transaction]
        return model
    }

    static func fetchSingle(_ context: NSManagedObjectContext, entityName: String, id: UUID? = nil) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        if let id { request.predicate = NSPredicate(format: "id == %@", id as CVarArg) }
        guard let row = try context.fetch(request).first else { fatalError("场景二断言前置失败：\(entityName) 无行") }
        return row
    }
}
