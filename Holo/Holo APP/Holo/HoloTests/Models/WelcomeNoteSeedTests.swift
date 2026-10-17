//
//  WelcomeNoteSeedTests.swift
//  HoloTests
//
//  预置欢迎笔记（新人笔记）种子与防污染测试：
//  - 种子幂等（物理空表才种）与固定 UUID 落库
//  - 激活/统计/手动整理三处排除（预置内容不冒充用户记录）
//  - SeedRevivalRepair Thought 段（重装/跨设备误种清理、已编辑保留、删过不复活语义）
//  - 必达跳转 pending/ack 状态机
//

import XCTest
import CoreData
@testable import Holo

final class WelcomeNoteSeedTests: XCTestCase {

    private var context: NSManagedObjectContext!
    /// SeedRevivalRepair.recordSeedMoment 落的是真实 UserDefaults，
    /// 测试必须自产自清，防止污染其他用例的铁证判定
    private let seedMomentKey = "holo.seed.revival.timestamp.v1"

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
    }

    override func tearDown() {
        try? CoreDataTestSupport.clearAllEntities(context)
        UserDefaults.standard.removeObject(forKey: seedMomentKey)
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeThought(
        id: UUID = UUID(),
        content: String = "一条普通想法",
        createdAt: Date = Date(),
        editedSecondsLater: TimeInterval = 0
    ) -> Thought {
        let thought = Thought(context: context)
        thought.id = id
        thought.content = content
        thought.createdAt = createdAt
        thought.updatedAt = createdAt.addingTimeInterval(editedSecondsLater)
        thought.organizedStatus = "disabled"
        return thought
    }

    private func fetchThought(id: UUID) -> Thought? {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - 种子

    func test种子_物理空表_种入固定UUID欢迎笔记() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        let note = try XCTUnwrap(fetchThought(id: WelcomeNoteSeed.noteId))
        XCTAssertEqual(note.firstLine, WelcomeNoteSeed.localizedNoteTitle.currentValue)
        XCTAssertEqual(note.organizedStatus, "disabled", "预置笔记不进 AI 整理")
        XCTAssertFalse(note.content.isEmpty)
        XCTAssertTrue(WelcomeNoteSeed.isNoteAlive(context: context))
    }

    func test种子_已有任何Thought行_不种() throws {
        makeThought()
        try context.save()

        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        XCTAssertNil(fetchThought(id: WelcomeNoteSeed.noteId), "存量想法（含软删）在场时不得种欢迎笔记")
    }

    func test种子_三语文案齐全且互异() {
        let content = WelcomeNoteSeed.localizedNoteContent
        let title = WelcomeNoteSeed.localizedNoteTitle
        for term in [content, title] {
            XCTAssertFalse(term.hans.isEmpty)
            XCTAssertFalse(term.hant.isEmpty)
            XCTAssertFalse(term.english.isEmpty)
        }
        XCTAssertNotEqual(content.hans, content.hant)
        XCTAssertNotEqual(content.hans, content.english)
    }

    // MARK: - 激活判定排除

    func test激活_只有欢迎笔记_不算已激活() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        XCTAssertFalse(
            NewUserActivationState.hasAnyRecord(context: context),
            "欢迎笔记不得让行动卡/首录庆祝误判用户已激活"
        )
    }

    func test激活_普通想法在场_正常判激活() throws {
        makeThought()
        try context.save()

        XCTAssertTrue(NewUserActivationState.hasAnyRecord(context: context))
    }

    // MARK: - 统计聚合排除

    func test统计_想法计数不含欢迎笔记() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        makeThought(content: "用户自己的第一条")
        try context.save()

        // retain：MainActor 隔离类在同步用例栈上析构会触发
        // swift_task_deinitOnExecutorMainActorBackDeploy 的 malloc 崩溃（测试基建既有坑）
        let repo = ThoughtRepository(context: context)
        CoreDataTestSupport.retain(repo)
        let window = DateInterval(start: Date(timeIntervalSinceNow: -3600), end: Date(timeIntervalSinceNow: 3600))
        let count = repo.getThoughtCount(from: window.start, to: window.end)

        XCTAssertEqual(count, 1, "统计聚合只数用户记录，欢迎笔记被排除")
    }

    // MARK: - 手动批量整理排除

    func test手动整理_欢迎笔记不进批量范围() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        // retain：同上，防 MainActor 隔离类同步析构崩溃
        let repo = ThoughtRepository(context: context)
        CoreDataTestSupport.retain(repo)
        let ids = try repo.fetchUnprocessedThoughtIds()
        let badge = try repo.countUnprocessed()

        XCTAssertFalse(ids.contains(WelcomeNoteSeed.noteId), "disabled 不在终态集合内，靠显式排除防误捞")
        XCTAssertEqual(badge, 0, "未整理徽章不得被欢迎笔记顶成 1")
    }

    // MARK: - 重装误种清理（SeedRevivalRepair Thought 段）
    // 时序还原重装现场：本地空表先误种 fresh 欢迎笔记（seedIfNeeded 内部已记
    // 种子时刻）→ iCloud 把卸载前的想法恢复回来（createdAt 早于种子时刻）→ repair。

    func test修复_铁证成立_清未编辑种子行() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()
        XCTAssertNotNil(fetchThought(id: WelcomeNoteSeed.noteId), "前置：fresh 种子行已落库")

        // 老用户回来了：卸载前的想法（createdAt 早于种子时刻）
        makeThought(id: UUID(), createdAt: Date(timeIntervalSinceNow: -86_400))
        try context.save()

        SeedRevivalRepair.repairIfNeeded(context: context)

        XCTAssertNil(fetchThought(id: WelcomeNoteSeed.noteId), "fresh 种子行应被清除")
        XCTAssertEqual(try context.count(for: Thought.fetchRequest()), 1, "老用户的想法原样保留")
    }

    func test修复_用户已编辑的欢迎笔记_保留() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        // 同步下来的编辑版：updatedAt 明显晚于 createdAt（超过 60s 容差）
        let note = try XCTUnwrap(fetchThought(id: WelcomeNoteSeed.noteId))
        note.updatedAt = note.createdAt.addingTimeInterval(600)
        makeThought(id: UUID(), createdAt: Date(timeIntervalSinceNow: -86_400))
        try context.save()

        SeedRevivalRepair.repairIfNeeded(context: context)

        XCTAssertNotNil(fetchThought(id: WelcomeNoteSeed.noteId), "用户改过内容的按真实想法保留")
    }

    func test修复_删过笔记的重装_不复活() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        // 卸载前删掉的欢迎笔记（软删行随 iCloud 回来，与 fresh 行同 id 并存）
        makeThought(id: WelcomeNoteSeed.noteId, createdAt: Date(timeIntervalSinceNow: -86_400))
            .markDeleted(batchId: UUID())
        try context.save()

        SeedRevivalRepair.repairIfNeeded(context: context)

        let alive = WelcomeNoteSeed.isNoteAlive(context: context)
        XCTAssertFalse(alive, "用户删过的预设不得复活：fresh 行被清，软删行维持删除")
    }

    func test修复_无铁证_真新用户零写入() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()

        SeedRevivalRepair.repairIfNeeded(context: context)

        XCTAssertNotNil(fetchThought(id: WelcomeNoteSeed.noteId), "真新用户没有铁证，欢迎笔记原样保留")
    }

    // MARK: - 必达跳转状态机

    func test状态机_pending落盘与送达回执() {
        let defaults = UserDefaults(suiteName: "welcomenote-tests")!
        defaults.removePersistentDomain(forName: "welcomenote-tests")
        defer { defaults.removePersistentDomain(forName: "welcomenote-tests") }

        // 注入独立 defaults 验证状态语义本身；mark/ack 读写同一 key
        WelcomeNoteSeed.markPendingPresentation(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: OnboardingProgressStore.welcomeNotePendingKey))

        WelcomeNoteSeed.acknowledgePresentation(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: OnboardingProgressStore.welcomeNotePendingKey))
    }

    // MARK: - 找回入口显隐

    func test找回入口_软删后隐藏() throws {
        WelcomeNoteSeed.seedIfNeeded(context: context)
        try context.save()
        XCTAssertTrue(WelcomeNoteSeed.isNoteAlive(context: context))

        let note = try XCTUnwrap(fetchThought(id: WelcomeNoteSeed.noteId))
        note.markDeleted(batchId: UUID())
        try context.save()

        XCTAssertFalse(WelcomeNoteSeed.isNoteAlive(context: context), "删除后设置页入口应隐藏")
    }
}
