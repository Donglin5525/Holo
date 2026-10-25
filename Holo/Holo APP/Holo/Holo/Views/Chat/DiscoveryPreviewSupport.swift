//
//  DiscoveryPreviewSupport.swift
//  Holo
//
//  「一个发现」G5 预览支撑：MockDiscoveryServiceForPreview 实现全部
//  DiscoveryService 协议面，九态（01 §1 状态表）可切换，供各视图 #Preview
//  与设计走查使用。不进生产链路（真实实现是 G6 的 DiscoveryCoordinator）。
//

import Foundation
import SwiftUI
import Combine

// MARK: - 九态预览行

/// 01 §1 状态表的九行，逐行对应一档（presentationState × settingsDetailState 联动）。
/// 注意协议的 DiscoveryPresentationState 没有 stale/revoked 两个独立 case：
/// 这两行在胶囊侧都映射为「无胶囊」的既有 case（waitingForMaterial / disabled），
/// 细化文案只体现在 settingsDetailState 上——缺口已记录在交付报告。
enum DiscoveryPreviewRow: String, CaseIterable, Identifiable {
    case disabled                  // 默认未开启
    case preparing                 // 首次确认后
    case waitingForMaterial        // 材料不足／无合格候选
    case availableUnread           // 有有效且未看发现（淡橙胶囊）
    case availableRead             // 已看但仍有效（普通胶囊）
    case stale                     // 有效内容过期／来源失效
    case pausedTemporarily         // 网络失败／预算不足
    case revoked                   // 撤权／关闭
    case serverUnsupported         // 后端不支持

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: return "1 默认未开启"
        case .preparing: return "2 首次确认后（正在准备）"
        case .waitingForMaterial: return "3 材料不足／无合格候选"
        case .availableUnread: return "4 有发现·未看"
        case .availableRead: return "5 有发现·已看"
        case .stale: return "6 过期／来源失效"
        case .pausedTemporarily: return "7 网络失败／预算不足"
        case .revoked: return "8 撤权／关闭"
        case .serverUnsupported: return "9 后端不支持"
        }
    }
}

// MARK: - Mock 服务

/// 预览用 DiscoveryService：状态由 previewRow 驱动；enable 可注入计划结果，
/// 反馈/草稿/重置等调用即时生效，方便走查各交互分支。
@MainActor
final class MockDiscoveryServiceForPreview: ObservableObject, DiscoveryService {

    @Published var previewRow: DiscoveryPreviewRow = .availableUnread {
        didSet { apply(row: previewRow) }
    }

    @Published var presentationState: DiscoveryPresentationState = .available(findingID: "finding-preview", viewed: false)
    @Published var settingsDetailState: DiscoverySettingsDetailState = .hasFinding(viewed: false)
    @Published var currentFinding: DiscoveryFindingPresentation?
    @Published var isDetailPresented = false

    /// enable() 的计划返回结果（默认 enabled；走查接管/授权/不支持分支时改这里）
    @Published var plannedEnableOutcome: DiscoveryEnableOutcome = .enabled
    /// submitFeedback / disable / resetFeedbackSuppression 调用留痕（走查断言用）
    @Published var lastFeedbackAction: DiscoveryFeedbackAction?

    init() {
        apply(row: previewRow)
    }

    private func apply(row: DiscoveryPreviewRow) {
        let finding = DiscoveryServicePreviewSamples.finding
        switch row {
        case .disabled:
            presentationState = .disabled
            settingsDetailState = .disabled
            currentFinding = nil
        case .preparing:
            presentationState = .preparing
            settingsDetailState = .preparing
            currentFinding = nil
        case .waitingForMaterial:
            presentationState = .waitingForMaterial
            settingsDetailState = .waitingForMaterial
            currentFinding = nil
        case .availableUnread:
            presentationState = .available(findingID: finding.findingID, viewed: false)
            settingsDetailState = .hasFinding(viewed: false)
            currentFinding = finding
        case .availableRead:
            presentationState = .available(findingID: finding.findingID, viewed: true)
            settingsDetailState = .hasFinding(viewed: true)
            currentFinding = finding
        case .stale:
            presentationState = .waitingForMaterial
            settingsDetailState = .stale
            currentFinding = nil
        case .pausedTemporarily:
            presentationState = .temporarilyUnavailable
            settingsDetailState = .pausedTemporarily
            currentFinding = nil
        case .revoked:
            presentationState = .disabled
            settingsDetailState = .revoked
            currentFinding = nil
        case .serverUnsupported:
            presentationState = .serverUnsupported
            settingsDetailState = .serverUnsupported
            currentFinding = nil
        }
        isDetailPresented = false
    }

    // MARK: DiscoveryService

    func enable(selectedDomains: Set<DiscoverySourceDomain>, confirmTakeoverIfOwnedByOtherDevice: Bool) async -> DiscoveryEnableOutcome {
        // 走查接管分支：第一次返回占用，确认重入后放行
        if case .needsTakeoverConfirmation = plannedEnableOutcome, !confirmTakeoverIfOwnedByOtherDevice {
            return .needsTakeoverConfirmation(ownerDeviceID: "旧设备")
        }
        let outcome = plannedEnableOutcome
        if outcome == .enabled {
            previewRow = .preparing
        }
        return outcome
    }

    func disable() async {
        previewRow = .disabled
    }

    func openFinding() -> DiscoveryFindingPresentation? {
        guard case .available(let findingID, _) = presentationState else { return nil }
        let base = DiscoveryServicePreviewSamples.finding
        let opened = DiscoveryFindingPresentation(
            findingID: findingID, title: base.title, body: base.body,
            citations: base.citations, displayQuotes: base.displayQuotes,
            coverageNote: base.coverageNote, timeRangeText: base.timeRangeText,
            publishedAt: base.publishedAt, expiresAt: base.expiresAt,
            viewed: true, hasCounterEvidenceNote: base.hasCounterEvidenceNote
        )
        currentFinding = opened
        isDetailPresented = true
        return opened
    }

    func submitFeedback(_ action: DiscoveryFeedbackAction) async {
        lastFeedbackAction = action
        if case .inaccurate = action {
            currentFinding = nil
            previewRow = .waitingForMaterial
            isDetailPresented = false
        }
    }

    func buildConversationDraft() -> DiscoveryConversationDraft? {
        DiscoveryConversationDraft(
            findingTitle: DiscoveryServicePreviewSamples.finding.title,
            findingSummary: DiscoveryServicePreviewSamples.finding.body.joined(separator: "\n"),
            sourceScopeDescription: "想法、习惯打卡（9 月 28 日 – 10 月 16 日）",
            suggestedDraftText: "关于「\(DiscoveryServicePreviewSamples.finding.title)」我想聊聊：",
            findingID: DiscoveryServicePreviewSamples.finding.findingID
        )
    }

    func resetFeedbackSuppression() async {
        // 预览行为：清除留痕即可
        lastFeedbackAction = nil
    }

    func refresh() async {}
}

// MARK: - 预览九态切换器（各 #Preview 复用）

/// 悬浮在预览画布顶部的九态切换 Picker；probe 视图在切换后重建。
struct DiscoveryPreviewStatePicker: View {
    @ObservedObject var mock: MockDiscoveryServiceForPreview

    var body: some View {
        Picker("九态", selection: $mock.previewRow) {
            ForEach(DiscoveryPreviewRow.allCases) { row in
                Text(row.label).tag(row)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}
