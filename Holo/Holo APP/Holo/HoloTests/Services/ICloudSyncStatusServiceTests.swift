//
//  ICloudSyncStatusServiceTests.swift
//  HoloTests
//
//  iCloud 同步状态机与错误识别测试：
//  核心断言——事件以错误结束时绝不写「成功」状态（假成功根治）；
//  iCloud 满（quotaExceeded）即使包在 partialFailure 里也要识别出来；
//  上传/下载双向状态各自独立跟踪，任一方向的进度不得盖住另一方向。
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

    // MARK: - 双向状态：上传/下载各自独立跟踪

    @MainActor
    func testExportAndImportTimesTrackedSeparately() {
        let service = makeService()

        service.processCloudKitEvent(type: .export, endDate: Date(), error: nil)

        XCTAssertNotNil(service.lastExportTime)
        XCTAssertNil(service.lastImportTime, "上传成功不得冒充「已接收云端数据」")

        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)

        XCTAssertNotNil(service.lastImportTime)
    }

    @MainActor
    func testDirectionInProgressFlagsAreIndependent() {
        let service = makeService()

        service.processCloudKitEvent(type: .export, endDate: nil, error: nil)
        XCTAssertTrue(service.isUploading)
        XCTAssertFalse(service.isDownloading, "上传进行中不代表下载也在进行")
        XCTAssertTrue(service.isSyncing)

        service.processCloudKitEvent(type: .export, endDate: Date(), error: nil)
        XCTAssertFalse(service.isUploading)
        XCTAssertFalse(service.isSyncing)
    }

    @MainActor
    func testDirectionStatusLinesFourStates() {
        let service = makeService()

        // 初始：从未发生
        XCTAssertEqual(service.exportStatusLine.detail, "尚未上传")
        XCTAssertEqual(service.importStatusLine.detail, "尚未收到云端数据")
        XCTAssertFalse(service.exportStatusLine.hasError)

        // 进行中
        service.processCloudKitEvent(type: .import, endDate: nil, error: nil)
        XCTAssertTrue(service.importStatusLine.isInProgress)
        XCTAssertEqual(service.importStatusLine.detail, "正在接收 iCloud 数据…")

        // 成功
        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)
        XCTAssertFalse(service.importStatusLine.isInProgress)
        XCTAssertTrue(service.importStatusLine.detail.hasPrefix("已接收 · "))
    }

    @MainActor
    func testErrorOnlyAttachesToItsOwnDirectionLine() {
        let service = makeService()

        // 下载成功在先：下载行应保持成功状态
        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)
        let importSuccessDetail = service.importStatusLine.detail

        // 上传失败：错误只挂上传行
        service.processCloudKitEvent(
            type: .export,
            endDate: Date(),
            error: NSError(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)
        )

        XCTAssertTrue(service.exportStatusLine.hasError)
        XCTAssertEqual(service.lastErrorDirection, "export")
        XCTAssertFalse(service.importStatusLine.hasError, "上传的失败不得污染下载行")
        XCTAssertEqual(service.importStatusLine.detail, importSuccessDetail)
    }

    // MARK: - 状态机：失败绝不写成功状态

    @MainActor
    func testExportFailureDoesNotWriteSyncTimeOrSuccessText() throws {
        let service = makeService()

        // 先有一次成功 import，让下载时间有值
        service.processCloudKitEvent(type: .import, endDate: Date(), error: nil)
        let importTime = try XCTUnwrap(service.lastImportTime)

        // iCloud 满导致 export 失败
        service.processCloudKitEvent(type: .export, endDate: Date(), error: makeWrappedQuotaError())

        XCTAssertFalse(service.isSyncing)
        XCTAssertEqual(service.lastImportTime, importTime, "上传失败不得动下载方向的时间")
        XCTAssertNil(service.lastExportTime, "上传失败不得写上传成功时间")
        XCTAssertEqual(service.lastEventDescription, "本机数据上传失败")
        XCTAssertTrue(service.lastErrorIsQuota)
        XCTAssertEqual(service.lastErrorDirection, "export")
        XCTAssertEqual(service.lastErrorMessage, "iCloud 空间已满，本机数据未上传")
        XCTAssertEqual(service.errorHistory.count, 1)
        XCTAssertEqual(service.errorHistory.first?.ckErrorCode, CKError.quotaExceeded.rawValue)

        // 持久化生效
        XCTAssertEqual(defaults.string(forKey: "iCloudSyncStatusService.lastErrorMessage"), "iCloud 空间已满，本机数据未上传")
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncStatusService.lastErrorIsQuota"))
        XCTAssertEqual(defaults.string(forKey: "iCloudSyncStatusService.lastErrorDirection"), "export")
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
    func testExportSuccessClearsAnyDirectionError() {
        let service = makeService()

        // 下载方向的失败
        service.processCloudKitEvent(
            type: .import,
            endDate: Date(),
            error: NSError(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)
        )
        XCTAssertNotNil(service.lastErrorMessage)
        XCTAssertEqual(service.lastErrorDirection, "import")

        // 上传成功是更强的恢复信号：本地积压已对齐服务端，任意方向错误随之解除
        service.processCloudKitEvent(type: .export, endDate: Date(), error: nil)

        XCTAssertNil(service.lastErrorMessage)
        XCTAssertNil(service.lastErrorDirection)
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
        let importTime = service.lastImportTime

        let cancelled = NSError(domain: CKErrorDomain, code: CKError.operationCancelled.rawValue)
        service.processCloudKitEvent(type: .export, endDate: Date(), error: cancelled)

        XCTAssertNil(service.lastErrorMessage, "系统取消不算失败")
        XCTAssertEqual(service.lastImportTime, importTime)
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
        XCTAssertEqual(relaunched.lastErrorDirection, "export")
        XCTAssertEqual(relaunched.lastEventDescription, "本机数据上传失败")
        XCTAssertEqual(relaunched.errorHistory.count, 1)
        // 上传行如实显示失败，不显示「已上传」
        XCTAssertTrue(relaunched.exportStatusLine.hasError)
        XCTAssertTrue(relaunched.exportStatusLine.detail.hasPrefix("上传失败"))
    }

    // MARK: - 旧版本时间戳迁移

    @MainActor
    func testLegacySyncTimeMigratesToBothDirections() {
        let legacy = Date(timeIntervalSinceNow: -3600)
        defaults.set(legacy, forKey: "iCloudSyncStatusService.lastSyncTime")

        let service = makeService()

        // 旧值无法区分方向：两方向都继承旧值（宁可保守，不让老用户误看「数据正在路上」）
        XCTAssertEqual(service.lastExportTime, legacy)
        XCTAssertEqual(service.lastImportTime, legacy)
        // 迁移后新键已落盘，重启不再依赖旧键
        XCTAssertEqual(defaults.object(forKey: "iCloudSyncStatusService.lastExportTime") as? Date, legacy)
    }

    @MainActor
    func testFreshInstallHasNoDirectionTimes() {
        let service = makeService()
        XCTAssertNil(service.lastExportTime)
        XCTAssertNil(service.lastImportTime)
    }

    // MARK: - 首次同步判定：锚定下载事件

    func testInitialSyncPendingPureFunction() {
        // 可用 + 账号正常 + 从未下载 = 首次恢复未完成
        XCTAssertTrue(ICloudSyncStatusService.initialSyncPending(
            isAvailable: true, accountAvailable: true, hasCompletedAnyImport: false
        ))
        // 下载过哪怕一次 = 不再提示「数据正在路上」
        XCTAssertFalse(ICloudSyncStatusService.initialSyncPending(
            isAvailable: true, accountAvailable: true, hasCompletedAnyImport: true
        ))
        // 能力缺失 / 账号不可用 = 不提示
        XCTAssertFalse(ICloudSyncStatusService.initialSyncPending(
            isAvailable: false, accountAvailable: true, hasCompletedAnyImport: false
        ))
        XCTAssertFalse(ICloudSyncStatusService.initialSyncPending(
            isAvailable: true, accountAvailable: false, hasCompletedAnyImport: false
        ))
    }

    @MainActor
    func testSeedUploadAloneDoesNotCompleteInitialSync() {
        let service = makeService()

        // 新设备首装：种子数据上传成功（旧版到这里就把「首次同步」横幅关掉了）
        service.processCloudKitEvent(type: .export, endDate: Date(), error: nil)

        XCTAssertNotNil(service.lastExportTime)
        // 实例级判定依赖账号状态（默认 couldNotDetermine 时恒 false），
        // 语义由纯函数锁定：下载没发生过 = pending 仍成立
        XCTAssertTrue(ICloudSyncStatusService.initialSyncPending(
            isAvailable: true, accountAvailable: true,
            hasCompletedAnyImport: service.lastImportTime != nil
        ))
        // 下载行如实显示「尚未收到」
        XCTAssertEqual(service.importStatusLine.detail, "尚未收到云端数据")
    }

    // MARK: - CloudKit 环境判定（生产库/开发库）

    func testCloudKitEnvironmentByProvisioningProfile() {
        // 无内嵌开发描述文件 = App Store/TestFlight 正式渠道 → 生产库
        XCTAssertEqual(
            CloudKitRuntimeAvailability.environment(hasEmbeddedProvisioningProfile: false),
            .production
        )
        // 有内嵌开发描述文件 = Xcode 安装的开发构建 → 开发库
        XCTAssertEqual(
            CloudKitRuntimeAvailability.environment(hasEmbeddedProvisioningProfile: true),
            .development
        )
    }

    // MARK: - 进行中事件

    @MainActor
    func testInProgressEventOnlyUpdatesProgressText() {
        let service = makeService()

        service.processCloudKitEvent(type: .export, endDate: nil, error: nil)

        XCTAssertTrue(service.isSyncing)
        XCTAssertEqual(service.lastEventDescription, "正在上传本机数据")
        XCTAssertNil(service.lastExportTime)
        XCTAssertNil(service.lastErrorMessage)
    }
}
