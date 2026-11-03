//
//  HoloMemoryCenterDetailView.swift
//  Holo
//
//  「这条记忆」详情页（减法版契约 = 原型 ③④⑤）
//
//  默认两段：这句话（大标题 + 一行灰字）+ 依据（原话引用卡 / 为什么这么说）；
//  其余（适用范围/用途/使用记录/控制按钮）收进「更多信息 ▾」，展开仍按六段顺序。
//  规律型统计 = 一句自然语言 +「看数据」展开完整数据；来源行行尾小圆点标异常态；
//  「不对」走「哪里不对？」弹层；操作经 HoloMemoryUserControlService 落库，
//  遗忘走二次确认弹层。
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
    /// 「不对」→「哪里不对？」弹层（减法原型 ⑧）。
    @Published var showInaccurateSheet = false
    /// 逐证据实时核验结果（evidence.id → 来源状态；行尾小圆点据此渲染）。
    @Published private(set) var evidenceStatuses: [String: HoloKnowledgeSourceStatus] = [:]
    /// 证据未存摘要时按 sourceID 回查的现场原文（evidence.id → 原文）。
    @Published private(set) var liveQuoteByEvidenceID: [String: String] = [:]

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
            // 来源实时核验：每条证据给 verified/revised/deleted/unknown（原型 ⑤ 小圆点）。
            // 引用卡缺摘要的同步回查原文，保证引用卡显示的是真原文而非占位。
            let verifier = HoloKnowledgeCoreDataSourceVerifier(
                businessContainer: CoreDataStack.shared.persistentContainer
            )
            var statuses: [String: HoloKnowledgeSourceStatus] = [:]
            var liveQuotes: [String: String] = [:]
            for evidence in record.evidenceRefs {
                statuses[evidence.id] = await verifier.verify(evidence)
                if (evidence.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty,
                   let text = await HoloMemoryEvidenceSourceLookup.liveText(for: evidence) {
                    liveQuotes[evidence.id] = text
                }
            }
            evidenceStatuses = statuses
            liveQuoteByEvidenceID = liveQuotes
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

    /// 「更多信息 ▾」展开态（默认两段，减法原型 ③④）。
    @State private var showsMoreInfo = false
    /// 规律型「看数据」展开态。
    @State private var showsFullStats = false
    /// 不可路由来源的出处弹层（原型 ⑤ 轻弹层）。
    @State private var selectedEvidence: HoloMemoryEvidenceRef?
    @State private var liveEvidenceText: String?

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
        .sheet(isPresented: $viewModel.showInaccurateSheet) {
            HoloMemoryInaccurateFeedbackSheet(
                onCancel: { viewModel.showInaccurateSheet = false },
                onSubmit: { reason, _ in
                    viewModel.showInaccurateSheet = false
                    Task { await viewModel.perform(.markInaccurate(reason: reason)) }
                }
            )
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
                Image(systemName: "questionmark.square.dashed")
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

    // MARK: - 主体（默认两段：这句话 + 依据；其余收进「更多信息 ▾」）

    private func detailBody(
        record: HoloMemoryRecord,
        projection: HoloMemoryManagementProjection,
        events: [HoloMemoryUserControlEvent]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ① 这句话：大标题 + 一行灰字（减法原型 ③④）
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displaySummary.isEmpty ? "（内容已删除）" : record.displaySummary)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.holoToolText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(HoloMemorySourceLine.detailSubline(origin: projection.originLabel, record: record))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, 6)

                if let notice = viewModel.notice {
                    Text(notice)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolWarning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.holoToolWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 12)
                }

                // ② 依据：原话引用卡 / 来源行（可点）或规律型「为什么这么说」
                evidenceSection(record: record)

                // ③ 按钮行：修改（或确认）/ 不对 / ···（减法原型 ③④）
                actionRow(projection: projection)

                // ④ 更多信息 ▾：适用范围 · 用途 · 用过几次 · 暂停 / 遗忘
                moreInfoToggle(projection: projection)
                if showsMoreInfo {
                    moreInfoSections(record: record, projection: projection, events: events)
                }
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $viewModel.showDeleteConfirm) { deleteConfirmSheet }
        .sheet(item: $selectedEvidence) { evidence in
            sourcePreviewSheet(evidence)
        }
    }

    // MARK: - 依据段

    @ViewBuilder
    private func evidenceSection(record: HoloMemoryRecord) -> some View {
        if HoloMemorySourceLine.isRhythm(record) {
            section("为什么这么说") {
                rhythmCard(record)
            }
        } else {
            section("依据") {
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
        }
    }

    /// 规律型：一句自然语言 +「看数据」（展开完整数据）+「在原模块查看」。
    private func rhythmCard(_ record: HoloMemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rhythmSentence(record))
                .font(.system(size: 14))
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    withAnimation(HoloAnimation.standard) { showsFullStats.toggle() }
                } label: {
                    Text(showsFullStats ? "收起数据" : "看数据")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                }
                if let module = moduleLink(record) {
                    Button {
                        dismiss()
                        DeepLinkState.shared.navigate(to: module)
                    } label: {
                        Text("在原模块查看")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.holoToolText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                    }
                }
            }

            if showsFullStats {
                HoloMemoryEvidenceStatsList(data: HoloMemoryEvidenceStatsData(record: record))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 统计翻译成一句自然语言：优先用汇总证据自带的观察摘要，缺则由字段组成。
    private func rhythmSentence(_ record: HoloMemoryRecord) -> String {
        let aggregate = record.evidenceRefs.first { $0.kind == .aggregateSnapshot }
        if let summary = aggregate?.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        var sentence = ""
        if let weeks = HoloMemorySourceLine.aggregateWindowWeeks(record) {
            sentence = "看了最近 \(weeks) 周的记录"
        } else {
            sentence = "看了你的相关记录"
        }
        let count = aggregate?.sampleCount
            ?? record.evidenceRefs.filter { $0.kind != .aggregateSnapshot }.count
        if count > 0 { sentence += "，共 \(count) 条" }
        if !record.counterEvidenceRefs.isEmpty {
            sentence += "，有 \(record.counterEvidenceRefs.count) 次例外已计入"
        }
        return sentence + "。"
    }

    /// 原模块直达（仅财务/任务/习惯有模块级深链；想法/目标/对话无列表页深链则不显示）。
    private func moduleLink(_ record: HoloMemoryRecord) -> DeepLinkTarget? {
        switch record.primaryDomain ?? record.sourceDomains.first {
        case .finance: return .finance
        case .task: return .tasks
        case .habit: return .habits
        default: return nil
        }
    }

    // MARK: - 来源行（引用卡 / 记录行 + 行尾异常小圆点，减法原型 ③⑤）

    /// 明确表达型：原话引用卡 +「查看原话 ›」；记录型：图标行。可路由且原始记录
    /// 存活 → 直达对应模块；不可路由（汇总类/对话原话）→ 出处弹层按域回查原文。
    @ViewBuilder
    private func sourceRow(_ evidence: HoloMemoryEvidenceRef) -> some View {
        let target = HoloMemoryEvidenceRouter.deepLinkTarget(for: evidence)
        let status = viewModel.evidenceStatuses[evidence.id] ?? .verified

        if evidence.kind == .explicitUserStatement {
            quoteRow(evidence, target: target, status: status)
        } else {
            recordRow(evidence, target: target, status: status)
        }
    }

    private func quoteRow(
        _ evidence: HoloMemoryEvidenceRef,
        target: DeepLinkTarget?,
        status: HoloKnowledgeSourceStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("「\(quoteText(evidence))」")
                .font(.system(size: 14))
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoToolAction.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.holoToolAction.opacity(0.3), lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                Text("\(domainTitle(evidence.sourceDomain)) · \(HoloMemorySourceLine.shortDate(evidence.observedAt))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if target != nil {
                    Button {
                        handleSourceTap(evidence, target: target)
                    } label: {
                        Text("查看原话 ›")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.holoToolAction)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if status != .verified {
                    HoloMemorySourceStatusMark(status: status)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { handleSourceTap(evidence, target: target) }
    }

    private func recordRow(
        _ evidence: HoloMemoryEvidenceRef,
        target: DeepLinkTarget?,
        status: HoloKnowledgeSourceStatus
    ) -> some View {
        let rowContent = HStack(spacing: 11) {
            Image(systemName: evidenceIconName(evidence.sourceDomain))
                .font(.system(size: 15))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 34, height: 34)
                .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(domainTitle(evidence.sourceDomain))记录 · \(HoloMemorySourceLine.shortDate(evidence.observedAt))")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(target != nil ? "可点进对应记录核对" : "汇总类来源，无单一出处")
                    .font(.system(size: 12.5)).foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if status != .verified {
                HoloMemorySourceStatusMark(status: status)
            }
            if target != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .contentShape(Rectangle())

        return Button {
            handleSourceTap(evidence, target: target)
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private func handleSourceTap(_ evidence: HoloMemoryEvidenceRef, target: DeepLinkTarget?) {
        if let target {
            // 跳转前校验原始记录仍存活（不存在或已进回收站都视为已清除，让用户有感知）
            guard HoloMemoryEvidenceRouter.isSourceAlive(for: evidence) else {
                HoloToastCenter.shared.show("这条依据的原文已被删除", type: .info)
                return
            }
            dismiss()
            DeepLinkState.shared.navigate(to: target)
        } else {
            selectedEvidence = evidence
        }
    }

    /// 引用文本：证据摘要优先，缺则用回查到的现场原文；都没有说明原文已不可查。
    private func quoteText(_ evidence: HoloMemoryEvidenceRef) -> String {
        if let summary = evidence.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let live = viewModel.liveQuoteByEvidenceID[evidence.id] {
            return live
        }
        return "原始内容已删除"
    }

    // MARK: - 出处弹层（原型 ⑤：原文 + 日期 · 来源 + 返回）

    private func sourcePreviewSheet(_ evidence: HoloMemoryEvidenceRef) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.holoToolBorder)
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            Text("「\(previewBody(evidence))」")
                .font(.system(size: 14.5))
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(domainTitle(evidence.sourceDomain)) · \(HoloMemorySourceLine.shortDate(evidence.observedAt))")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, 10)

            if evidence.kind == .explicitUserStatement {
                Text("这是你在对话里明确表达过的内容，Holo 据此形成了这条理解。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineSpacing(3)
                    .padding(.top, 8)
            }

            Button {
                selectedEvidence = nil
            } label: {
                Text("返回")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.holoToolOnAction)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.holoToolAction, in: RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolBackground)
        .presentationDragIndicator(.hidden)
        .presentationDetents([.medium])
        .task(id: evidence.id) {
            liveEvidenceText = await HoloMemoryEvidenceSourceLookup.liveText(for: evidence)
        }
    }

    /// 存量证据未保存摘要时按 sourceID 回查原文；查不到（已删除/不存在）才落占位文案。
    private func previewBody(_ evidence: HoloMemoryEvidenceRef) -> String {
        if let summary = evidence.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let liveEvidenceText, !liveEvidenceText.isEmpty {
            return liveEvidenceText
        }
        return "原始记录已删除，无法显示当时的原文。"
    }

    // MARK: - 操作区（修改/不对/···；其余收进「更多信息」）

    @ViewBuilder
    private func actionRow(projection: HoloMemoryManagementProjection) -> some View {
        HStack(spacing: 8) {
            if projection.allowedActions.contains(.confirm) {
                primaryButton("符合现在的情况") {
                    Task { await viewModel.perform(.confirm) }
                }
            } else if projection.allowedActions.contains(.correct) {
                primaryButton(projection.bucket == .history ? "重新核对" : "修改") {
                    viewModel.showEditSheet = true
                }
            } else if projection.allowedActions.contains(.restore) {
                primaryButton("重新启用") {
                    Task { await viewModel.perform(.restore) }
                }
            }

            if projection.allowedActions.contains(.markInaccurate) {
                Button {
                    viewModel.showInaccurateSheet = true
                } label: {
                    Text("不对")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(width: 76, height: 46)
                        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                }
                .accessibilityLabel("不对")
            }

            if hasOverflowActions(projection) {
                Menu {
                    if projection.allowedActions.contains(.correct)
                        && !projection.allowedActions.contains(.confirm)
                        && projection.bucket != .history {
                        Button("修改") { viewModel.showEditSheet = true }
                    }
                    if projection.allowedActions.contains(.markOutdated) {
                        Button("已经过时") { Task { await viewModel.perform(.markOutdated) } }
                    }
                    if projection.allowedActions.contains(.disable) {
                        Button("暂停使用") { Task { await viewModel.perform(.disable) } }
                    }
                    if projection.allowedActions.contains(.restore)
                        && !projection.allowedActions.contains(.confirm)
                        && !projection.allowedActions.contains(.correct) {
                        Button("重新启用") { Task { await viewModel.perform(.restore) } }
                    }
                    if projection.allowedActions.contains(.delete) {
                        Button("删除记忆", role: .destructive) { viewModel.showDeleteConfirm = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(width: 36, height: 46)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作")
            }
        }
        .padding(.top, 18)
    }

    /// ··· 菜单是否有项（全空时不渲染空菜单）。
    private func hasOverflowActions(_ projection: HoloMemoryManagementProjection) -> Bool {
        let actions = projection.allowedActions
        if actions.contains(.correct) && !actions.contains(.confirm) && projection.bucket != .history {
            return true
        }
        if actions.contains(.markOutdated) || actions.contains(.disable) || actions.contains(.delete) {
            return true
        }
        if actions.contains(.restore) && !actions.contains(.confirm) && !actions.contains(.correct) {
            return true
        }
        return false
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

    // MARK: - 更多信息 ▾（适用范围 · 用途 · 用过几次 · 暂停 / 遗忘）

    private func moreInfoToggle(projection: HoloMemoryManagementProjection) -> some View {
        Button {
            withAnimation(HoloAnimation.standard) { showsMoreInfo.toggle() }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text(showsMoreInfo ? "更多信息 ▴" : "更多信息 ▾")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Image(systemName: showsMoreInfo ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.7))
                }
                Text("适用范围 · 用途 · 用过几次 · 暂停 / 遗忘")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsMoreInfo ? "收起更多信息" : "展开更多信息")
        .padding(.top, 12)
    }

    @ViewBuilder
    private func moreInfoSections(
        record: HoloMemoryRecord,
        projection: HoloMemoryManagementProjection,
        events: [HoloMemoryUserControlEvent]
    ) -> some View {
        // 六段顺序契约：适用范围 → 用途 → 使用记录 → 控制（减法只是收起，不改顺序）。
        section("适用范围") {
            kvRow("适用时间", effectiveRangeText(record))
            kvRow("形成方式", originText(projection))
        }

        section("用途") {
            Text(useText(projection))
                .font(.system(size: 13.5))
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
        }

        section("用过几次") {
            VStack(alignment: .leading, spacing: 6) {
                if events.isEmpty {
                    Text("本次升级后，操作会记录在这里。")
                        .font(.system(size: 12.5)).foregroundStyle(Color.holoToolTextSecondary)
                }
                ForEach(events.reversed(), id: \.id) { event in
                    HStack(spacing: 7) {
                        Text(HoloMemorySourceLine.shortDate(event.occurredAt))
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.holoToolTextSecondary)
                        Text(eventText(event))
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.holoToolText)
                    }
                }
            }
            .padding(.vertical, 6)
        }

        section("控制") {
            VStack(spacing: 9) {
                if projection.allowedActions.contains(.disable) {
                    secondaryButton("暂停使用") { Task { await viewModel.perform(.disable) } }
                }
                if projection.allowedActions.contains(.markOutdated) {
                    secondaryButton("已经过时") { Task { await viewModel.perform(.markOutdated) } }
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
                if !projection.allowedActions.contains(.disable)
                    && !projection.allowedActions.contains(.delete)
                    && !projection.allowedActions.contains(.markOutdated) {
                    Text("当前状态没有可用的控制操作。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 15)
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
        .padding(.top, 16)
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

    // MARK: - 删除确认弹层（两步确认，契约不变）

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
                    deletePoint("如果只是不想影响回答，「暂停使用」更合适")
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
        let started = record.validFrom.map { formatter.string(from: $0) } ?? ""
        let duration = HoloMemorySourceLine.durationText(record)
        return started.isEmpty ? duration : "\(started) · \(duration)"
    }

    private func originText(_ projection: HoloMemoryManagementProjection) -> String {
        switch projection.originLabel {
        case .userConfirmed: return "你确认过 Holo 的理解"
        case .userCorrected: return "你改写过内容"
        case .userAdded: return "你告诉我的"
        case .autoFormed: return "来自你的记录，Holo 自动整理"
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
