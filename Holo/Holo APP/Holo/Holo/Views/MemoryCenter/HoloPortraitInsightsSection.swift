//
//  HoloPortraitInsightsSection.swift
//  Holo
//
//  Phase 3（修订）：记忆中心「Holo 眼中的我 · 动态画像与跨模块洞察」视图模块。
//  严格按分段语义分流（2026-11-20 东林真机验收反馈）：
//  - `.confirmed`（「已记住」分段）：只展示已确立的画像，不挂「准/不准」审核按钮；
//  - `.pendingReview`（「值得确认」分段）：承接所有推测态画像/跨模块洞察与待求证轻追问，
//    由用户一键「准（记住）」或「不准（永久拉黑）」。
//

import SwiftUI

struct HoloPortraitInsightsSection: View {
    enum Mode {
        case confirmed
        case pendingReview
    }

    let mode: Mode
    @Binding var store: PortraitStore
    let onOpenChat: () -> Void
    var onSwitchToWorthConfirming: (() -> Void)? = nil

    @State private var isSynthesizing = false
    @State private var statusBanner: String?
    @State private var pendingRejectEntry: PortraitEntry?

    private var targetConfidence: PortraitConfidence {
        mode == .confirmed ? .confirmed : .inferred
    }

    private var crossDomainInsights: [PortraitEntry] {
        store.entries(in: .crossDomainInsight, confidenceFilter: targetConfidence)
    }

    private var profileDimensions: [PortraitDimension] {
        [.identity, .recentState, .longTermPattern, .preference]
    }

    private var hasSectionContent: Bool {
        let hasEntries = PortraitDimension.allCases.contains {
            !store.entries(in: $0, confidenceFilter: targetConfidence).isEmpty
        }
        if mode == .pendingReview {
            return hasEntries || !store.clarifications.isEmpty
        }
        return hasEntries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            headerRow

            if let banner = statusBanner {
                HStack(spacing: 8) {
                    Text(banner)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if mode == .confirmed && store.pendingReviewCount > 0, let onSwitch = onSwitchToWorthConfirming {
                        Button("去确认") {
                            onSwitch()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.holoToolAction)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            if !hasSectionContent {
                emptyStateCard
            } else {
                if !crossDomainInsights.isEmpty {
                    insightGroupCard(
                        title: "跨模块洞察",
                        icon: "smallcircle.filled.circle",
                        entries: crossDomainInsights,
                        highlighted: true
                    )
                }

                ForEach(profileDimensions, id: \.rawValue) { dim in
                    let items = store.entries(in: dim, confidenceFilter: targetConfidence)
                    if !items.isEmpty {
                        insightGroupCard(
                            title: dim.displayTitle,
                            icon: iconName(for: dim),
                            entries: items,
                            highlighted: false
                        )
                    }
                }

                if mode == .pendingReview,
                   let clarification = store.clarifications.values.sorted(by: { $0.createdAt > $1.createdAt }).first {
                    clarificationCard(clarification)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.md)
    }

    // MARK: - 顶栏

    private var headerRow: some View {
        HStack(alignment: .center, spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .confirmed ? "Holo 眼中的我" : "新发现的画像与洞察")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.holoToolText)
                Text(mode == .confirmed ? "你已确认的跨模块动态画像" : "确认后将进入「已记住」，点不准则永久不再推断")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                Task { await triggerRefresh() }
            } label: {
                HStack(spacing: 4) {
                    if isSynthesizing {
                        ProgressView()
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(isSynthesizing ? "分析中" : "更新洞察")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.holoToolAction)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.holoToolSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .disabled(isSynthesizing)
            .fixedSize()
        }
    }

    // MARK: - 空态提示

    @ViewBuilder
    private var emptyStateCard: some View {
        if mode == .confirmed && store.pendingReviewCount > 0 {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("有 \(store.pendingReviewCount) 条新洞察等你确认")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                    Text("确认后的画像会沉淀在这里，持续让 Holo 更懂你。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                Spacer(minLength: 4)
                if let onSwitch = onSwitchToWorthConfirming {
                    Button("去看看") {
                        onSwitch()
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.holoToolAction)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.holoToolAction.opacity(0.1), in: Capsule())
                    .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolAction.opacity(0.3), lineWidth: 0.8))
        } else if mode == .confirmed {
            VStack(alignment: .leading, spacing: 6) {
                Text("尚未确立动态画像")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                Text("点击右上角「更新洞察」，Holo 会综合你的财务、健康、习惯、想法与目标生成跨模块推测，供你在「值得确认」里挑选记住。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        }
    }

    // MARK: - 分组卡片

    private func insightGroupCard(
        title: String,
        icon: String,
        entries: [PortraitEntry],
        highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.holoToolAction : Color.holoToolTextSecondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
            }

            ForEach(entries) { entry in
                portraitRow(entry)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .strokeBorder(highlighted ? Color.holoToolAction.opacity(0.35) : Color.holoToolBorder, lineWidth: highlighted ? 1 : 0.5)
        )
    }

    private func portraitRow(_ entry: PortraitEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(PortraitTextSanitizer.sanitize(entry.statement))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.holoToolText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if mode == .pendingReview {
                    Text("推测")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.holoToolAction)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.holoToolAction.opacity(0.12), in: Capsule())
                        .fixedSize()
                } else {
                    Menu {
                        Button(role: .destructive) {
                            pendingRejectEntry = entry
                        } label: {
                            Label("不再记住", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .alert(
                        "不再记住这条画像？",
                        isPresented: Binding(
                            get: { pendingRejectEntry?.key == entry.key },
                            set: { if !$0 { pendingRejectEntry = nil } }
                        )
                    ) {
                        Button("取消", role: .cancel) { pendingRejectEntry = nil }
                        Button("不再记住", role: .destructive) {
                            HoloPortraitSynthesisRuntime.rejectEntry(key: entry.key)
                            store = HoloPortraitSynthesisRuntime.loadStore()
                            statusBanner = "已移出「\(entry.statement)」"
                            pendingRejectEntry = nil
                        }
                    } message: {
                        Text("移出后，Holo 不会再使用「\(PortraitTextSanitizer.sanitize(entry.statement))」这条画像。")
                    }
                }
            }

            if !entry.evidenceSummary.isEmpty {
                Text("依据：\(PortraitTextSanitizer.sanitize(entry.evidenceSummary))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 仅在「值得确认」分段展示「准 / 不准」表态按钮
            if mode == .pendingReview {
                HStack(spacing: 8) {
                    Button {
                        HoloPortraitSynthesisRuntime.confirmEntry(key: entry.key)
                        store = HoloPortraitSynthesisRuntime.loadStore()
                        statusBanner = "已记住「\(entry.statement)」"
                    } label: {
                        Text("准，记住")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.holoToolAction)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.holoToolAction.opacity(0.1), in: Capsule())
                    }

                    Button {
                        HoloPortraitSynthesisRuntime.rejectEntry(key: entry.key)
                        store = HoloPortraitSynthesisRuntime.loadStore()
                        statusBanner = "已移出并记住不再推断该项"
                    } label: {
                        Text("不准")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.holoToolInset, in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - 待求证轻卡片（仅「值得确认」分段展示）

    private func clarificationCard(_ item: PortraitClarification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.holoToolAction)
                Text("想向你确认一件事")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
            }
            Text(PortraitTextSanitizer.sanitize(item.question))
                .font(.system(size: 13.5))
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    onOpenChat()
                } label: {
                    Text("去聊聊告诉 Holo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.holoToolAction)
                }
                Button {
                    HoloPortraitSynthesisRuntime.rejectEntry(key: item.key)
                    store = HoloPortraitSynthesisRuntime.loadStore()
                } label: {
                    Text("忽略")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func iconName(for dimension: PortraitDimension) -> String {
        switch dimension {
        case .identity: return "person.crop.circle"
        case .longTermPattern: return "repeat"
        case .preference: return "slider.horizontal.3"
        case .recentState: return "waveform.path.ecg"
        case .crossDomainInsight: return "smallcircle.filled.circle"
        }
    }

    private func triggerRefresh() async {
        isSynthesizing = true
        statusBanner = nil
        let result = await HoloPortraitSynthesisRuntime.runIfDue(force: true)
        store = HoloPortraitSynthesisRuntime.loadStore()
        isSynthesizing = false
        if let err = result.errorMessage {
            // 技术报错只进日志，绝不向普通用户暴露 invalidJSON 等程序术语。
            NSLog("[HoloPortraitInsightsSection] 手动更新洞察失败: %@", err)
            statusBanner = "这次分析暂时没成功，请稍后再试"
        } else if let reason = result.skipReason {
            statusBanner = reason
        } else if let report = result.applyReport {
            if mode == .confirmed && store.pendingReviewCount > 0 {
                statusBanner = "发现 \(store.pendingReviewCount) 条新洞察，去「值得确认」看看"
            } else if report.upsertedKeys.isEmpty {
                statusBanner = "当前画像已是最新，暂无新增洞察"
            } else {
                statusBanner = "已更新 \(report.upsertedKeys.count) 条画像与洞察"
            }
        }
    }
}
