//
//  ICloudSyncStatusServiceTests.swift
//  HoloTests
//
//  iCloud 同步状态机与错误识别测试：
//  核心断言——事件以错误结束时绝不写「成功」状态（假成功根治）；
//  iCloud 满（quotaExceeded）即使包在 partialFailure 里也要识别出来。
//

import XCTest
import CloudKit
import CoreData
@testable import Holo

final class ICloudSyncStatusServiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "iCloudSyncStatusServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    private func makeService() -> ICloudSyncStatusService {
        ICloudSyncStatusService(defaults: defaults)
    }

    /// 构造「配额超限被 partialFailure 包裹」的真实形态错误
    private func makeWrappedQuotaError() -> NSError {
        let quota = NSError(domain: CKErrorDomain, code: CKError.quotaExceeded.rawValue)
        return NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [AnyHashable(1): quota]]
        )
    }

    // MARK: - 错误识别

    func testDirectQuotaExceededIsClassified() {
        let error = NSError(domain: CKErrorDomain, code: CKError.quotaExceeded.rawValue)
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.classify(error), .quotaExceeded)
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.deepestCKErrorCode(error), CKError.quotaExceeded.rawValue)
    }

    func testQuotaInsidePartialFailureIsClassified() {
        let error = makeWrappedQuotaError()
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.classify(error), .quotaExceeded)
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.deepestCKErrorCode(error), CKError.quotaExceeded.rawValue)
    }

    func testQuotaInsideUnderlyingErrorChainIsClassified() {
        let quota = NSError(domain: CKErrorDomain, code: CKError.quotaExceeded.rawValue)
        let wrapped = NSError(domain: "NSPersistentCloudKitContainer", code: 1, userInfo: [NSUnderlyingErrorKey: quota])
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.classify(wrapped), .quotaExceeded)
    }

    func testOperationCancelledIsClassified() {
        let error = NSError(domain: CKErrorDomain, code: CKError.operationCancelled.rawValue)
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.classify(error), .operationCancelled)
    }

    func testOtherCKErrorIsNotQuota() {
        let inner = NSError(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)
        let partial = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [AnyHashable(1): inner]]
        )
        XCTAssertEqual(CloudKitSyncErrorAnalyzer.classify(partial), .other)
    }

    // MARK: - 错误流水

    func testErrorLogKeepsOnlyLatestRecords() {
        for index in 0..<25 {
            let record = SyncErrorRecord(
                date: Date(),
                direction: "export",
                ckErrorCode: index,
                message: "error-\(index)"
            )
            SyncErrorLog.append(record, to: defaults)
        }

        let records = SyncErrorLog.load(from: defaults)
        XCTAssertEqual(records.count, SyncErrorLog.recordLimit)
        XCTAssertEqual(records.first?.message, "error-5")
        XCTAssertEqual(records.last?.message, "error-24")
    }

    // MARK: - 状态机：失败绝不写成功状态

    @MainActor
    func testExportFailureDoesNotWriteSyncTimeOrSuccessText() throws {
        let service = makeService()

        // 先有一次成功 import，让 lastSyncTime 有值
        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)
        let successTime = try XCTUnwrap(service.lastSyncTime)

        // iCloud 满导致 export 失败
        service.processCloudKitEvent(type: .export, endDate: Date(), error: makeWrappedQuotaError())

        XCTAssertFalse(service.isSyncing)
        XCTAssertEqual(service.lastSyncTime, successTime, "上传失败不得刷新最近同步时间")
        XCTAssertEqual(service.lastEventDescription, "本机数据上传失败")
        XCTAssertTrue(service.lastErrorIsQuota)
        XCTAssertEqual(service.lastErrorMessage, "iCloud 空间已满，本机数据未上传")
        XCTAssertEqual(service.errorHistory.count, 1)
        XCTAssertEqual(service.errorHistory.first?.ckErrorCode, CKError.quotaExceeded.rawValue)

        // 持久化生效
        XCTAssertEqual(defaults.string(forKey: "iCloudSyncStatusService.lastErrorMessage"), "iCloud 空间已满，本机数据未上传")
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncStatusService.lastErrorIsQuota"))
    }

    @MainActor
    func testImportSuccessDoesNotClearExportError() {
        let service = makeService()

        service.processCloudKitEvent(type: .export, endDate: Date(), error: makeWrappedQuotaError())
        XCTAssertNotNil(service.lastErrorMessage)

        // 下载方向成功：云端→本机通了，不代表积压数据传了上去，错误必须保留
        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)

        XCTAssertNotNil(service.lastErrorMessage, "import 成功不得清除上传错误")
        XCTAssertTrue(service.lastErrorIsQuota)
        XCTAssertEqual(service.lastEventDescription, "已接收 iCloud 数据")
    }

    @MainActor
    func testExportSuccessClearsQuotaError() {
        let service = makeService()

        service.processCloudKitEvent(type: .export, endDate: Date(), error: makeWrappedQuotaError())
        XCTAssertNotNil(service.lastErrorMessage)

        service.processCloudKitEvent(type: .export, endDate: Date(), error: nil)

        XCTAssertNil(service.lastErrorMessage, "上传成功才解除错误")
        XCTAssertFalse(service.lastErrorIsQuota)
        XCTAssertNil(service.lastErrorTime)
        XCTAssertNil(defaults.string(forKey: "iCloudSyncStatusService.lastErrorMessage"))
        XCTAssertEqual(service.lastEventDescription, "已上传本机数据")
    }

    @MainActor
    func testOperationCancelledIsNotAFailure() {
        let service = makeService()

        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)
        let successTime = service.lastSyncTime

        let cancelled = NSError(domain: CKErrorDomain, code: CKError.operationCancelled.rawValue)
        service.processCloudKitEvent(type: .export, endDate: Date(), error: cancelled)

        XCTAssertNil(service.lastErrorMessage, "系统取消不算失败")
        XCTAssertEqual(service.lastSyncTime, successTime)
        XCTAssertTrue(service.errorHistory.isEmpty)
    }

    @MainActor
    func testOtherExportFailureRecordsRawMessage() {
        let service = makeService()

        let networkError = NSError(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)
        service.processCloudKitEvent(type: .export, endDate: Date(), error: networkError)

        XCTAssertEqual(service.lastEventDescription, "本机数据上传失败")
        XCTAssertFalse(service.lastErrorIsQuota)
        XCTAssertNotNil(service.lastErrorMessage)
        XCTAssertEqual(service.errorHistory.first?.ckErrorCode, CKError.networkUnavailable.rawValue)
    }

    // MARK: - 重启恢复：错误不因 App 重启丢失

    @MainActor
    func testErrorStateSurvivesRelaunch() throws {
        let first = makeService()
        first.processCloudKitEvent(type: .export, endDate: Date(), error: makeWrappedQuotaError())
        let failedAt = try XCTUnwrap(first.lastErrorTime)

        // 同一份 defaults 新建实例 = App 重启后
        let relaunched = ICloudSyncStatusService(defaults: defaults)

        XCTAssertTrue(relaunched.lastErrorIsQuota)
        XCTAssertEqual(relaunched.lastErrorMessage, "iCloud 空间已满，本机数据未上传")
        XCTAssertEqual(relaunched.lastErrorTime, failedAt)
        XCTAssertEqual(relaunched.lastEventDescription, "本机数据上传失败")
        XCTAssertEqual(relaunched.errorHistory.count, 1)
        XCTAssertNotNil(relaunched.syncStatusDetailText.range(of: "最近同步失败"))
    }

    // MARK: - 进行中事件

    @MainActor
    func testInProgressEventOnlyUpdatesProgressText() {
        let service = makeService()

        service.processCloudKitEvent(type: .export, endDate: nil, error: nil)

        XCTAssertTrue(service.isSyncing)
        XCTAssertEqual(service.lastEventDescription, "正在上传本机数据")
        XCTAssertNil(service.lastSyncTime)
        XCTAssertNil(service.lastErrorMessage)
    }
}
