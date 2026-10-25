//
//  ThoughtAIScopeSettingsView.swift
//  Holo
//
//  「AI 分析范围」子页（2026-10-21 标签级 AI 排除方案，原型画板②）
//  有些想法，只想留给自己：标记标签下的想法不参与任何 AI 归类与分析。
//

import SwiftUI

struct ThoughtAIScopeSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var tags: [ThoughtRepository.AIScopeTagInfo] = []
    /// Toggle 的 UI 状态镜像：确认前先亮起，取消则回退；落库统一走 ExclusionService
    @State private var excludedTagIDs: Set<UUID> = []
    @State private var excludedThoughtCount = 0
    @State private var pendingTag: ThoughtRepository.AIScopeTagInfo?
    @State private var showingConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                introSection
                summarySection
                tagSection
            }
            .tint(.holoPrimary)
            .navigationTitle("AI 分析范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .holoSheetShell()
            .alert(
                "把「\(pendingTag?.displayName ?? "")」留给自己？",
                isPresented: $showingConfirm
            ) {
                Button("暂不", role: .cancel) { cancelPending() }
                Button("开启排除") { confirmPending() }
            } message: {
                Text("带「\(pendingTag?.displayName ?? "")」标签的想法将退出所有 AI 处理：不归类主题、不打自动标签、不进洞察与复盘——AI 不会知道它们的存在。\n\n已有的 AI 归类会一并撤下，随时可以关闭恢复。")
            }
        }
        .task { await load() }
    }

    // MARK: - 分区

    /// 说明卡：为什么有这个页面
    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.holoPrimary)
                    .padding(.bottom, 2)
                Text("有些想法，只想留给自己。")
                    .font(.title3.weight(.bold))
                Text("在这里标记的标签，Holo 不会交给 AI——不归类、不分析、不进任何报告。")
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    /// 摘要卡：当前排除规模（给用户看的反馈数字）
    private var summarySection: some View {
        Section {
            LabeledContent {
                Text(summaryText)
                    .font(.holoBody.weight(.semibold))
                    .foregroundStyle(Color.holoPrimary)
            } label: {
                Text("当前范围")
            }
        } footer: {
            Text("AI 看不到这些想法——连「存在多少条」都看不到。")
        }
    }

    private var summaryText: String {
        let tagCount = excludedTagIDs.count
        guard tagCount > 0 else { return "还没有标签被排除" }
        return "已排除 \(tagCount) 个标签 · 覆盖 \(excludedThoughtCount) 条想法"
    }

    /// 标签列表：每行一个开关
    private var tagSection: some View {
        Section {
            if tags.isEmpty {
                Text("还没有可用标签")
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoTextSecondary)
            }
            ForEach(tags) { info in
                tagRow(info)
            }
        } header: {
            Text("标签")
        } footer: {
            Text("关闭排除后，这些想法会重新参与 AI 归类与分析。")
        }
    }

    private func tagRow(_ info: ThoughtRepository.AIScopeTagInfo) -> some View {
        let excluded = excludedTagIDs.contains(info.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("#\(info.displayName)")
                        .font(.holoBody.weight(.semibold))
                        .foregroundStyle(excluded ? Color.holoAIShieldTint : Color.primary)
                    if excluded {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.holoAIShieldTint)
                    }
                }
                Text(excluded
                     ? "\(info.userThoughtCount) 条想法 · AI 不可见"
                     : info.userThoughtCount > 0 ? "\(info.userThoughtCount) 条想法" : "未使用")
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoTextSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { excluded },
                set: { on in handleToggle(info, on: on) }
            ))
            .labelsHidden()
            .accessibilityIdentifier("thoughts.aiScope.tag.\(info.displayName)")
        }
        .contentShape(Rectangle())
    }

    // MARK: - 交互

    private func handleToggle(_ info: ThoughtRepository.AIScopeTagInfo, on: Bool) {
        if on {
            // 先亮起再确认，取消回退；首次语义即「开启需确认」
            excludedTagIDs.insert(info.id)
            pendingTag = info
            showingConfirm = true
        } else {
            excludedTagIDs.remove(info.id)
            Task {
                _ = await ThoughtAIExclusionService.shared.setTagExcluded(tagID: info.id, false)
                await load()
                HoloToastCenter.shared.show(String(localized: "已恢复参与 AI，稍后自动归类"), type: .success)
            }
        }
    }

    private func confirmPending() {
        guard let tag = pendingTag else { return }
        pendingTag = nil
        Task {
            _ = await ThoughtAIExclusionService.shared.setTagExcluded(tagID: tag.id, true)
            await load()
        }
    }

    private func cancelPending() {
        if let tag = pendingTag { excludedTagIDs.remove(tag.id) }
        pendingTag = nil
    }

    // MARK: - 数据

    private func load() async {
        let tags = await MainActor.run { ThoughtRepository().fetchUserTagsForAIScope() }
        let count = await MainActor.run { ThoughtRepository().countExcludedThoughts() }
        self.tags = tags
        self.excludedTagIDs = Set(tags.filter(\.tag.excludeFromAI).map(\.id))
        self.excludedThoughtCount = count
    }
}

private extension ThoughtRepository.AIScopeTagInfo {
    var displayName: String { ThoughtTagNormalizer.displayName(tag.name) }
}
