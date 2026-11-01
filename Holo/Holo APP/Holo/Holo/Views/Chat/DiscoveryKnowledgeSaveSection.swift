//
//  DiscoveryKnowledgeSaveSection.swift
//  Holo
//
//  「一个发现」详情页的记忆内联区域（融合契约 §4：一次确认完成保存）。
//  独立叶子 struct（View Weight Guard：新增界面块建独立文件，不内联回宿主）。
//
//  状态：
//  · notEligible → 不渲染（未达记忆门槛时不显示不能兑现的保存按钮）
//  · eligible → 「可以让 Holo 记住：〔准确结论〕 / 用于：〔相关帮助〕 / 确认并记住」
//  · remembered → 「已记住 · 查看或修改」（辅助回答关闭时注明）
//  · unavailable → 简短说明（来源已变化/已限制）
//  保存成功才回执；失败不显示成功、不把「有点像」当补偿确认。
//

import SwiftUI

struct DiscoveryKnowledgeSaveSection: View {
    let findingID: String
    let service: any DiscoveryService
    /// 保存成功/已记住时回调（宿主据此收起「有点像」与保存邀请）
    let onRemembered: (String) -> Void
    /// 「查看或修改」→ 跳记忆中心（路由由宿主接）
    let onOpenMemory: (String) -> Void

    @State private var state: DiscoveryKnowledgeSaveState = .notEligible
    @State private var isSaving = false
    @State private var failureText: String?

    var body: some View {
        content
            .task(id: findingID) {
                let loaded = await service.knowledgeSaveState(for: findingID)
                state = loaded
                if case .remembered(let propositionID, _) = loaded {
                    onRemembered(propositionID)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .notEligible:
            EmptyView()
        case .eligible(let claimID, let preview, let usesDescription):
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("可以让 Holo 记住：")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Text(preview)
                    .holoText(.body)
                    .foregroundStyle(Color.holoToolText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.discovery.detail.memory.preview")
                Text("用于：\(usesDescription)")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failureText {
                    Text(failureText)
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.discovery.detail.memory.failure")
                }
                Button {
                    save(claimID: claimID)
                } label: {
                    Label(isSaving ? "保存中…" : "确认并记住", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoloActionStyle(role: .primary))
                .disabled(isSaving)
                .accessibilityIdentifier("chat.discovery.detail.memory.confirm")
            }
            .padding(HoloSpacing.md)
            .holoSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.discovery.detail.memory")

        case .remembered(let propositionID, let answeringEnabled):
            Button {
                onOpenMemory(propositionID)
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.holoToolSuccess)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(answeringEnabled ? "已记住 · 查看或修改" : "已记住，辅助回答已关闭 · 查看或修改")
                            .holoText(.supporting)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.holoToolText)
                        Text("你确认的理解会出现在 Holo 记忆里")
                            .holoText(.metadata)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.discovery.detail.memory.remembered")

        case .unavailable(let reason):
            Text(reason == "restricted" ? "这条理解已在记忆里被你限制，不再提供保存。" : "来源已变化，暂不能保存这条理解。")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.discovery.detail.memory.unavailable")
        }
    }

    private func save(claimID: String) {
        guard !isSaving else { return }
        isSaving = true
        failureText = nil
        Task {
            let outcome = await service.confirmAndRemember(findingID: findingID, claimID: claimID)
            isSaving = false
            switch outcome {
            case .saved(let propositionID), .alreadySaved(let propositionID):
                let refreshed = await service.knowledgeSaveState(for: findingID)
                withAnimation(HoloAnimation.standard) {
                    state = refreshed
                    if case .remembered = refreshed {} else {
                        state = .remembered(propositionID: propositionID, answeringEnabled: true)
                    }
                }
                onRemembered(propositionID)
            case .conflict(let reason):
                failureText = reason == "sourceChanged"
                    ? "原记录有变化，Holo 需要重新核对后才能保存。"
                    : "这条理解刚有更新，请重新查看后再确认。"
            case .notEligible:
                failureText = "这条观察还没有达到可保存的证据门槛。"
            case .failed:
                failureText = "没保存成功，请稍后再试。"
            }
        }
    }
}
