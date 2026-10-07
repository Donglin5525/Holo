//
//  DeviceIntelligenceIndexView.swift
//  Holo
//
//  设备智能索引状态页（语义图谱 V3 §4.1/§5.3；2026-09-24 方案 §5.4 重做）
//
//  AI 相关状态的唯一可见处：主页面不出现任何索引进度/失败/配额，
//  用户主动进来才看到概括状态。pending=0 不再直接等于「已完成」——
//  区分未授权/未开启/已暂停/整理中/完成/失败可重试，操作含开启、
//  暂停/继续、仅重试失败、重建与删除（§5.3：销毁向量/候选/簇/摘要，
//  不删除想法原文）。
//

import SwiftUI
import CoreData

struct DeviceIntelligenceIndexView: View {

    /// 页面状态快照（从管线与语义库实时读取，不再用 @State 记「已删除」）
    private struct StatusSnapshot {
        var consentGranted = false
        var indexFlag: ThoughtSemanticFeatureFlags.TriState = .off
        var storeAvailable = false
        var stats: ThoughtSemanticStore.IndexStats?
        var eligibleCount = 0
    }

    @State private var snapshot = StatusSnapshot()
    @State private var showDestroyConfirm = false
    @State private var busy = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                statusCard
                explanationCard
                if snapshot.storeAvailable {
                    actionsCard
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.xl)
        }
        .background(Color.holoBackground)
        .navigationTitle(String(localized: "设备智能索引"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadStatus() }
        .alert("删除设备智能索引？", isPresented: $showDestroyConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await destroyIndex() }
            }
        } message: {
            Text("向量、候选关系、主题摘要将全部删除且不可恢复；你的想法原文、主题与标签不受影响。")
        }
    }

    // MARK: - 状态卡（如实区分六种状态）

    private var statusTitle: String {
        if !snapshot.consentGranted { return String(localized: "AI 数据处理未授权") }
        if !snapshot.storeAvailable { return String(localized: "索引未初始化") }
        if snapshot.indexFlag == .off { return String(localized: "索引已暂停") }
        if let stats = snapshot.stats {
            if stats.pendingJobs + stats.runningJobs > 0 {
                return String(localized: "整理中：已索引 \(stats.activeItems) 条，剩 \(stats.pendingJobs) 条待处理")
            }
            if stats.failedJobs > 0 {
                return String(localized: "已索引 \(stats.activeItems) 条，\(stats.failedJobs) 条处理失败")
            }
            return String(localized: "当前已索引 \(stats.activeItems) 条想法")
        }
        return String(localized: "索引开启中")
    }

    private var statusDetail: String {
        if !snapshot.consentGranted {
            return String(localized: "授权撤回后不会处理任何新内容；已建索引保留在本机。")
        }
        if !snapshot.storeAvailable {
            return String(localized: "首次开启或重建后会逐步建立索引。")
        }
        var detail = ""
        if let stats = snapshot.stats {
            if stats.unavailableDone > 0 {
                detail += String(localized: "\(stats.unavailableDone) 条纯图片或空内容不适合处理，已跳过。")
            }
            if let last = stats.lastFinishedAt {
                let formatter = RelativeDateTimeFormatter()
                detail += String(localized: "最近处理：\(formatter.localizedString(for: last, relativeTo: Date()))。")
            }
        }
        if snapshot.indexFlag == .on, snapshot.stats?.pendingJobs == 0, snapshot.eligibleCount > (snapshot.stats?.activeItems ?? 0) + (snapshot.stats?.unavailableDone ?? 0) {
            // 已入队全处理完但仍有无向量的想法（如未授权期间产生）→ 提示可重建范围
            detail += String(localized: "部分想法尚未纳入，可点击「重新核对」补齐。")
        }
        return detail
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("状态")
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextSecondary)
            Text(statusTitle)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            if !statusDetail.isEmpty {
                Text(statusDetail)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
            .fill(Color.holoCardBackground))
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("这个索引是什么")
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextSecondary)
            // 文案按已核实的后端事实收敛（2026-09-24 方案 §3 P1：不写未经核实的「不留副本」）
            Text("Holo 在你的设备上为想法建立语义索引，用来归类主题、找回相关内容。索引数据只存在本机，不上传 iCloud。处理请求时，后端会把必要内容转发给 AI 服务处理，Holo 服务器只记录用量与状态。删除索引不会删除你的想法。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
            .fill(Color.holoCardBackground))
    }

    // MARK: - 操作

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("管理")
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextSecondary)

            if ThoughtSemanticFeatureFlags.automaticEnabled {
                if (snapshot.stats?.failedJobs ?? 0) > 0 {
                    actionButton(title: String(localized: "重试失败项（\(snapshot.stats?.failedJobs ?? 0) 条）"), role: .primary) {
                        if let store = await ThoughtSemanticPipeline.shared.store {
                            try? await store.retryFailedJobs()
                            await ThoughtSemanticPipeline.shared.kickQueue()
                        }
                        await loadStatus()
                    }
                }
                actionButton(title: String(localized: "重新核对全部想法"), role: .secondary) {
                    await ThoughtSemanticChangeFeed.shared.reconcileAllThoughts()
                    await ThoughtSemanticPipeline.shared.kickQueue()
                    await loadStatus()
                }
            }

            Button {
                showDestroyConfirm = true
            } label: {
                Text("删除设备智能索引")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .padding(.top, HoloSpacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
            .fill(Color.holoCardBackground))
    }

    private func actionButton(title: String, role: _ActionRole, action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                await action()
                busy = false
            }
        } label: {
            Text(title)
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(role == .primary ? .white : .holoPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(role == .primary ? Color.holoPrimary.opacity(0.85) : Color.holoPrimary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private enum _ActionRole { case primary, secondary }

    // MARK: - 数据

    @MainActor
    private func loadStatus() async {
        snapshot.consentGranted = HoloAIDataProcessingConsent.shared.isGranted
        snapshot.indexFlag = ThoughtSemanticFeatureFlags.index
        let store = await ThoughtSemanticPipeline.shared.store
        snapshot.storeAvailable = store != nil
        snapshot.stats = nil
        if let store {
            snapshot.stats = try? await store.indexStats()
        }
        // 可索引分母：未删除想法数（纯图/空文合法跳过，由 stats.unavailableDone 体现）
        let context = CoreDataStack.shared.viewContext
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        snapshot.eligibleCount = (try? context.count(for: request)) ?? 0
    }

    @MainActor
    private func destroyIndex() async {
        // 删除即回到未开启态；重新开启走「开启索引」（bootstrap + 全量对账）
        UserDefaults.standard.set(false, forKey: ThoughtSemanticFeatureFlags.automaticKey)
        ThoughtSemanticFeatureFlags.settingsChanged()
        try? await ThoughtSemanticChangeFeed.shared.destroyIndex()
        await loadStatus()
    }
}
