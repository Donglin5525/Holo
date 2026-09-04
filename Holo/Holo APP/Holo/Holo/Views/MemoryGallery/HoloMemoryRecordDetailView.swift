//
//  HoloMemoryRecordDetailView.swift
//  Holo
//
//  单条记忆的用户说明、来源与反馈入口。
//

import SwiftUI
import CoreData

enum HoloMemoryRecordDetailChange {
    case updated(HoloMemoryRecord)
    case removed(String)
}

struct HoloMemoryRecordDetailView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var record: HoloMemoryRecord
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showCorrection = false
    @State private var correctionText = ""
    @State private var showForgetConfirmation = false
    @State private var selectedEvidence: HoloMemoryEvidenceRef?
    @State private var liveEvidenceExcerpt: String?

    let onChange: (HoloMemoryRecordDetailChange) -> Void

    init(
        record: HoloMemoryRecord,
        onChange: @escaping (HoloMemoryRecordDetailChange) -> Void
    ) {
        _record = State(initialValue: record)
        self.onChange = onChange
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                summaryCard
                sourceSection
                feedbackSection

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.holoCaption)
                        .foregroundColor(.red)
                }
            }
            .padding(HoloSpacing.lg)
            // iPad 限宽：containerRelativeFrame 按容器全宽定宽会通铺，改背景通铺+内容限宽
            .holoContentColumn(paintsBackground: false)
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationTitle("这条记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showCorrection) {
            correctionSheet
        }
        .sheet(item: $selectedEvidence) { evidence in
            evidencePreviewSheet(evidence)
        }
        .confirmationDialog(
            "不再使用这条记忆？",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("不再使用", role: .destructive) {
                Task { await apply(.noLongerUse) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除当前这条记忆。如果之后出现新的证据，Holo 仍可能重新形成相似记忆。你的原始业务数据不会被删除。")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: HoloMemoryDisplayGroup.group(for: record)?.icon ?? "brain")
                    .foregroundColor(.holoPrimary)
                Text(HoloMemoryDisplayGroup.group(for: record)?.title ?? "记忆")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                if let badge = HoloMemoryFeedbackBadge(decision: record.userDecision) {
                    HoloMemoryFeedbackBadgeView(badge: badge)
                }
            }

            Text(record.displaySummary)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                HoloMemoryUserPresentation.durationTitle(for: record),
                systemImage: HoloMemoryUserPresentation.durationIcon(for: record)
            )
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)

            Text(HoloMemoryUserPresentation.durationExplanation(for: record))
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)

            Text("观察时间：\(HoloMemoryUserPresentation.timeRange(for: record))")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)

            if let status = HoloMemoryUserPresentation.degradedStatus(for: record) {
                Label(status, systemImage: "exclamationmark.circle")
                    .font(.holoCaption)
                    .foregroundColor(.orange)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("查看来源")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Text(HoloMemoryUserPresentation.sourceSummary(for: record))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            if record.evidenceRefs.isEmpty {
                Text("来源暂不可用，这条记忆不会用于 Holo 的回答。")
                    .font(.holoCaption)
                    .foregroundColor(.orange)
            } else {
                ForEach(record.evidenceRefs) { evidence in
                    evidenceRow(evidence)
                }
            }
        }
    }

    @ViewBuilder
    private func evidenceRow(_ evidence: HoloMemoryEvidenceRef) -> some View {
        // 汇总类证据没有单一出处，保持纯展示；其余可点：有详情页的直达，否则弹出处预览。
        if evidence.kind == .aggregateSnapshot {
            evidenceRowContent(evidence)
        } else {
            Button {
                handleEvidenceTap(evidence)
            } label: {
                HStack(alignment: .center, spacing: HoloSpacing.xs) {
                    evidenceRowContent(evidence)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func evidenceRowContent(_ evidence: HoloMemoryEvidenceRef) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: evidenceIcon(evidence.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text("\(evidence.sourceDomain.userFacingName) · \(evidenceTitle(evidence.kind))")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(evidence.observedAt.formatted(.dateTime.month().day()))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            if let summary = evidence.summary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summary)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(3)
            }
        }
        .padding(HoloSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    private func handleEvidenceTap(_ evidence: HoloMemoryEvidenceRef) {
        if let target = HoloMemoryEvidenceRouter.deepLinkTarget(for: evidence) {
            // 跳转前校验原始记录仍存活（不存在或已进回收站都视为已清除，让用户有感知）
            guard isEvidenceSourceAlive(evidence) else {
                HoloToastCenter.shared.show("该记录已被清除", type: .info)
                return
            }
            dismiss()
            DeepLinkState.shared.navigate(to: target)
        } else {
            selectedEvidence = evidence
        }
    }

    /// 可路由证据的 sourceID 是否仍指向一条未删除的原始记录
    private func isEvidenceSourceAlive(_ evidence: HoloMemoryEvidenceRef) -> Bool {
        guard let entityName = HoloMemoryEvidenceRouter.sourceEntityName(for: evidence),
              let sourceID = evidence.sourceID,
              let uuid = UUID(uuidString: sourceID) else { return false }
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", uuid as CVarArg)
        request.fetchLimit = 1
        return ((try? CoreDataStack.shared.viewContext.count(for: request)) ?? 0) > 0
    }

    private func evidencePreviewSheet(_ evidence: HoloMemoryEvidenceRef) -> some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Label(
                        "\(evidence.sourceDomain.userFacingName) · \(evidenceTitle(evidence.kind))",
                        systemImage: evidenceIcon(evidence.kind)
                    )
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)

                    Text(previewBody(for: evidence))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("观察时间：\(evidence.observedAt.formatted(.dateTime.year().month().day()))")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)

                    Text(evidence.kind == .explicitUserStatement
                         ? "这是你在对话里明确表达过的内容，Holo 据此形成了这条记忆。"
                         : "这是 Holo 形成这条记忆时依据的原始记录。")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(HoloSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("记忆出处")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { selectedEvidence = nil }
                }
            }
            .task(id: evidence.id) {
                liveEvidenceExcerpt = nil
                liveEvidenceExcerpt = await HoloMemoryConversationExcerptLookup.excerpt(for: evidence)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 存量证据未保存摘要时按 sourceID 回查原文；查不到才落占位文案。
    private func previewBody(for evidence: HoloMemoryEvidenceRef) -> String {
        if let summary = evidence.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let liveEvidenceExcerpt, !liveEvidenceExcerpt.isEmpty {
            return liveEvidenceExcerpt
        }
        return "这条证据没有留下文字摘要，原始内容可能已被删除。"
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("这条记忆对吗？")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            HStack(spacing: HoloSpacing.sm) {
                feedbackButton("准确", icon: "checkmark", color: .holoSuccess) {
                    Task { await apply(.accurate) }
                }
                feedbackButton("不准确", icon: "xmark", color: .orange) {
                    Task { await apply(.inaccurate) }
                }
            }

            HStack(spacing: HoloSpacing.sm) {
                feedbackButton("纠正", icon: "pencil", color: .holoPrimary) {
                    correctionText = record.displaySummary
                    showCorrection = true
                }
                feedbackButton("不再使用", icon: "eye.slash", color: .red) {
                    showForgetConfirmation = true
                }
            }
        }
        .disabled(isWorking)
        .opacity(isWorking ? 0.6 : 1)
    }

    private func feedbackButton(
        _ title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.holoCaption)
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.sm)
                .background(color.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(.plain)
    }

    private var correctionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                Text("写下更准确的说法")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                TextEditor(text: $correctionText)
                    .font(.holoCaption)
                    .padding(HoloSpacing.sm)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                Text("纠正后，Holo 会优先使用你确认过的版本。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("纠正记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCorrection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await saveCorrection() } }
                        .disabled(correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func apply(_ action: HoloMemoryFeedbackAction) async {
        isWorking = true
        errorMessage = nil
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let service = HoloMemoryFeedbackService(store: repository)
            guard try await service.apply(action, to: record.id) else {
                throw HoloMemoryFeedbackError.recordNotFound
            }
            switch action {
            case .accurate, .inaccurate:
                if let persisted = try await repository.fetch(id: record.id) {
                    record = persisted
                } else {
                    switch action {
                    case .accurate:
                        record.userDecision = .confirmed
                        record.state = .active
                    case .inaccurate:
                        record.userDecision = .rejected
                        record.state = .suppressed
                    case .noLongerUse:
                        break
                    }
                }
                onChange(.updated(record))
            case .noLongerUse:
                onChange(.removed(record.id))
                dismiss()
            }
        } catch {
            errorMessage = "这次操作没有保存成功，请稍后重试。"
        }
        isWorking = false
    }

    @MainActor
    private func saveCorrection() async {
        isWorking = true
        errorMessage = nil
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let service = HoloMemoryFeedbackService(store: repository)
            record = try await service.correct(id: record.id, summary: correctionText)
            onChange(.updated(record))
            showCorrection = false
        } catch HoloMemoryFeedbackError.emptyCorrection {
            errorMessage = "请先写下更准确的内容。"
        } catch {
            errorMessage = "纠正没有保存成功，请稍后重试。"
        }
        isWorking = false
    }

    private func evidenceTitle(_ kind: HoloMemoryEvidenceKind) -> String {
        switch kind {
        case .entityRef: return "具体记录"
        case .aggregateSnapshot: return "一段时间的汇总"
        case .explicitUserStatement: return "你明确说过的内容"
        }
    }

    private func evidenceIcon(_ kind: HoloMemoryEvidenceKind) -> String {
        switch kind {
        case .entityRef: return "doc.text"
        case .aggregateSnapshot: return "chart.bar"
        case .explicitUserStatement: return "person.crop.circle.badge.checkmark"
        }
    }
}
