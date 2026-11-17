//
//  VisualAssetArchiveServiceTests.swift
//  HoloTests
//
//  素材包契约（方案 02 §9）：导出→导入幂等复用、墓碑跳过不绕过、路径穿越拒绝、
//  hash 篡改拒绝、同 ID 异内容重映射（不覆盖旧素材）。owner 不在本机只导素材。
//

import XCTest
import CoreData
@testable import Holo

final class VisualAssetArchiveServiceTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var dir: URL!
    private let repo = VisualAssetRepository.shared

    override func setUpWithError() throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["VisualAsset", "VisualPlacementRevision", "VisualAssetTombstone"])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visual-archive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 造一个最小合法素材（sourceData 像素 + thumbnail）
    private func makeAsset(id: UUID, pixel: UInt8) -> VisualAsset {
        let a = VisualAsset(context: context)
        a.setValue(id, forKey: "id")
        a.setValue(UUID(), forKey: "creationOperationID")
        a.setValue("sticker", forKey: "kind")
        a.setValue(Data([pixel, pixel, pixel]), forKey: "sourceData")
        a.setValue(Data([pixel]), forKey: "thumbnailData")
        a.setValue(Date(), forKey: "createdAt")
        a.setValue("visible", forKey: "libraryVisibility")
        try? context.save()
        return a
    }

    func testExportImportRoundTripReuse() throws {
        let id = UUID()
        makeAsset(id: id, pixel: 0xAB)
        _ = try VisualAssetArchiveService.export(assets: [repo.findAsset(byID: id, in: context)!], to: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))

        // 清空后导入：imported = 1，同 ID 落库
        try CoreDataTestSupport.clearEntities(context, ["VisualAsset"])
        let report = try VisualAssetArchiveService.import(from: dir, into: context)
        XCTAssertEqual(report.imported, 1)
        XCTAssertNotNil(repo.findAsset(byID: id, in: context), "同 ID 同内容恢复原 ID")
        XCTAssertEqual(report.tombstoneSkipped, [])

        // 再导一次：复用（幂等重试不重复）
        let report2 = try VisualAssetArchiveService.import(from: dir, into: context)
        XCTAssertEqual(report2.reused, 1)
        XCTAssertEqual(report2.imported, 0)
    }

    func testImportTombstoneSkippedNotBypassed() throws {
        let id = UUID()
        makeAsset(id: id, pixel: 0xCD)
        _ = try repo.writeTombstone(operationID: UUID(), assetID: id, in: context)
        try? context.save()
        // 导出含墓碑素材 → 如实失败（不输出半包）
        XCTAssertThrowsError(try VisualAssetArchiveService.export(assets: [repo.findAsset(byID: id, in: context)!], to: dir)) { error in
            guard case VisualArchiveError.tombstoneSkipped = error else {
                return XCTFail("应报墓碑，实际 \(error)")
            }
        }
        // 手工构造一个含墓碑 ID 的包 → 导入跳过并报告
        let other = UUID()
        makeAsset(id: other, pixel: 0xEF)
        let cleanDir = dir.appendingPathComponent("clean", isDirectory: true)
        _ = try VisualAssetArchiveService.export(assets: [repo.findAsset(byID: other, in: context)!], to: cleanDir)
        try CoreDataTestSupport.clearEntities(context, ["VisualAsset"])
        _ = try repo.writeTombstone(operationID: UUID(), assetID: other, in: context)
        try? context.save()
        let report = try VisualAssetArchiveService.import(from: cleanDir, into: context)
        XCTAssertEqual(report.tombstoneSkipped, [other.uuidString], "墓碑 ID 跳过并报告，不自动换 ID 绕过删除")
        XCTAssertEqual(report.imported, 0)
    }

    func testImportRejectsPathTraversal() throws {
        let id = UUID()
        makeAsset(id: id, pixel: 0x11)
        _ = try VisualAssetArchiveService.export(assets: [repo.findAsset(byID: id, in: context)!], to: dir)
        // 篡改 manifest：把 sourceData 的 path 改成 ../evil.bin
        let manifestURL = dir.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(VisualArchiveManifest.self, from: Data(contentsOf: manifestURL))
        manifest.assets[0].files[0].path = "../evil.bin"
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try CoreDataTestSupport.clearEntities(context, ["VisualAsset"])
        XCTAssertThrowsError(try VisualAssetArchiveService.import(from: dir, into: context)) { error in
            guard case VisualArchiveError.pathUnsafe = error else {
                return XCTFail("应拒路径穿越，实际 \(error)")
            }
        }
    }

    func testImportRejectsHashMismatch() throws {
        let id = UUID()
        makeAsset(id: id, pixel: 0x22)
        _ = try VisualAssetArchiveService.export(assets: [repo.findAsset(byID: id, in: context)!], to: dir)
        // 篡改一个数据文件
        let fileURL = dir.appendingPathComponent("\(id.uuidString)-sourceData.bin")
        try Data([0xFF, 0xFF]).write(to: fileURL)
        try CoreDataTestSupport.clearEntities(context, ["VisualAsset"])
        XCTAssertThrowsError(try VisualAssetArchiveService.import(from: dir, into: context)) { error in
            guard case VisualArchiveError.hashMismatch = error else {
                return XCTFail("应拒 hash 不符，实际 \(error)")
            }
        }
    }

    func testSameIDDifferentContentRemapsNotOverwrite() throws {
        let id = UUID()
        makeAsset(id: id, pixel: 0x33)
        _ = try VisualAssetArchiveService.export(assets: [repo.findAsset(byID: id, in: context)!], to: dir)
        // 本机把同 ID 素材内容改掉（模拟两端各自持有同 ID 异内容）
        let local = repo.findAsset(byID: id, in: context)!
        local.setValue(Data([0x99, 0x99, 0x99]), forKey: "sourceData")
        try context.save()
        let report = try VisualAssetArchiveService.import(from: dir, into: context)
        XCTAssertEqual(report.remapped, 1, "同 ID 异内容 → 新 ID 仅重映射本次，不覆盖旧素材")
        XCTAssertEqual(repo.findAsset(byID: id, in: context)!.value(forKey: "sourceData") as? Data, Data([0x99, 0x99, 0x99]),
                       "本机原素材内容未被覆盖")
    }
}
