//
//  ThoughtEditorCommitTests.swift
//  HoloTests
//
//  G1「保存可信」编辑器单笔事务提交（2026-10-04 体检整改）：
//  稳定 ID 幂等 / 无变化跳过 / 手动标签保护 / 清空落库 / 引用差异 / 整理状态回退 / 已删不复活。
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtEditorCommitTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext!
    private var repository: ThoughtRepository!

    override func setUpWithError() throws {
        let model = CoreDataTestSupport.sharedModel
        let store = NSPersistentContainer(name: "ThoughtEditorCommitTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        store.persistentStoreDescriptions = [description]
        var storeError: Error?
        store.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        container = store
        context = store.viewContext
        repository = ThoughtRepository(context: context)
        CoreDataTestSupport.retain(container, context, repository)
    }

    @discardableResult
    private func makeExistingThought(
        content: String,
        manualTags: [String] = [],
        inlineTags: [String] = []
    ) throws -> Thought {
        try repository.create(
            content: content, mood: nil,
            manualTags: manualTags, inlineTags: inlineTags,
            imageData: nil, richContentJSON: nil
        )
    }

    private func assignmentKeys(_ assignments: [ThoughtTagAssignment], source: ThoughtTagAssignment.Source) -> Set<String> {
        Set(assignments
            .filter { $0.source == source.rawValue }
            .compactMap { $0.tag.map { ThoughtTagNormalizer.key($0.name) } })
    }

    // MARK: - 稳定 ID 幂等（T04：不重复创建）

    func test_createCommit_isIdempotentByThoughtId() throws {
        let id = UUID()
        _ = try repository.commitEditorContent(thoughtId: id, content: "第一版", createIfMissing: true)
        _ = try repository.commitEditorContent(thoughtId: id, content: "第二版", createIfMissing: true)

        let all = try repository.fetchAll()
        XCTAssertEqual(all.filter { $0.id == id }.count, 1, "同 ID 重复提交不得产生重复记录")
        XCTAssertEqual(try repository.fetchById(id)?.content, "第二版")
    }

    // MARK: - 无变化跳过（T05：只打开不写库）

    func test_noChangeCommit_skipsWrite() throws {
        let thought = try makeExistingThought(content: "原文", inlineTags: ["旧标签"])
        let before = thought.updatedAt

        let receipt = try repository.commitEditorContent(
            thoughtId: thought.id,
            content: "原文",
            inlineTags: ["旧标签"],
            richContentJSON: .some(nil),
            references: [],
            createIfMissing: false
        )

        XCTAssertFalse(receipt.committed, "无变化提交必须走跳过分支")
        context.refresh(thought, mergeChanges: false)
        XCTAssertEqual(thought.updatedAt, before, "无变化提交不得刷新 updatedAt")
    }

    func test_changedContent_stillCommits() throws {
        let thought = try makeExistingThought(content: "原文")
        let receipt = try repository.commitEditorContent(
            thoughtId: thought.id, content: "新文", createIfMissing: false)
        XCTAssertTrue(receipt.committed)
        XCTAssertEqual(try repository.fetchById(thought.id)?.content, "新文")
    }

    // MARK: - 手动标签保护（T06）

    func test_manualTag_survivesInlineEdit() throws {
        let thought = try makeExistingThought(content: "正文没有标签", manualTags: ["手动标签"])

        _ = try repository.commitEditorContent(
            thoughtId: thought.id,
            content: "新正文 #行内标签",
            inlineTags: ["行内标签"],
            createIfMissing: false
        )

        let assignments = try repository.fetchAssignments(thoughtId: thought.id)
        let manualKeys = assignmentKeys(assignments, source: .manual)
        XCTAssertEqual(manualKeys, [ThoughtTagNormalizer.key("手动标签")], "正文里没有的手动标签不得被编辑清除")
        XCTAssertEqual(
            assignmentKeys(assignments, source: .inline),
            [ThoughtTagNormalizer.key("行内标签")]
        )
    }

    func test_removedInlineTag_onlyTouchesInline() throws {
        let thought = try makeExistingThought(
            content: "带 #旧标签 的正文",
            manualTags: ["手动标签"],
            inlineTags: ["旧标签"]
        )

        _ = try repository.commitEditorContent(
            thoughtId: thought.id,
            content: "正文不再有标签",
            inlineTags: [],
            createIfMissing: false
        )

        let assignments = try repository.fetchAssignments(thoughtId: thought.id)
        XCTAssertTrue(assignmentKeys(assignments, source: .inline).isEmpty, "正文中移除的 inline 标签应删除")
        XCTAssertEqual(
            assignmentKeys(assignments, source: .manual),
            [ThoughtTagNormalizer.key("手动标签")],
            "manual 来源不受 inline 差异影响"
        )
    }

    func test_manualCoveredTag_skipsDuplicateInlineAssignment() throws {
        // 手动标签与行内同名：inline 差异不重复建 assignment（manual 优先口径与 create 一致）
        let thought = try makeExistingThought(content: "正文", manualTags: ["同名标签"])
        _ = try repository.commitEditorContent(
            thoughtId: thought.id,
            content: "正文 #同名标签",
            inlineTags: ["同名标签"],
            createIfMissing: false
        )
        let assignments = try repository.fetchAssignments(thoughtId: thought.id)
        XCTAssertEqual(assignmentKeys(assignments, source: .inline).count, 0, "manual 已覆盖的标签不得再建 inline 身份")
        XCTAssertEqual(assignmentKeys(assignments, source: .manual).count, 1)
    }

    // MARK: - 清空落库（T07）

    func test_clearContent_savesEmptyAndKeepsManualTags() throws {
        let thought = try makeExistingThought(
            content: "有内容 #行内",
            manualTags: ["手动"],
            inlineTags: ["行内"]
        )

        _ = try repository.commitEditorContent(
            thoughtId: thought.id,
            content: "",
            inlineTags: [],
            richContentJSON: .some(nil),
            references: [],
            createIfMissing: false
        )

        let reloaded = try XCTUnwrap(try repository.fetchById(thought.id))
        XCTAssertEqual(reloaded.content, "", "清空是合法编辑，必须落库为空正文")
        let assignments = try repository.fetchAssignments(thoughtId: thought.id)
        XCTAssertEqual(
            assignmentKeys(assignments, source: .manual),
            [ThoughtTagNormalizer.key("手动")],
            "清空正文后手动标签仍保留"
        )
        XCTAssertTrue(assignmentKeys(assignments, source: .inline).isEmpty)
    }

    // MARK: - 引用同一事务与差异（T03/T04）

    func test_referenceDiff_rebuiltOnlyOnChange() throws {
        let targetA = try makeExistingThought(content: "目标A")
        let targetB = try makeExistingThought(content: "目标B")
        let source = try makeExistingThought(content: "引用方")
        let refA = [ThoughtRepository.ReferenceSnapshot(targetId: targetA.id, displayText: "目标A", snapshot: "目标A")]

        let first = try repository.commitEditorContent(
            thoughtId: source.id, content: "引用方 @目标A", inlineTags: [],
            references: refA, createIfMissing: false)
        XCTAssertTrue(first.committed)

        let unchanged = try repository.commitEditorContent(
            thoughtId: source.id, content: "引用方 @目标A", inlineTags: [],
            references: refA, createIfMissing: false)
        XCTAssertFalse(unchanged.committed, "引用完全一致时不得删除重建")

        let refB = [ThoughtRepository.ReferenceSnapshot(targetId: targetB.id, displayText: "目标B", snapshot: "目标B")]
        _ = try repository.commitEditorContent(
            thoughtId: source.id, content: "引用方 @目标B", inlineTags: [],
            references: refB, createIfMissing: false)

        let references = try repository.getReferences(for: source.id)
        XCTAssertEqual(references.map(\.id), [targetB.id], "引用变更后旧关系清除、新关系建立")
    }

    func test_referenceClear_commitsEmptyReferenceList() throws {
        let target = try makeExistingThought(content: "目标")
        let source = try makeExistingThought(content: "引用方")
        _ = try repository.commitEditorContent(
            thoughtId: source.id, content: "引用方",
            inlineTags: [],
            references: [ThoughtRepository.ReferenceSnapshot(targetId: target.id, displayText: "目标", snapshot: "目标")],
            createIfMissing: false)

        _ = try repository.commitEditorContent(
            thoughtId: source.id, content: "引用方", inlineTags: [],
            references: [], createIfMissing: false)

        XCTAssertTrue(try repository.getReferences(for: source.id).isEmpty, "空引用列表表示清空全部引用")
    }

    // MARK: - 整理状态回退（V2 §5.5 口径）

    func test_contentChange_flipsOrganizedStatusToPending() throws {
        let thought = try makeExistingThought(content: "旧内容")
        thought.organizedStatus = "organized"
        thought.indexCompletedHash = ThoughtTagIndexProjection.textHash("旧内容")
        try context.save()

        _ = try repository.commitEditorContent(
            thoughtId: thought.id, content: "新内容", createIfMissing: false)

        XCTAssertEqual(
            try repository.fetchById(thought.id)?.organizedStatus, "pending",
            "正文实变后应回到 pending 等待重排"
        )
    }

    // MARK: - 已删除想法不复活（createIfMissing=false）

    func test_missingThoughtWithoutCreate_throwsNotFound() throws {
        XCTAssertThrowsError(
            try repository.commitEditorContent(thoughtId: UUID(), content: "x", createIfMissing: false)
        )
    }
}
