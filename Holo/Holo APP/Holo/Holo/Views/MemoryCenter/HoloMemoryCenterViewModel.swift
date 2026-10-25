//
//  HoloMemoryCenterViewModel.swift
//  Holo
//
//  「Holo 记忆」管理主页 ViewModel（方案 §3.2 M01 / §11.1）
//
//  只发送管理意图并展示结果：查询、筛选、分段切换；不判定权限——
//  桶/分组/可用操作的唯一口径是 HoloMemoryManagementProjection，
//  本类只把查询契约（ListQuery）套到快照上。
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class HoloMemoryCenterViewModel: ObservableObject {

    // MARK: - 状态（§4.5：失败不得伪装成「0 条」假空态）

    enum LoadState: Equatable {
        case loading
        case loaded(HoloMemoryManagementSnapshot)
        case failed
    }

    enum BucketSelection: Equatable {
        case remembered
        case observing

        var bucket: HoloMemoryManagementBucket {
            switch self {
            case .remembered: return .remembered
            case .observing: return .observing
            }
        }
    }

    enum TimeFilter: String, CaseIterable, Identifiable {
        case all
        case recent
        case longTerm

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "时间"
            case .recent: return "近期"
            case .longTerm: return "长期"
            }
        }

        var timeGroup: HoloMemoryManagementTimeGroup? {
            switch self {
            case .all: return nil
            case .recent: return .recent
            case .longTerm: return .longTerm
            }
        }
    }

    enum OriginFilter: String, CaseIterable, Identifiable {
        case all
        case userConfirmed
        case userCorrected
        case userAdded
        case autoFormed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "形成方式"
            case .userConfirmed: return "你确认过"
            case .userCorrected: return "你纠正过"
            case .userAdded: return "你添加"
            case .autoFormed: return "Holo 推断"
            }
        }

        var origin: HoloMemoryManagementOrigin? {
            switch self {
            case .all: return nil
            case .userConfirmed: return .userConfirmed
            case .userCorrected: return .userCorrected
            case .userAdded: return .userAdded
            case .autoFormed: return .autoFormed
            }
        }
    }

    @Published private(set) var state: LoadState = .loading
    @Published var selectedBucket: BucketSelection = .remembered
    @Published var searchText: String = ""
    @Published var timeFilter: TimeFilter = .all
    @Published var originFilter: OriginFilter = .all
    @Published var domainFilter: HoloMemoryDomain?

    // MARK: - 操作回执（§5.1：行内回执 + 撤销；保存成功才展示成功）

    struct ActionReceipt: Identifiable, Equatable {
        let id = UUID()
        let recordID: String
        let text: String
        let operationID: String
        let contentVersionAfterApply: Int
    }

    @Published var receipt: ActionReceipt?
    /// 非成功路径的行内提示（冲突/被拒/落库失败；条目与草稿不动，§2.3）。
    @Published var actionNotice: String?

    private var controlService: HoloMemoryUserControlService?

    /// 供详情/编辑页复用同一服务实例（同一账本与仓库）。
    func makeControlService() async throws -> HoloMemoryUserControlService {
        if let controlService { return controlService }
        let repository = try await HoloMemoryRuntime.shared.repository()
        let controller = try await HoloMemoryRuntime.shared.persistenceController()
        let service = HoloMemoryUserControlService(
            repository: repository,
            eventStore: HoloMemoryControlEventStore(controller: controller)
        )
        controlService = service
        return service
    }

    // MARK: - 操作执行（预检→事务→回执/提示→刷新）

    @MainActor
    func perform(
        _ action: HoloMemoryUserControlAction,
        on projection: HoloMemoryManagementProjection
    ) async {
        do {
            let service = try await makeControlService()
            // 先收敛崩溃残留，保证账本与记录一致。
            _ = try await service.reconcileOutstanding()
            let request = HoloMemoryUserControlRequest(
                operationID: "op-\(UUID().uuidString)",
                recordID: projection.recordID,
                expectedContentVersion: projection.contentVersion,
                action: action,
                issuedAt: Date()
            )
            let outcome = try await service.apply(request, projection: projection)
            await handle(outcome, action: action, projection: projection)
        } catch {
            NSLog("[HoloMemoryCenter] 操作异常: \(String(describing: error))")
            actionNotice = "暂时没做成，稍后再试一次。"
        }
    }

    /// 撤销回执对应的那笔操作。
    @MainActor
    func undoReceipt() async {
        guard let receipt = receipt else { return }
        do {
            let service = try await makeControlService()
            let request = HoloMemoryUserControlRequest(
                operationID: "op-undo-\(UUID().uuidString)",
                recordID: receipt.recordID,
                expectedContentVersion: receipt.contentVersionAfterApply,
                action: .undo(operationID: receipt.operationID),
                issuedAt: Date()
            )
            let outcome = try await service.apply(request, projection: nil)
            self.receipt = nil
            if outcome.isSuccess {
                await load()
            } else {
                actionNotice = noticeText(for: outcome)
                await load()
            }
        } catch {
            actionNotice = "暂时没做成，稍后再试一次。"
        }
    }

    @MainActor
    private func handle(
        _ outcome: HoloMemoryUserControlOutcome,
        action: HoloMemoryUserControlAction,
        projection: HoloMemoryManagementProjection
    ) async {
        switch outcome {
        case .applied(let newVersion, let undoableID):
            if let undoableID, action != .forget {
                receipt = ActionReceipt(
                    recordID: projection.recordID,
                    text: receiptText(for: action),
                    operationID: undoableID,
                    contentVersionAfterApply: newVersion
                )
            }
            await load()
        case .alreadyApplied:
            await load()
        default:
            // 冲突/被拒/失败：条目与状态不动，给可读解释（§2.3）。
            actionNotice = noticeText(for: outcome)
        }
    }

    private func receiptText(for action: HoloMemoryUserControlAction) -> String {
        switch action {
        case .confirm: return "已确认 · 相关回答会参考这条信息"
        case .correct: return "已改好 · 回答将使用新的说法"
        case .markOutdated: return "已标记过时 · 移入过去的记忆"
        case .markInaccurate: return "已标记不准确 · 不再用于回答"
        case .disable: return "已停用 · 不再影响回答"
        case .restore: return "已重新启用 · 重新校验通过后生效"
        case .forget, .undo: return "已完成"
        }
    }

    private func noticeText(for outcome: HoloMemoryUserControlOutcome) -> String {
        switch outcome {
        case .conflict:
            return "这条记忆已有新修改，先看看最新版本再操作。"
        case .notFound:
            return "这条记忆已不存在，列表已刷新。"
        case .notAllowed(let reason):
            switch reason {
            case .sourceInvalid: return "原记录已删除，这条理解不能这样确认——可改为重新核对。"
            case .prohibitedInference: return "这类推断不支持这样操作。"
            case .unknownDecisionVersion: return "这条记忆的数据版本暂不认识，先不动它。"
            case .recordRemoved: return "这条记忆已被删除。"
            case .actionNotAvailable: return "这个操作在这里不适用。"
            }
        case .persistenceFailed:
            return "保存没成功，内容没丢，稍后再试。"
        case .applied, .alreadyApplied:
            return ""
        }
    }

    /// 供空态区分「自动形成开启/关闭」两种解释（§4.5）；不改设置。
    let automaticMemoryEnabled: Bool
    /// 顶栏「已保存，当前不用于回答」提示的依据（§7.1）。
    let answeringEnabled: Bool

    private let settings: HoloMemorySettings

    init(settings: HoloMemorySettings = .shared) {
        self.settings = settings
        self.automaticMemoryEnabled = settings.automaticMemoryEnabled
        self.answeringEnabled = settings.memoryAssistedAnsweringEnabled
    }

    // MARK: - 读取（不触发萃取、不产生模型调用）

    func load() async {
        state = .loading
        do {
            // 先按事件账本收敛崩溃残留（§11.4），再读取快照。
            let warmupService = try await makeControlService()
            _ = try await warmupService.reconcileOutstanding()
            let repository = try await HoloMemoryRuntime.shared.repository()
            let service = HoloMemoryManagementReadService(repository: repository)
            let snapshot = try await service.loadSnapshot(
                answeringEnabled: settings.memoryAssistedAnsweringEnabled
            )
            state = .loaded(snapshot)
        } catch {
            // 内部错误细节进日志（§8.3），界面只呈现「失败 + 重试」。
            NSLog("[HoloMemoryCenter] 加载失败: \(String(describing: error))")
            state = .failed
        }
    }

    // MARK: - 列表与计数（与快照同一投影）

    private var snapshot: HoloMemoryManagementSnapshot? {
        if case .loaded(let snapshot) = state { return snapshot }
        return nil
    }

    var rememberedCount: Int { snapshot?.summary.remembered ?? 0 }
    var observingCount: Int { snapshot?.summary.observing ?? 0 }

    /// 当前桶（已记住时按时间分组拆两段，§4.1）。
    var currentRows: [HoloMemoryManagementProjection] {
        rows(matching: currentQuery())
    }

    var recentRows: [HoloMemoryManagementProjection] {
        rows(matching: currentQuery(timeGroup: .recent))
    }

    var longTermRows: [HoloMemoryManagementProjection] {
        rows(matching: currentQuery(timeGroup: .longTerm))
    }

    /// 搜索/筛选取自当前分段视图；默认不含过去与停用（§4.3）。
    private func currentQuery(
        timeGroup: HoloMemoryManagementTimeGroup? = nil
    ) -> HoloMemoryManagementListQuery {
        HoloMemoryManagementListQuery(
            bucket: selectedBucket.bucket,
            timeGroup: timeGroup ?? (selectedBucket == .remembered ? timeFilter.timeGroup : nil),
            origin: originFilter.origin,
            domain: domainFilter,
            searchText: searchText.isEmpty ? nil : searchText
        )
    }

    private func rows(matching query: HoloMemoryManagementListQuery) -> [HoloMemoryManagementProjection] {
        guard let snapshot else { return [] }
        return snapshot.applying(query)
    }

    /// 筛选无结果与「没有记忆」是两种状态（§4.3）：有快照但列表空 = 筛选无结果。
    var isFilterActive: Bool {
        timeFilter != .all || originFilter != .all || domainFilter != nil || !searchText.isEmpty
    }

    /// 可选领域（动态，来自快照真实数据）。
    var availableDomains: [HoloMemoryDomain] {
        guard let snapshot else { return [] }
        let domains = Set(snapshot.projections.flatMap { snapshot.sourceDomainsByRecordID[$0.recordID] ?? [] })
        return domains.sorted()
    }

    func resetFilters() {
        timeFilter = .all
        originFilter = .all
        domainFilter = nil
        searchText = ""
    }
}
