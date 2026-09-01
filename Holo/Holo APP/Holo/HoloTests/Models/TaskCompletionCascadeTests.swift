//
//  TaskCompletionCascadeTests.swift
//  HoloTests
//
//  主任务完成 ⇔ 子任务全完成的级联不变式单测
//

import XCTest
import CoreData
@testable import Holo

final class TaskCompletionCascadeTests: XCTestCase {

    private func makeRepo() throws -> (TodoRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "CompletionCascadeTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = TodoRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    /// 造一个带 3 条子任务（第 1 条已勾、其余未勾）的任务
    private func makeTaskWithChecklist(_ repo: TodoRepository) throws -> TodoTask {
        let task = try repo.createTask(title: "整理房间")
        _ = try repo.addCheckItem(title: "桌面", to: task, order: 0)
        _ = try repo.addCheckItem(title: "地面", to: task, order: 1)
        _ = try repo.addCheckItem(title: "衣柜", to: task, order: 2)
        let first = (task.checkItems?.allObjects as? [CheckItem] ?? [])
            .sorted { $0.order < $1.order }.first
        if let first { try repo.toggleCheckItem(first) }
        return task
    }

    private func checkItems(of task: TodoTask) -> [CheckItem] {
        (task.checkItems?.allObjects as? [CheckItem] ?? []).sorted { $0.order < $1.order }
    }

    // MARK: - 级联勾选

    func test_完成主任务_未勾子任务全部级联勾上() throws {
        let (repo, _) = try makeRepo()
        let task = try makeTaskWithChecklist(repo)

        _ = try repo.toggleTaskCompletion(task)

        XCTAssertTrue(task.completed)
        XCTAssertEqual(checkItems(of: task).count, 3)
        XCTAssertTrue(checkItems(of: task).allSatisfy(\.isChecked), "主任务完成后子任务应全部勾上")
    }

    func test_取消完成_子任务勾选进度保留() throws {
        let (repo, _) = try makeRepo()
        let task = try makeTaskWithChecklist(repo)
        _ = try repo.toggleTaskCompletion(task)

        _ = try repo.toggleTaskCompletion(task)

        XCTAssertFalse(task.completed)
        XCTAssertTrue(checkItems(of: task).allSatisfy(\.isChecked), "取消完成后子任务进度不应被清掉")
    }

    func test_completeTask入口_同样级联勾选() throws {
        let (repo, _) = try makeRepo()
        let task = try makeTaskWithChecklist(repo)

        try repo.completeTask(task)

        XCTAssertTrue(task.completed)
        XCTAssertTrue(checkItems(of: task).allSatisfy(\.isChecked))
    }

    func test_无子任务任务_完成不受级联影响() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(title: "纯待办")

        _ = try repo.toggleTaskCompletion(task)

        XCTAssertTrue(task.completed)
        XCTAssertTrue(checkItems(of: task).isEmpty)
    }
}
