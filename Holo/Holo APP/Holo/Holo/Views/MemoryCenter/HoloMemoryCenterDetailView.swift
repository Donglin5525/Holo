//
//  HoloMemoryCenterDetailView.swift
//  Holo
//
//  「这条记忆」详情页（方案 §3.2 M02；视觉契约 = 原型画面 08/09/12）
//
//  陈述/状态/基本情况/来源依据/操作记录（事件账本驱动）/按桶操作区。
//  操作经 HoloMemoryUserControlService 落库；删除走二次确认弹层。
//

import Combine
import SwiftUI

@MainActor
final class HoloMemoryCenterDetailViewModel: ObservableObject {
    enum DetailState: Equatable {
        case loading
        case loaded(record: HoloMemoryRecord, projection: HoloMemoryManagementProjection, events: [HoloMemoryUserControlEvent])
        case missing(String)   // 不存在/已删除/不在本设备：给具体原因
        case failed
    }

    @Published private(set) var state: DetailState = .loading
    @Published var notice: String?
    @Published var receiptText: String?
    @Published var showDeleteConfirm = false
    @Published var showEditSheet = false

    let recordID: String
    let autoOpenEdit: Bool
    private var service: HoloMemoryUserControlService?

    init(recordID: String, autoOpenEdit: Bool = false) {
        self.recordID = recordID
        self.autoOpenEdit = autoOpenEdit
    }

    func load() async {
        state = .loading
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            guard let record = try await repository.fetch(id: recordID) else {
                state = .missing("这条记忆已不存在——可能已被删除，或还在别的设备上没有同步过来。")
                return
            }
            let controller = try await HoloMemoryRuntime.shared.persistenceController()
            let service = HoloMemoryUserControlService(
                repository: repository,
                eventStore: HoloMemoryControlEventStore(controller: controller)
            )
            self.service = service
            _ = try? await service.reconcileOutstanding()
            let projection = HoloMemoryManagementProjection.project(
                .init(record: record),
                context: HoloMemoryManagementProjectionContext(now: Date())
            )
            let events = (try? await service.eventStore.events(forRecordID: recordID)) ?? []
            state = .loaded(record: record, projection: projection, events: events)
        } catch {
            NSLog("[HoloMemoryDetail] 加载失败: \(String(describing: error))")
            state = .failed
        }
    }

    func perform(_ action: HoloMemoryUserControlAction) async {
        guard case .loaded(let record, let projection, _) = state else { return }
        guard let service else { return }
        do {
            let request = HoloMemoryUserControlRequest(
                operationID: "op-\(UUID().uuidString)",
                recordID: record.id,
                expectedContentVersion: record.recordVersion,
                action: action,
                issuedAt: Date()
            )
            let outcome = try await service.apply(request, projection: projection)
            switch outcome {
            case .applied, .alreadyApplied:
                if case .forget = action { return }   // 删除后详情不复存在，由上层关闭
                receiptText = nil
                showEditSheet = false
                await load()
            case .conflict:
                notice = "这条记忆已有新修改，已为你刷新到最新版本。"
                await load()
            default:
                notice = "没做成：内容没有变化，稍后再试。"
            }
        } catch {
            notice = "暂时没做成，稍后再试一次。"
        }
    }
}

struct HoloMemoryCenterDetailView: View {
    @StateObject private var viewModel: HoloMemoryCenterDetailViewModel
    @Environment(\.dismiss) private var dismiss

    /// autoOpenEdit：从观察行「改一下」直达时自动打开编辑弹层。
    init(recordID: String, autoOpenEdit: Bool = false) {
        _viewModel = StateObject(wrappedValue: HoloMemoryCenterDetailViewModel(
            recordID: recordID, autoOpenEdit: autoOpenEdit
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            content
        }
        .background(Color.holoToolBackground)
        .buttonStyle(.plain)
        .navigationBarBackButtonHidden(true)
        #if canImport(UIKit)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            await viewModel.load()
            if viewModel.autoOpenEdit { viewModel.showEditSheet = true }
        }
        .sheet(isPresented: $viewModel.showEditSheet) {
            if case .loaded(let record, _, _) = viewModel.state {
                HoloMemoryEditView(originalRecord: record) { statement in
                    await viewModel.perform(.correct(statement: statement))
                    return viewModel.notice == nil
                }
            }
        }
    }

    private var navBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .frame(width: 34, height: 34)
                    .background(Color.holoToolSurface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .accessibilityLabel("返回")
            Text("这条记忆")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
                .padding(.leading, 4)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(height: 50)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: HoloSpacing.md) {
                Text("加载失败").holoText(.sectionTitle).foregroundStyle(Color.holoToolText)
                Button("重试") { Task { await viewModel.load() } }
                    .holoText(.body).foregroundStyle(Color.holoToolAction)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing(let reason):
            VStack(spacing: HoloSpacing.sm) {
                Image(systemName: "tr-question-square")
                    .font(.system(size: 30)).foregroundStyle(Color.holoToolTextSecondary)
                Text(reason)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let record, let projection, let events):
            detailBody(record: record, projection: projection, events: events)
        }
    }

    private func detailBody(
        record: HoloMemoryRecord,
        projection: HoloMemoryManagementProjection,
        events: [HoloMemoryUserControlEvent]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(record.displaySummary.isEmpty ? "（内容已删除）" : record.displaySummary)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .lineSpacing(4)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                    .padding(.top, 6)

                HStack(spacing: 6) {
                    ForEach(HoloMemoryRowTags.tags(for: projection), id: \.text) { tag in
                        HoloMemoryTagBadge(tag: tag)
                    }
                }
                .padding(.top, 10)

                if let notice = viewModel.notice {
                    Text(notice)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolWarning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.holoToolWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 12)
                }

                section("基本情况") {
                    kvRow("适用时间", effectiveRangeText(record))
                    kvRow("形成方式", originText(record, projection: projection))
                    kvRow("使用说明", useText(projection))
                }

                section("来源依据") {
                    if record.evidenceRefs.isEmpty {
                        Text(record.state == .tombstoned ? "内容已删除，来源随正文一并清除。" : "暂无来源。")
                            .font(.system(size: 13)).foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(record.evidenceRefs, id: \.id) { evidence in
                            sourceRow(evidence)
                        }
                        if record.sourceDomains.contains(.health) || record.sensitivity == .sensitive {
                            Text("健康相关来源仅保存在本设备。")
                                .font(.system(size: 12)).foregroundStyle(Color.holoToolTextSecondary)
                                .padding(.top, 6)
                        }
                    }
                }

                section("操作记录") {
                    VStack(alignment: .leading, spacing: 6) {
                        if events.isEmpty {
                            Text("本次升级后，操作会记录在这里。")
                                .font(.system(size: 12.5)).foregroundStyle(Color.holoToolTextSecondary)
                        }
                        ForEach(events.reversed(), id: \.id) { event in
                            HStack(spacing: 7) {
                                Text(shortDate(event.occurredAt))
                                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.holoToolTextSecondary)
                                Text(eventText(event))
                                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.holoToolText)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                actionZone(projection: projection)
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $viewModel.showDeleteConfirm) { deleteConfirmSheet }
    }

    // MARK: - 分组小件

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.holoToolTextSecondary)
                .kerning(1.5)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
                .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        }
        .padding(.top, 18)
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(key)
                .font(.system(size: 13)).foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 14)).foregroundStyle(Color.holoToolText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 15)
    }

    private func sourceRow(_ evidence: HoloMemoryEvidenceRef) -> some View {
        HStack(spacing: 11) {
            Image(systemName: evidenceIconName(evidence.sourceDomain))
                .font(.system(size: 15))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 34, height: 34)
                .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(domainTitle(evidence.sourceDomain))记录 · \(shortDate(evidence.observedAt))")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.holoToolText)
                Text("可点进对应记录核对")
                    .font(.system(size: 12.5)).foregroundStyle(Color.holoToolTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    // MARK: - 操作区（投影 allowedActions 唯一判据）

    @ViewBuilder
    private func actionZone(projection: HoloMemoryManagementProjection) -> some View {
        VStack(spacing: 9) {
            if projection.allowedActions.contains(.confirm) {
                primaryButton("符合现在的情况") {
                    Task { await viewModel.perform(.confirm) }
                }
            }
            if projection.allowedActions.contains(.correct) {
                primaryButton(projection.bucket == .history ? "重新核对" : "改一下") {
                    viewModel.showEditSheet = true
                }
            }
            if projection.allowedActions.contains(.restore) {
                primaryButton("重新启用") {
                    Task { await viewModel.perform(.restore) }
                }
            }
            HStack(spacing: 9) {
                if projection.allowedActions.contains(.markOutdated) {
                    secondaryButton("已经过时") { Task { await viewModel.perform(.markOutdated) } }
                }
                if projection.allowedActions.contains(.markInaccurate) {
                    secondaryButton("不准确") { Task { await viewModel.perform(.markInaccurate(reason: nil)) } }
                }
                if projection.allowedActions.contains(.disable) {
                    secondaryButton("不再使用") { Task { await viewModel.perform(.disable) } }
                }
            }
            if projection.allowedActions.contains(.delete) {
                Button {
                    viewModel.showDeleteConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                        Text("删除记忆")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.holoToolError)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("删除记忆")
            }
        }
        .padding(.top, 20)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.holoToolOnAction)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.holoToolAction, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        }
    }

    // MARK: - 删除确认弹层（原型画面 12：三区结构）

    private var deleteConfirmSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.holoToolBorder)
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)
            VStack(spacing: 13) {
                Text("删除这条记忆？")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.holoToolText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    deletePoint("删除后不再用于任何回答，且无法恢复")
                    deletePoint("原始记录（笔记、账单、聊天）不会被删除")
                    deletePoint("Holo 不会用原来的证据自动重建这条理解")
                    deletePoint("如果只是不想影响回答，「不再使用」更合适")
                }
            }
            .padding(.horizontal, 20)
            HStack(spacing: 10) {
                Button("取消") { viewModel.showDeleteConfirm = false }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                Button("删除") {
                    viewModel.showDeleteConfirm = false
                    Task {
                        await viewModel.perform(.forget)
                        dismiss()
                    }
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .background(Color.holoToolBackground)
        .presentationDragIndicator(.hidden)
    }

    private func deletePoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Color.holoToolTextSecondary.opacity(0.5))
                .frame(width: 6, height: 6).padding(.top, 7)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineSpacing(3)
        }
    }

    // MARK: - 文案

    private func effectiveRangeText(_ record: HoloMemoryRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日起"
        var text = record.validFrom.map { formatter.string(from: $0) } ?? ""
        if let validTo = record.validTo {
            let toFormatter = DateFormatter()
            toFormatter.locale = Locale(identifier: "zh_CN")
            toFormatter.dateFormat = "M月d日"
            text += " · 适用至 \(toFormatter.string(from: validTo))"
        } else {
            switch record.persistenceClass {
            case .currentState, .phase: text += text.isEmpty ? "当前阶段有效" : " · 当前阶段有效"
            case .durable, .permanentFact: text += text.isEmpty ? "长期有效" : " · 长期有效"
            }
        }
        return text.isEmpty ? "当前阶段" : text
    }

    private func originText(_ record: HoloMemoryRecord, projection: HoloMemoryManagementProjection) -> String {
        switch projection.originLabel {
        case .userConfirmed: return "你确认过 Holo 的理解"
        case .userCorrected: return "你改写过内容"
        case .userAdded: return "你主动添加"
        case .autoFormed: return "Holo 依据记录与对话自动形成"
        }
    }

    private func useText(_ projection: HoloMemoryManagementProjection) -> String {
        switch projection.bucket {
        case .remembered:
            return projection.useLabel == .referenceOnly
                ? "仅作参考进入相关回答，不作为确定事实"
                : "相关回答会参考这条理解"
        case .observing: return "暂不作为事实使用；确认后才会参与回答"
        case .history: return "不再进入现在的回答，仅作回看"
        case .stopped: return "已停用，不影响任何回答"
        case .removed: return "已删除"
        }
    }

    private func eventText(_ event: HoloMemoryUserControlEvent) -> String {
        switch event.kind {
        case .confirmed: return "确认了这条理解"
        case .corrected: return "改写了内容"
        case .outdated: return "标记已过时"
        case .inaccurate: return "标记不准确"
        case .disabled: return "不再使用"
        case .restored: return "重新启用"
        case .forgotten: return "删除了这条记忆"
        case .undo: return "撤销了上一次操作"
        }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func domainTitle(_ domain: HoloMemoryDomain) -> String {
        HoloMemoryCenterViewModel.domainTitle(domain)
    }

    private func evidenceIconName(_ domain: HoloMemoryDomain) -> String {
        switch domain {
        case .finance: return "doc.plaintext"
        case .thought: return "lightbulb"
        case .health: return "figure.run"
        case .habit: return "checkmark.circle"
        case .task: return "checklist"
        case .goal: return "target"
        case .conversation: return "bubble.left"
        case .profile: return "person.crop.circle"
        }
    }
}
