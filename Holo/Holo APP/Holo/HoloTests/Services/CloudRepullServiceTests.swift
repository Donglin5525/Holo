//
//  CloudRepullServiceTests.swift
//  HoloTests
//
//  Cloud 重拉（P2）可单测件：
//  - 导入稳定探测：未开始传输绝不判稳（空库「稳定」只是还没开始）；
//  - 备份文件工具：三件套改名/逆转还原/只清理重拉备份。
//  完整状态机（备份→重建→导入→报告）走真机验收，不做单例打桩。
//

import XCTest
import OSLog
@testable import Holo

final class CloudRepullServiceTests: XCTestCase {

    private var tempDir: URL!
    private let logger = Logger(subsystem: "com.tangyuxuan.Holo.tests", category: "CloudRepull")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudrepull-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - 导入稳定探测

    private func counts(_ values: [Int]) -> [CloudRepullService.EntityCount] {
        zip(CloudRepullService.trackedEntities, values).map {
            CloudRepullService.EntityCount(entity: $0.entity, displayName: $0.displayName, count: $1)
        }
    }

    func testNotStableBeforeAnyImportCompleted() {
        // 空库计数完全一致，但一次 import 成功事件都没收到：只是传输还没开始，绝不判稳
        let stable = counts([0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(CloudRepullService.importStreamStabilized(
            history: [stable, stable, stable], importCompleted: false
        ))
    }

    func testStableAfterImportCompletedWithRepeatedCounts() {
        let stable = counts([10, 5, 2, 30, 4, 1, 88, 93, 5])
        XCTAssertTrue(CloudRepullService.importStreamStabilized(
            history: [stable, stable, stable], importCompleted: true
        ))
    }

    func testNotStableWhileCountsStillChanging() {
        let a = counts([10, 5, 2, 30, 4, 1, 88, 93, 5])
        let b = counts([11, 5, 2, 30, 4, 1, 88, 93, 5])
        XCTAssertFalse(CloudRepullService.importStreamStabilized(
            history: [a, b, b], importCompleted: true
        ))
        XCTAssertFalse(CloudRepullService.importStreamStabilized(
            history: [a, a, b], importCompleted: true
        ))
    }

    func testNotStableWithInsufficientHistory() {
        let stable = counts([1, 1, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertFalse(CloudRepullService.importStreamStabilized(
            history: [stable, stable], importCompleted: true
        ))
        XCTAssertTrue(CloudRepullService.importStreamStabilized(
            history: [stable, stable], importCompleted: true, requiredRepeats: 2
        ))
    }

    // MARK: - 备份文件工具（CoreDataStack 静态层）

    private func makeFakeStoreFiles(at storeURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try Data("fake\(suffix)".utf8).write(to: url)
        }
    }

    func testMoveStoreFilesBacksUpAllThreeFiles() throws {
        let storeURL = tempDir.appendingPathComponent("HoloDataModel.sqlite")
        try makeFakeStoreFiles(at: storeURL)

        let result = CoreDataStack.moveStoreFiles(
            at: storeURL, suffix: CoreDataStack.cloudRepullBackupSuffix, logger: logger
        )

        XCTAssertTrue(result.isComplete, "三件套齐全时备份必须完整")
        XCTAssertTrue(result.hasMainFile)
        XCTAssertEqual(result.movedFileURLs.count, 3)
        // 原位置三件套已全部挪走
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + suffix))
        }
        // 备份名带统一可逆转标记
        for url in result.movedFileURLs {
            XCTAssertTrue(url.lastPathComponent.contains(CoreDataStack.cloudRepullBackupSuffix))
        }
    }

    func testRevertBackupFilesRestoresOriginalNames() throws {
        let storeURL = tempDir.appendingPathComponent("HoloDataModel.sqlite")
        try makeFakeStoreFiles(at: storeURL)

        let result = CoreDataStack.moveStoreFiles(
            at: storeURL, suffix: CoreDataStack.cloudRepullBackupSuffix, logger: logger
        )
        try CoreDataStack.revertBackupFiles(result.movedFileURLs, logger: logger)

        // 原名三件套全部归位，内容不变
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺少 \(suffix)")
        }
        XCTAssertEqual(
            try String(contentsOf: storeURL, encoding: .utf8), "fake"
        )
    }

    func testRemoveCloudRepullBackupsOnlyCleansRepullBackups() throws {
        let storeURL = tempDir.appendingPathComponent("HoloDataModel.sqlite")
        try makeFakeStoreFiles(at: storeURL)

        // 一份历史重拉备份 + 一份冲突恢复备份（不能被误删）
        _ = CoreDataStack.moveStoreFiles(
            at: storeURL, suffix: CoreDataStack.cloudRepullBackupSuffix, logger: logger
        )
        try makeFakeStoreFiles(at: storeURL)
        _ = CoreDataStack.moveStoreFiles(
            at: storeURL, suffix: ".conflict-backup-", logger: logger
        )
        try makeFakeStoreFiles(at: storeURL)

        CoreDataStack.removeCloudRepullBackups(around: storeURL)

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(files.contains { $0.contains(CoreDataStack.cloudRepullBackupSuffix) }, "重拉备份应被清理")
        XCTAssertTrue(files.contains { $0.contains(".conflict-backup-") }, "冲突恢复备份不得被误删")
        XCTAssertTrue(files.contains("HoloDataModel.sqlite"), "当前库不受影响")
    }
}
