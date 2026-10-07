//
//  ThoughtEditorRecoveryTests.swift
//  HoloTests
//
//  G1「保存可信」编辑器本机恢复日志（2026-10-04 体检整改）：
//  记录读写 / 孤儿草稿 / 按 thoughtId 检索 / staged 文件生命周期 / 损坏容错 / 孤儿对账。
//

import XCTest
@testable import Holo

final class ThoughtEditorRecoveryTests: XCTestCase {

    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThoughtEditorRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeStore() -> ThoughtEditorRecoveryStore {
        ThoughtEditorRecoveryStore(rootDirectory: rootURL)
    }

    private func draftsDirectory() -> URL {
        rootURL.appendingPathComponent("drafts", isDirectory: true)
    }

    private func stagedDirectory() -> URL {
        rootURL.appendingPathComponent("staged", isDirectory: true)
    }

    private func makeDraft(
        thoughtId: UUID? = nil,
        content: String,
        stagedFiles: [String] = []
    ) -> ThoughtEditorRecoveryDraft {
        ThoughtEditorRecoveryDraft(
            sessionId: UUID(),
            thoughtId: thoughtId,
            content: content,
            richContentJSON: nil,
            stagedImageFiles: stagedFiles,
            updatedAt: Date()
        )
    }

    // MARK: - 读写回环

    func test_draftRoundTrip_orphanListing() async throws {
        let store = makeStore()
        let draft = makeDraft(content: "未保存的草稿")
        await store.save(draft)

        let orphans = await store.orphanDrafts()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.sessionId, draft.sessionId)
        XCTAssertEqual(orphans.first?.content, "未保存的草稿")
    }

    func test_draftsFilterByThoughtId() async throws {
        let store = makeStore()
        let thoughtId = UUID()
        let linked = makeDraft(thoughtId: thoughtId, content: "已有想法的未提交修改")
        let orphan = makeDraft(content: "孤儿草稿")
        await store.save(linked)
        await store.save(orphan)

        let linkedDrafts = await store.drafts(forThoughtId: thoughtId)
        XCTAssertEqual(linkedDrafts.count, 1)
        XCTAssertEqual(linkedDrafts.first?.content, "已有想法的未提交修改")

        let orphans = await store.orphanDrafts()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.content, "孤儿草稿")
    }

    func test_latestDraftSortsFirst() async throws {
        let store = makeStore()
        let thoughtId = UUID()
        var older = makeDraft(thoughtId: thoughtId, content: "旧")
        older.updatedAt = Date().addingTimeInterval(-60)
        let newer = makeDraft(thoughtId: thoughtId, content: "新")
        await store.save(older)
        await store.save(newer)

        let drafts = await store.drafts(forThoughtId: thoughtId)
        XCTAssertEqual(drafts.first?.content, "新")
    }

    // MARK: - 清理语义

    func test_clearRemovesRecordButKeepsStagedFile() async throws {
        let store = makeStore()
        await store.writeStagedImage(Data([1, 2, 3]), fileName: "img.jpg")
        let draft = makeDraft(content: "c", stagedFiles: ["img.jpg"])
        await store.save(draft)

        await store.clear(sessionId: draft.sessionId)

        let orphans = await store.orphanDrafts()
        XCTAssertTrue(orphans.isEmpty, "记录应被清除")
        let staged = await store.stagedImageData("img.jpg")
        XCTAssertNotNil(staged, "staged 文件应保留：恢复接管场景新记录还要引用它")
    }

    func test_stagedImageRoundTrip() async throws {
        let store = makeStore()
        let payload = Data("fake-image".utf8)
        await store.writeStagedImage(payload, fileName: "a.jpg")

        let loaded = await store.stagedImageData("a.jpg")
        XCTAssertEqual(loaded, payload)

        await store.removeStagedImage("a.jpg")
        let removed = await store.stagedImageData("a.jpg")
        XCTAssertNil(removed)
    }

    // MARK: - 损坏容错

    func test_corruptedRecord_toleratedAsMissing() async throws {
        let store = makeStore()
        let good = makeDraft(content: "好记录")
        await store.save(good)
        let badURL = draftsDirectory().appendingPathComponent(UUID().uuidString + ".json")
        try Data("这不是 JSON".utf8).write(to: badURL)

        let orphans = await store.orphanDrafts()
        XCTAssertEqual(orphans.count, 1, "损坏记录按不存在处理，不影响其他记录")
        XCTAssertEqual(orphans.first?.content, "好记录")
    }

    // MARK: - 孤儿 staged 文件对账（T12 兜底）

    func test_cleanupOrphans_removesOldUnreferencedFiles() async throws {
        let store = makeStore()
        await store.writeStagedImage(Data([1]), fileName: "referenced.jpg")
        await store.writeStagedImage(Data([2]), fileName: "orphan.jpg")

        // 把 orphan.jpg 的修改时间拨到 8 天前
        let orphanURL = stagedDirectory().appendingPathComponent("orphan.jpg")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: orphanURL.path
        )

        let draft = makeDraft(content: "c", stagedFiles: ["referenced.jpg"])
        await store.save(draft)

        await store.cleanupOrphans()

        let kept = await store.stagedImageData("referenced.jpg")
        XCTAssertNotNil(kept, "被记录引用的 staged 文件必须保留")
        let gone = await store.stagedImageData("orphan.jpg")
        XCTAssertNil(gone, "超期且无引用的 staged 文件应被清理")
    }
}
