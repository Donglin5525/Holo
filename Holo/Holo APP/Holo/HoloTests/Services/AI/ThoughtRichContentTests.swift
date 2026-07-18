//
//  ThoughtRichContentTests.swift
//  HoloTests
//
//  观点结构化内容测试：路径子树重命名、引用关系重建、候选查询
//  使用内存 Core Data 隔离
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtRichContentTests: XCTestCase {

    // MARK: - In-Memory Core Data

    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "RichContentTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (ThoughtRepository(context: ctx), ctx)
    }

    @discardableResult
    private func makeThought(repo: ThoughtRepository, content: String) throws -> Thought {
        try repo.create(content: content)
    }

    @discardableResult
    private func makeTag(in ctx: NSManagedObjectContext, name: String) throws -> ThoughtTag {
        let tag = ThoughtTag(context: ctx)
        tag.id = UUID()
        tag.name = name
        tag.usageCount = 1
        try ctx.save()
        return tag
    }

    private func allTagNames(in ctx: NSManagedObjectContext) throws -> [String] {
        try ctx.fetch(ThoughtTag.fetchRequest()).map(\.name)
    }

    // MARK: - 路径子树重命名

    func test_路径重命名_整棵子树同步改名() async throws {
        let (repo, ctx) = try makeRepo()
        try makeTag(in: ctx, name: "工作")
        try makeTag(in: ctx, name: "工作/Holo")
        try makeTag(in: ctx, name: "工作/Holo/编辑器")
        try makeTag(in: ctx, name: "生活")

        let outcome = try repo.renameTagPathPrefix(from: "工作", to: "项目")

        XCTAssertEqual(outcome, .renamed)
        let names = try allTagNames(in: ctx)
        XCTAssertTrue(names.contains("项目"))
        XCTAssertTrue(names.contains("项目/Holo"))
        XCTAssertTrue(names.contains("项目/Holo/编辑器"))
        XCTAssertTrue(names.contains("生活"), "非子树标签不受影响")
        XCTAssertFalse(names.contains("工作/Holo"))
    }

    func test_路径重命名_中间路径只影响其子树() async throws {
        let (repo, ctx) = try makeRepo()
        try makeTag(in: ctx, name: "工作")
        try makeTag(in: ctx, name: "工作/Holo")
        try makeTag(in: ctx, name: "工作/Holo/编辑器")

        _ = try repo.renameTagPathPrefix(from: "工作/Holo", to: "工作/HoloApp")

        let names = try allTagNames(in: ctx)
        XCTAssertTrue(names.contains("工作"), "父级不受影响")
        XCTAssertTrue(names.contains("工作/HoloApp"))
        XCTAssertTrue(names.contains("工作/HoloApp/编辑器"))
    }

    func test_路径重命名_目标已存在时合并() async throws {
        let (repo, ctx) = try makeRepo()
        try makeTag(in: ctx, name: "工作")
        try makeTag(in: ctx, name: "项目")
        try makeTag(in: ctx, name: "工作/Holo")

        let outcome = try repo.renameTagPathPrefix(from: "工作", to: "项目")

        XCTAssertEqual(outcome, .merged, "根路径目标已存在应合并")
        let names = try allTagNames(in: ctx)
        XCTAssertTrue(names.contains("项目"))
        XCTAssertTrue(names.contains("项目/Holo"))
        XCTAssertFalse(names.contains("工作"))
    }

    func test_路径重命名_源不存在抛错() async throws {
        let (repo, _) = try makeRepo()
        XCTAssertThrowsError(try repo.renameTagPathPrefix(from: "不存在", to: "目标"))
    }

    // MARK: - 引用关系重建

    func test_重建引用_写入快照并替换旧关系() async throws {
        let (repo, _) = try makeRepo()
        let source = try makeThought(repo: repo, content: "来源想法")
        let target = try makeThought(repo: repo, content: "目标想法")
        let stale = try makeThought(repo: repo, content: "过时目标")

        // 先建立一条旧关系
        try repo.replaceReferences(thoughtId: source.id, references: [
            .init(targetId: stale.id, displayText: "过时目标", snapshot: "旧快照")
        ])

        // 全量重建：旧关系被替换，快照写入
        try repo.replaceReferences(thoughtId: source.id, references: [
            .init(targetId: target.id, displayText: "目标想法", snapshot: "目标摘要")
        ])

        let references = try repo.getReferences(for: source.id)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.id, target.id)

        let referenceRows = (source.references as? Set<ThoughtReference>) ?? []
        XCTAssertEqual(referenceRows.first?.displayText, "目标想法")
        XCTAssertEqual(referenceRows.first?.snapshot, "目标摘要")
    }

    func test_重建引用_清空传空数组() async throws {
        let (repo, _) = try makeRepo()
        let source = try makeThought(repo: repo, content: "来源")
        let target = try makeThought(repo: repo, content: "目标")

        try repo.replaceReferences(thoughtId: source.id, references: [
            .init(targetId: target.id, displayText: "目标", snapshot: "")
        ])
        try repo.replaceReferences(thoughtId: source.id, references: [])

        XCTAssertTrue(try repo.getReferences(for: source.id).isEmpty)
    }

    func test_重建引用_目标不存在时跳过不崩溃() async throws {
        let (repo, _) = try makeRepo()
        let source = try makeThought(repo: repo, content: "来源")

        try repo.replaceReferences(thoughtId: source.id, references: [
            .init(targetId: UUID(), displayText: "幽灵", snapshot: "快照")
        ])

        XCTAssertTrue(try repo.getReferences(for: source.id).isEmpty)
    }

    // MARK: - 候选查询

    func test_标签候选_空关键词按最近使用排序() async throws {
        let (repo, ctx) = try makeRepo()
        let old = try makeTag(in: ctx, name: "旧标签")
        old.lastUsedAt = Date(timeIntervalSinceNow: -3600)
        let recent = try makeTag(in: ctx, name: "新标签")
        recent.lastUsedAt = Date()

        let candidates = try repo.fetchTagCandidates(query: "")

        XCTAssertEqual(candidates.first?.name, "新标签")
    }

    func test_标签候选_路径前缀优先于包含() async throws {
        let (repo, ctx) = try makeRepo()
        try makeTag(in: ctx, name: "工具箱")
        try makeTag(in: ctx, name: "工作/Holo")

        let candidates = try repo.fetchTagCandidates(query: "工作")

        XCTAssertEqual(candidates.first?.name, "工作/Holo", "路径前缀匹配应排在包含匹配前")
    }

    func test_引用候选_排除当前编辑想法() async throws {
        let (repo, _) = try makeRepo()
        let current = try makeThought(repo: repo, content: "正在编辑")
        try makeThought(repo: repo, content: "其他想法")

        let candidates = try repo.fetchReferenceCandidates(query: "", excludingThoughtId: current.id)

        XCTAssertFalse(candidates.contains { $0.id == current.id })
        XCTAssertEqual(candidates.count, 1)
    }

    func test_引用候选_关键词匹配正文() async throws {
        let (repo, _) = try makeRepo()
        try makeThought(repo: repo, content: "关于标签体系的思考")
        try makeThought(repo: repo, content: "今天天气不错")

        let candidates = try repo.fetchReferenceCandidates(query: "标签", excludingThoughtId: nil)

        XCTAssertEqual(candidates.count, 1)
    }

    // MARK: - 保存派生字段

    func test_创建想法_派生firstLine() async throws {
        let (repo, _) = try makeRepo()
        let thought = try repo.create(content: "\n第一行内容\n第二行")

        XCTAssertEqual(thought.firstLine, "第一行内容")
    }

    func test_创建想法_写入richContentJSON() async throws {
        let (repo, _) = try makeRepo()
        let nodes: [HoloContentNode] = [.text(value: "内容 ")]
        let json = try RichContentSerializer.jsonString(from: nodes)

        let thought = try repo.create(content: "内容 ", richContentJSON: json)

        XCTAssertEqual(thought.richContentJSON, json)
    }
}
