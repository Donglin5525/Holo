//
//  NewUserActivationStateTests.swift
//  HoloTests
//
//  新用户激活判定单测：全库无记录口径（交易/任务/想法/习惯，排除回收站软删）、
//  人生第一笔交易判定。支撑首页第一步行动卡显隐与首次记录庆祝触发。
//

import XCTest
import CoreData
@testable import Holo

final class NewUserActivationStateTests: XCTestCase {

    private func makeContext() throws -> (NSManagedObjectContext, NSPersistentContainer) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "NewUserActivationTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        CoreDataTestSupport.retain(container, container.viewContext)
        return (container.viewContext, container)
    }

    private func insert(_ entityName: String, in ctx: NSManagedObjectContext, softDeleted: Bool = false) {
        let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: ctx)
        object.setValue(UUID(), forKey: "id")
        if softDeleted {
            object.setValue(Date(), forKey: "deletedAt")
        }
    }

    func testEmptyStoreHasNoRecord() throws {
        let (ctx, _) = try makeContext()
        XCTAssertFalse(NewUserActivationState.hasAnyRecord(context: ctx))
        XCTAssertFalse(NewUserActivationState.isFirstTransactionEver(context: ctx))
    }

    func testSingleTransactionIsFirstEver() throws {
        let (ctx, _) = try makeContext()
        insert("Transaction", in: ctx)
        XCTAssertTrue(NewUserActivationState.hasAnyRecord(context: ctx))
        XCTAssertTrue(NewUserActivationState.isFirstTransactionEver(context: ctx))
    }

    func testSecondTransactionIsNoLongerFirst() throws {
        let (ctx, _) = try makeContext()
        insert("Transaction", in: ctx)
        insert("Transaction", in: ctx)
        XCTAssertTrue(NewUserActivationState.hasAnyRecord(context: ctx))
        XCTAssertFalse(NewUserActivationState.isFirstTransactionEver(context: ctx))
    }

    func testSoftDeletedTransactionDoesNotCount() throws {
        let (ctx, _) = try makeContext()
        insert("Transaction", in: ctx, softDeleted: true)
        XCTAssertFalse(NewUserActivationState.hasAnyRecord(context: ctx))
        XCTAssertFalse(NewUserActivationState.isFirstTransactionEver(context: ctx))
    }

    func testNonFinanceRecordAlsoActivates() throws {
        let (ctx, _) = try makeContext()
        for entity in ["TodoTask", "Thought", "Habit"] {
            insert(entity, in: ctx)
            XCTAssertTrue(NewUserActivationState.hasAnyRecord(context: ctx), "\(entity) 应视为已有记录")
            ctx.reset()
        }
        XCTAssertFalse(NewUserActivationState.isFirstTransactionEver(context: try makeContext().0))
    }
}
