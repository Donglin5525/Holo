//
//  VisualAssetRepositoryTests.swift
//  HoloTests
//
//  位置解析契约测试：把方案 fixtures/contract-cases.json 的 revisionCases
//  （V01–V14）逐条迁成 Swift 断言——到达顺序无关、重复到达不影响声明结果、
//  墙上时间不参与胜出、墓碑优先、高版本 unsupported、坏数据 corrupt。
//  外加仓库行为：clock 单调分配、按 operationID 幂等创建、placementKey 归一化、
//  payload 规范编码往返与值域校验。
//

import XCTest
import CoreData
@testable import Holo

final class VisualAssetRepositoryTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private let repo = VisualAssetRepository.shared

    private let assetA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let assetB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearEntities(context, ["VisualAsset", "VisualPlacementRevision", "VisualAssetTombstone"])
    }

    // MARK: - 构造工具

    private func makeAsset(_ id: UUID) {
        let a = VisualAsset(context: context)
        a.setValue(id, forKey: "id")
        a.setValue(UUID(), forKey: "creationOperationID")
        a.setValue("sticker", forKey: "kind")
        a.setValue(Date(), forKey: "createdAt")
        a.setValue("visible", forKey: "libraryVisibility")
        try? context.save()
    }

    private func makeTombstone(_ assetID: UUID) {
        let t = VisualAssetTombstone(context: context)
        t.setValue(UUID(), forKey: "id")
        t.setValue(UUID(), forKey: "operationID")
        t.setValue(assetID, forKey: "assetID")
        t.setValue(Date(), forKey: "deletedAt")
        try? context.save()
    }

    /// 直接构造一条位置版本（模拟本机写入或远端同步到达的记录）
    @discardableResult
    private func makeRevision(op: String, clock: Int64, writer: String, mutation: String = "",
                              action: VisualPlacementPayload.Action, assetID: UUID?,
                              schemaVersion: Int = 1, payloadJSON: String? = nil,
                              changedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                              incomplete: Bool = false) -> VisualPlacementRevision {
        let r = VisualPlacementRevision(context: context)
        let opID = opName(op)
        if incomplete {
            // 模拟「包络尚不完整」的远端部分同步记录：有 operationID 和 placementKey，
            // 缺 clock/writer/payloadJSON 等其余必需字段
            r.setValue(opID, forKey: "operationID")
            r.setValue("spendingProject", forKey: "ownerKind")
            r.setValue("owner-key", forKey: "ownerKey")
            r.setValue("primaryVisual", forKey: "slot")
            r.setValue(VisualPlacementCoding.placementKey(ownerKind: "spendingProject", ownerKey: "owner-key", slot: "primaryVisual"), forKey: "placementKey")
            try? context.save()
            return r
        }
        var json = payloadJSON
        if json == nil {
            let payload: VisualPlacementPayload
            switch action {
            case .set:
                payload = .setAsset(.asset(assetID!), presentation: nil)
            case .clear:
                payload = .clear
            }
            if schemaVersion != payload.schemaVersion {
                json = "{\"action\":\"\(action.rawValue)\",\"schemaVersion\":\(schemaVersion),"
                    + "\"selection\":{\"assetID\":\"\(assetID?.uuidString ?? "")\",\"type\":\"asset\"},"
                    + "\"presentation\":null}"
            } else {
                json = String(data: try! VisualPlacementCoding.canonicalData(payload), encoding: .utf8)
            }
        }
        r.setValue(UUID(), forKey: "id")
        r.setValue(opID, forKey: "operationID")
        r.setValue(mutation.isEmpty ? opID : opName(mutation), forKey: "mutationID")
        r.setValue("spendingProject", forKey: "ownerKind")
        r.setValue("owner-key", forKey: "ownerKey")
        r.setValue("primaryVisual", forKey: "slot")
        r.setValue(VisualPlacementCoding.placementKey(ownerKind: "spendingProject", ownerKey: "owner-key", slot: "primaryVisual"), forKey: "placementKey")
        r.setValue(clock, forKey: "logicalClock")
        r.setValue(writer, forKey: "writerID")
        r.setValue(json, forKey: "payloadJSON")
        // 测试注入的 hash 允许显式覆盖（V09 需要 hash 不一致）；默认给一个稳定值
        r.setValue("hash-\(action.rawValue)-\(assetID?.uuidString ?? "none")-v\(schemaVersion)", forKey: "payloadHash")
        r.setValue(changedAt, forKey: "changedAt")
        try? context.save()
        return r
    }

    /// 稳定 op 名 → UUID：FNV-1a 手写哈希（不受 Swift hashValue 进程随机化影响，
    /// 也不踩 %d 吃 64 位值的格式符坑）
    private func opName(_ s: String) -> UUID {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        let digits = String(format: "%012llx", hash % 0x1000_0000_0000)
        return UUID(uuidString: "00000000-0000-0000-0000-" + digits)!
    }

    private func setPayloadHash(_ r: VisualPlacementRevision, _ hash: String) {
        r.setValue(hash, forKey: "payloadHash")
        try? context.save()
    }

    private func resolve() -> ResolvedPlacement {
        repo.resolvePlacement(ownerKind: "spendingProject", ownerKey: "OWNER-KEY", slot: "primaryVisual", in: context)
    }

    // MARK: - V01–V14 契约

    func testV01NoRevisionsResolvesNone() {
        XCTAssertEqual(resolve(), .none)
    }

    func testV02SingleSetReady() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        if case .assetReady(let d) = resolve() {
            XCTAssertEqual(d.assetID, assetA)
        } else { XCTFail("应 ready，实际 \(resolve())") }
    }

    func testV03HigherClockClearWins() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        makeRevision(op: "op-b", clock: 2, writer: "writer-a", action: .clear, assetID: nil)
        XCTAssertEqual(resolve(), .none)
    }

    func testV04SameClockWriterTieBreakIgnoredWallClock() {
        makeAsset(assetA); makeAsset(assetB)
        // op-a 的 changedAt=2028（晚）仍输给 writerID 字节序更大的 op-b（changedAt=2025）
        makeRevision(op: "op-a", clock: 4, writer: "writer-a", action: .set, assetID: assetA,
                     changedAt: ISO8601DateConverter.date("2028-01-01")!)
        makeRevision(op: "op-b", clock: 4, writer: "writer-b", action: .set, assetID: assetB,
                     changedAt: ISO8601DateConverter.date("2025-01-01")!)
        if case .assetReady(let d) = resolve() {
            XCTAssertEqual(d.assetID, assetB, "同 clock 时 writerID 字节序大者胜，changedAt 不参与")
        } else { XCTFail("应 ready，实际 \(resolve())") }
    }

    func testV05UnknownHigherSchemaVersionUnsupported() {
        makeAsset(assetA)
        makeRevision(op: "op-b", clock: 2, writer: "writer-a", action: .set, assetID: assetA, schemaVersion: 2)
        XCTAssertEqual(resolve(), .unsupported(schemaVersion: 2))
    }

    func testV06TombstoneBeatsReadyAsset() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 99, writer: "writer-a", action: .set, assetID: assetA)
        makeTombstone(assetA)
        XCTAssertEqual(resolve(), .deleted)
    }

    func testV07AssetNotYetArrivedPending() {
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        XCTAssertEqual(resolve(), .pending, "引用先到素材未到：占位不丢")
    }

    func testV08IncompleteEnvelopePending() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        makeRevision(op: "op-b", clock: 0, writer: "", action: .set, assetID: nil, incomplete: true)
        XCTAssertEqual(resolve(), .pending, "存在不完整包络：pending 只读，不拿旧版当确定赢家")
    }

    func testV09SameOperationDifferentHashCorrupt() {
        makeAsset(assetA)
        let r1 = makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        setPayloadHash(r1, "hash-one")
        let r2 = makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        setPayloadHash(r2, "hash-two")
        if case .corrupt = resolve() {} else { XCTFail("同 op 不同 hash 应 corrupt，实际 \(resolve())") }
    }

    func testV10DuplicateArrivalIdempotent() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        if case .assetReady(let d) = resolve() {
            XCTAssertEqual(d.assetID, assetA)
        } else { XCTFail("重复到达不影响声明结果，实际 \(resolve())") }
    }

    func testV11HigherClockSetBeatsEarlierClear() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 2, writer: "writer-a", action: .clear, assetID: nil)
        makeRevision(op: "op-b", clock: 3, writer: "writer-a", action: .set, assetID: assetA)
        if case .assetReady(let d) = resolve() {
            XCTAssertEqual(d.assetID, assetA)
        } else { XCTFail("应 ready，实际 \(resolve())") }
    }

    func testV12InvalidPayloadCorrupt() {
        makeAsset(assetA)
        // focusX 越界（5.0 > 1）→ 解码成功但值域非法 → corrupt
        let bad = "{\"action\":\"set\",\"presentation\":{\"borderStyle\":\"adaptivePaper\",\"borderWeight\":\"standard\",\"fit\":\"contain\",\"focusX\":5.0,\"focusY\":0.5,\"rotationDegrees\":0,\"scale\":1.0,\"softenPhotoInDark\":false},\"schemaVersion\":1,\"selection\":{\"assetID\":\"\(assetA.uuidString)\",\"type\":\"asset\"}}"
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA, payloadJSON: bad)
        if case .corrupt = resolve() {} else { XCTFail("payload 越界应 corrupt，实际 \(resolve())") }
    }

    func testV13SameOperationDifferentClockCorrupt() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA)
        makeRevision(op: "op-a", clock: 9, writer: "writer-a", action: .set, assetID: assetA)
        if case .corrupt = resolve() {} else { XCTFail("同 op 不同 clock 应 corrupt，实际 \(resolve())") }
    }

    func testV14ChangedAtAloneDoesNotAffectOutcome() {
        makeAsset(assetA)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA,
                     changedAt: ISO8601DateConverter.date("2026-11-17")!)
        makeRevision(op: "op-a", clock: 1, writer: "writer-a", action: .set, assetID: assetA,
                     changedAt: ISO8601DateConverter.date("2029-11-17")!)
        if case .assetReady(let d) = resolve() {
            XCTAssertEqual(d.assetID, assetA, "仅 changedAt 不同的物理副本不改变赢家")
        } else { XCTFail("实际 \(resolve())") }
    }

    // MARK: - 仓库行为

    func testCommitRevisionAllocatesMonotonicClock() throws {
        let op1 = UUID(), op2 = UUID()
        let r1 = try repo.commitRevision(operationID: op1, ownerKind: "thought", ownerKey: "T-1", slot: "hero",
                                         payload: .setAsset(.asset(assetA), presentation: nil), in: context)
        let r2 = try repo.commitRevision(operationID: op2, ownerKind: "thought", ownerKey: "T-1", slot: "hero",
                                         payload: .clear, in: context)
        let c1 = r1.value(forKey: "logicalClock") as! Int64
        let c2 = r2.value(forKey: "logicalClock") as! Int64
        XCTAssertEqual(c2, c1 + 1, "同 slot 后提交的版本 clock 更高")
        // clear 胜出
        XCTAssertEqual(repo.resolvePlacement(ownerKind: "thought", ownerKey: "T-1", slot: "hero", in: context), .none)
    }

    func testCreateAssetIdempotentByOperationID() throws {
        let op = UUID()
        let a1 = try repo.createAssetIfNeeded(operationID: op, kind: .sticker,
                                              assign: { $0.setValue("贴纸 1", forKey: "displayName") }, in: context)
        try context.save()
        let a2 = try repo.createAssetIfNeeded(operationID: op, kind: .sticker, assign: { _ in }, in: context)
        XCTAssertEqual(a1.objectID, a2.objectID, "重试复用同一 operation 的素材，不重复创建")
    }

    func testPlacementKeyNormalizesOwnerKeyCase() {
        // ownerKey 归一化为小写后，大小写不同的写入落到同一 slot
        makeAsset(assetA)
        _ = try! repo.commitRevision(operationID: UUID(), ownerKind: "thought", ownerKey: "ABC-123", slot: "hero",
                                     payload: .setAsset(.asset(assetA), presentation: nil), in: context)
        let resolved = repo.resolvePlacement(ownerKind: "thought", ownerKey: "abc-123", slot: "hero", in: context)
        if case .assetReady(let d) = resolved {
            XCTAssertEqual(d.assetID, assetA)
        } else { XCTFail("ownerKey 大小写归一化后应命中，实际 \(resolved)") }
    }

    func testPayloadCanonicalRoundTrip() throws {
        let payload = VisualPlacementPayload.setAsset(
            .asset(assetA, sourceAttachmentID: UUID()),
            presentation: .init(fit: .contain, focusX: 0.3, focusY: 0.7, scale: 1.1,
                                rotationDegrees: -3, borderStyle: .white, borderWeight: .thin,
                                softenPhotoInDark: true))
        let json = String(data: try VisualPlacementCoding.canonicalData(payload), encoding: .utf8)!
        let back = try VisualPlacementCoding.decode(from: json)
        XCTAssertEqual(back, payload, "规范编码往返无损")
        // 键序稳定（两次编码字节一致）
        let json2 = String(data: try VisualPlacementCoding.canonicalData(payload), encoding: .utf8)!
        XCTAssertEqual(json, json2)
    }

    func testValidateBounds() {
        func expectThrow(_ p: VisualPlacementPayload, kind: VisualAssetKind = .sticker) -> VisualPlacementPayloadError? {
            do { try p.validate(kind: kind); return nil } catch let e as VisualPlacementPayloadError { return e } catch { return nil }
        }
        var p = VisualPlacementPayload.setAsset(.asset(assetA), presentation: .init(focusX: 1.5, focusY: 0.5))
        XCTAssertEqual(expectThrow(p), .invalidFocus)
        p = VisualPlacementPayload.setAsset(.asset(assetA), presentation: .init(scale: 2.0))
        XCTAssertEqual(expectThrow(p), .invalidScale)
        p = VisualPlacementPayload.setAsset(.asset(assetA), presentation: .init(rotationDegrees: 9))
        XCTAssertEqual(expectThrow(p), .invalidRotation)
        // sticker 只允许 contain
        p = VisualPlacementPayload.setAsset(.asset(assetA), presentation: .init(fit: .cover))
        XCTAssertEqual(expectThrow(p), .stickerMustContain)
        // photo 允许 cover
        p = VisualPlacementPayload.setAsset(.asset(assetA), presentation: .init(fit: .cover))
        XCTAssertEqual(expectThrow(p, kind: .photo), nil)
        // record 选择的形状约束
        p = VisualPlacementPayload.setAsset(.record(module: "thought", recordID: UUID()), presentation: nil)
        XCTAssertEqual(expectThrow(p), nil)
    }

    func testRecordSelectionResolves() {
        let recordID = UUID()
        _ = try! repo.commitRevision(operationID: UUID(), ownerKind: "galleryDay",
                                     ownerKey: "[2026,11,17]", slot: "featuredRecord",
                                     payload: .setRecord(module: "thought", recordID: recordID), in: context)
        XCTAssertEqual(repo.resolvePlacement(ownerKind: "galleryDay", ownerKey: "[2026,11,17]",
                                             slot: "featuredRecord", in: context),
                       .recordSelected(module: "thought", recordID: recordID))
    }

    func testResolveOnForeignContextReturnsNoneInsteadOfCrash() {
        // 2026-11-17 真机闪退回归锁：固定支出页曾拿到环境默认的空模型临时 context，
        // entityForName 抛 ObjC 异常（try? 拦不住）直接闪退。修复后语义=无贴纸数据
        let foreign = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        foreign.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
        let resolved = repo.resolvePlacement(ownerKind: "spendingProject", ownerKey: "any",
                                             slot: "primaryVisual", in: foreign)
        XCTAssertEqual(resolved, .none, "陌生模型 context 上解析必须安静返回 none，不许抛异常")
    }

    func testCreateAssetAndApplyEndToEndResolvesReady() async throws {
        // 11-17 东林实报「设置外观没生效」回归锁：制作页提交带占位 assetID 的 payload，
        // 协调器必须重映射为真实素材 ID——读取端（viewContext）解析要命中 assetReady
        let op = UUID()
        let receipt = try await VisualCommitCoordinator.shared.commit(
            .createAssetAndApply(operationID: op, ownerKind: "spendingProject", ownerKey: "p-e2e",
                                 slot: "primaryVisual", expectedSlotWinnerRevisionID: nil,
                                 payload: .setAsset(.asset(UUID()), presentation: nil)) { _ in },
            in: CoreDataTestSupport.sharedTestContainer)
        let resolved = repo.resolvePlacement(ownerKind: "spendingProject", ownerKey: "P-E2E",
                                             slot: "primaryVisual", in: context)
        guard case .assetReady(let d) = resolved else {
            return XCTFail("提交后解析应 assetReady（重映射真实ID），实际 \(resolved)")
        }
        XCTAssertEqual(d.assetID, receipt.assetID, "位置记录必须指向真实创建的素材")
    }

    func testWriterIDStableAndUUIDShaped() {
        XCTAssertTrue(UUID(uuidString: VisualAssetRepository.writerID) != nil, "writerID 是安装级 UUID 串")
    }

    @MainActor
    func testCreateAssetOnlyAsyncCommitPersistsAndIsVisibleInViewContext() async throws {
        // 11-17 回归锁：主线程调用 VisualCommitCoordinator.commit(.createAssetOnly) 异步落库后，
        // viewContext 必须能查到该贴纸且 libraryVisibility == "visible"
        let op = UUID()
        let receipt = try await VisualCommitCoordinator.shared.commit(
            .createAssetOnly(operationID: op) { asset in
                asset.setValue("sticker", forKey: "kind")
                asset.setValue("visible", forKey: "libraryVisibility")
            },
            in: CoreDataTestSupport.sharedTestContainer)
        guard let assetID = receipt.assetID else {
            return XCTFail("createAssetOnly 必须返回 assetID")
        }
        let fetched = repo.findAsset(byID: assetID, in: context)
        XCTAssertNotNil(fetched, "viewContext 应能立即查到新建贴纸")
        XCTAssertEqual(fetched?.value(forKey: "libraryVisibility") as? String, "visible")
    }

    func testReplacingExistingPlacementWithExpectedWinnerSucceeds() async throws {
        // 11-17 回归锁：已有贴纸的固定支出重新选贴纸时，传入当前赢家 revisionID 应覆盖成功；传 nil 应报 conflict
        let ownerKey = "p-replace-\(UUID().uuidString)"
        let asset1 = UUID(), asset2 = UUID()
        _ = try await VisualCommitCoordinator.shared.commit(
            .createAssetAndApply(operationID: UUID(), ownerKind: "spendingProject", ownerKey: ownerKey,
                                 slot: "primaryVisual", expectedSlotWinnerRevisionID: nil,
                                 payload: .setAsset(.asset(asset1), presentation: nil)) { _ in },
            in: CoreDataTestSupport.sharedTestContainer)
        guard case .assetReady(let first) = repo.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context) else {
            return XCTFail("首次应用应 assetReady")
        }

        do {
            _ = try await VisualCommitCoordinator.shared.commit(
                .applyPlacement(operationID: UUID(), ownerKind: "spendingProject", ownerKey: ownerKey,
                                slot: "primaryVisual", expectedSlotWinnerRevisionID: nil,
                                payload: .setAsset(.asset(asset2), presentation: nil)),
                in: CoreDataTestSupport.sharedTestContainer)
            XCTFail("已有赢家时传 nil 基线必须抛出 conflict")
        } catch VisualCommitError.conflict(let currentID) {
            XCTAssertEqual(currentID, first.winningRevisionID)
        }

        let receipt2 = try await VisualCommitCoordinator.shared.commit(
            .createAssetAndApply(operationID: UUID(), ownerKind: "spendingProject", ownerKey: ownerKey,
                                 slot: "primaryVisual", expectedSlotWinnerRevisionID: first.winningRevisionID,
                                 payload: .setAsset(.asset(asset2), presentation: nil)) { _ in },
            in: CoreDataTestSupport.sharedTestContainer)
        guard case .assetReady(let second) = repo.resolvePlacement(
            ownerKind: "spendingProject", ownerKey: ownerKey, slot: "primaryVisual", in: context) else {
            return XCTFail("传入正确赢家基线后覆盖应成功")
        }
        XCTAssertEqual(second.assetID, receipt2.assetID)
    }
}

/// 测试用 ISO 日期
enum ISO8601DateConverter {
    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}
