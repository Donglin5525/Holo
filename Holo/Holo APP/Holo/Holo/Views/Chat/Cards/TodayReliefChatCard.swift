//
//  TodayReliefChatCard.swift
//  Holo
//
//  「今天减负」HoloAI 候选卡（2026-10-03 实施方案 §12）
//
//  - 同一候选摘要（本地 renderer 重算，不显示模型原句）；
//  - 采用走同一 PlanService：重复点击/重开页面不重复写入（unchanged 幂等）；
//  - 跨日或来源过期只允许「重新整理」，不能执行旧版本（R45）；
//  - 「调整」打开 TodayReliefSheet（同一审阅弹层），不用 ContextPlan 的 launchPlan。
//

import SwiftUI

/// 聊天持久信封：只存展示/恢复候选所需的版本化最小内容（不保存全库快照）。
nonisolated struct TodayReliefCardEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let scopeKey: String
    let payload: HoloTodayPlanPayload
    let newTaskTitle: String?
    let expectedHeads: [UUID]
    let createdAt: Date

    static let schema = 1

    func encode() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> TodayReliefCardEnvelope? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let envelope = try? decoder.decode(TodayReliefCardEnvelope.self, from: data),
              envelope.schemaVersion == schema else { return nil }
        return envelope
    }

    /// 候选是否仍可用于采用：scope 未跨日/换时区且 heads 仍对得上（来源决定性变化须重整理）。
    @MainActor
    var isFresh: Bool {
        let scope = HoloTodayDayScope.current()
        guard scope.scopeKey == scopeKey else { return false }
        let read = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext).currentPlan(scope: scope)
        switch read.state {
        case .noPlan:
            return expectedHeads.isEmpty
        case .active(_, let headIDs):
            return Set(headIDs) == Set(expectedHeads)
        default:
            return false
        }
    }
}

struct TodayReliefChatCard: View {

    let envelope: TodayReliefCardEnvelope
    /// 关闭聊天进 Today（由宿主提供；nil 则不显示该按钮）。
    var onViewToday: (() -> Void)? = nil

    @State private var adoptState: AdoptState = .idle
    @State private var showReliefSheet = false
    @ObservedObject private var planChange = TodayPlanChangeObserver.shared

    enum AdoptState: Equatable {
        case idle
        case adopting
        case done(deferred: Int)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "今天的安排建议"), systemImage: "sun.max")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.holoPrimary)

            Text(Self.summaryText(for: envelope.payload))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !envelope.payload.entries.isEmpty {
                ForEach(Array(envelope.payload.entries.prefix(5).enumerated()), id: \.element.taskID) { index, entry in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.holoPrimary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.holoPrimary.opacity(0.1)))
                        Text(entry.goal.isTaskResult ? "整件事" : "只推进一步")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !envelope.isFresh {
                Label(String(localized: "这份建议已过期（跨天或安排有新变化），重新整理一下。"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            switch adoptState {
            case .idle:
                if envelope.isFresh {
                    actionRow(fresh: true)
                } else {
                    Button {
                        showReliefSheet = true
                    } label: {
                        Text(String(localized: "重新整理"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.holoPrimary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            case .adopting:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 40)
            case .done(let deferredCount):
                Label(deferredCount > 0
                      ? String(localized: "已更新今天，\(deferredCount) 件事今天先放下")
                      : String(localized: "已更新今天的安排"),
                      systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.holoSuccess)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    actionRow(fresh: envelope.isFresh)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoToolBorder, lineWidth: 1))
        .sheet(isPresented: $showReliefSheet) {
            TodayReliefSheet()
                .holoSheetShell()
        }
    }

    private func actionRow(fresh: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                adopt()
            } label: {
                Text(String(localized: "采用这个安排"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary))
            }
            .buttonStyle(.plain)
            .disabled(!fresh)
            .accessibilityIdentifier("todayReliefChatAdoptButton")

            Button {
                showReliefSheet = true
            } label: {
                Text(String(localized: "调整"))
                    .font(.subheadline)
                    .foregroundStyle(Color.holoPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoPrimary.opacity(0.08)))
            }
            .buttonStyle(.plain)

            if let onViewToday {
                Button {
                    onViewToday()
                } label: {
                    Text(String(localized: "看今天"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func adopt() {
        adoptState = .adopting
        Task { @MainActor in
            do {
                let scope = HoloTodayDayScope.current()
                let receipt = try await HoloTodayPlanService.shared.adopt(
                    candidate: HoloTodayPlanCandidate(
                        scope: scope,
                        sourceFingerprint: "",
                        payload: envelope.payload,
                        newTaskTitle: envelope.newTaskTitle
                    ),
                    editedPayload: nil,
                    expectedHeads: envelope.expectedHeads,
                    operationID: UUID().uuidString
                )
                adoptState = .done(deferred: receipt.payload.deferredTaskIDs.count)
                HapticManager.light()
            } catch {
                adoptState = .failed(HoloTodayReliefViewModel.friendlyError(error))
            }
        }
    }

    /// 本地概括 renderer（与弹层同一口径；不显示模型 summary 原句）。
    nonisolated static func summaryText(for payload: HoloTodayPlanPayload) -> String {
        let selected = payload.entries.count
        let deferred = payload.deferredTaskIDs.count
        if selected == 0, deferred > 0 {
            return String(localized: "今天不主动推进，先放下 \(deferred) 件事。")
        }
        if deferred > 0 {
            return String(localized: "保留 \(selected) 件推进，放下 \(deferred) 件。")
        }
        return String(localized: "保留 \(selected) 件今天推进。")
    }
}
