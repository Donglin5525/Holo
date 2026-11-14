//
//  GoalSettingsSheet.swift
//  Holo
//
//  目标设置面板（2026-11-13 目标界面减法重设计五字段新家，S2 落地 S5 接线）
//  说明/期望结果/动机/图标/AI 上下文从 GoalEditForm 移出后落在这里；
//  领域行按规格 v3「详情页设置里可改」补入（创建表单不再让用户选领域）；
//  GoalSettingsSheet 只管字段 UI，GoalSettingsEditSheet 负责从 goal 预填、
//  保存走 GoalRepository 更新链路（02-产品实施方案 §4.4）。
//

import SwiftUI

struct GoalSettingsSheet: View {
    /// 面板字段直接读写 GoalDraft；allowAIContext 由调用方持有并负责落库
    @Binding var draft: GoalDraft
    @Binding var allowAIContext: Bool
    let onClose: () -> Void
    let onSave: () -> Void

    @State private var showIconPicker = false
    @State private var showDomainPicker = false

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "目标设置"),
            onClose: onClose,
            primaryTitle: String(localized: "保存"),
            primaryAction: onSave,
            primaryActionColor: GoalJourneyStyle.action,
            footerBackground: GoalJourneyStyle.sheetFooterCream
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    summaryField
                    desiredOutcomeField
                    motivationField
                    domainRow
                    iconRow
                    aiContextCard
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showIconPicker) {
            EmojiIconPickerSheet(currentIcon: draft.iconEmoji ?? draft.domain.defaultEmoji) { emoji in
                draft.iconEmoji = emoji
            }
        }
        .sheet(isPresented: $showDomainPicker) {
            GoalDomainPickerSheet(current: draft.domain) { domain in
                draft.domain = domain
            }
        }
    }

    // MARK: - 说明 / 期望结果 / 动机（自 GoalEditForm 迁移，容器换模块字段语言）

    private var summaryField: some View {
        GoalJourneyField(title: String(localized: "说明")) {
            TextField(String(localized: "想补充的背景"), text: summaryBinding, axis: .vertical)
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1...3)
        }
    }

    private var desiredOutcomeField: some View {
        GoalJourneyField(title: String(localized: "期望结果")) {
            TextField(String(localized: "做到什么样算圆满"), text: desiredOutcomeBinding, axis: .vertical)
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1...3)
        }
    }

    private var motivationField: some View {
        GoalJourneyField(title: String(localized: "动机")) {
            TextField(String(localized: "为什么想做这件事"), text: motivationBinding, axis: .vertical)
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1...3)
        }
    }

    private var summaryBinding: Binding<String> {
        Binding(
            get: { draft.summary ?? "" },
            set: { draft.summary = $0.isEmpty ? nil : $0 }
        )
    }

    private var desiredOutcomeBinding: Binding<String> {
        Binding(
            get: { draft.desiredOutcome ?? "" },
            set: { draft.desiredOutcome = $0.isEmpty ? nil : $0 }
        )
    }

    private var motivationBinding: Binding<String> {
        Binding(
            get: { draft.motivation ?? "" },
            set: { draft.motivation = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - 领域（规格 v3：表单不选、AI 认领，详情页设置里可改）

    /// 领域行：14pt 次文字标签 + 当前值（领域色圆点 + 名称）+ chevron，
    /// 行样式与 GoalEditForm 的选择行（数据来源/期限）同构
    private var domainRow: some View {
        Button {
            showDomainPicker = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Text(String(localized: "领域"))
                    .goalJourneyText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    Circle()
                        .fill(draft.domain.badgeColor)
                        .frame(width: 8, height: 8)
                    Text(draft.domain.displayName)
                        .goalJourneyText(.body)
                        .foregroundStyle(Color.holoToolText)
                }
                .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 图标（自 GoalEditForm 迁移；「默认/恢复默认」文案已随减法删除）

    private var iconRow: some View {
        Button {
            showIconPicker = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Text(draft.iconEmoji ?? draft.domain.defaultEmoji)
                    .font(.system(size: 22))
                    .frame(width: 40, height: 40)
                    .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                Text("图标")
                    .goalJourneyText(.row)
                    .foregroundStyle(Color.holoToolText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - AI 上下文（自 GoalManualCreateSheet 迁移）

    private var aiContextCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(GoalJourneyStyle.action)
                    .frame(width: 24, height: 24)
                Text("AI 上下文")
                    .goalJourneyText(.body)
                    .foregroundStyle(Color.holoToolText)
                Spacer()
            }
            Toggle(isOn: $allowAIContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许 HoloAI 参考此目标")
                        .holoText(.supporting)
                        .foregroundColor(.holoToolText)
                    Text("HoloAI 会基于此目标给出更精准的建议")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
            .tint(GoalJourneyStyle.action)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
    }
}

// MARK: - 领域选择器（规格 v3：七项固定枚举，选中态用模块行动色）

/// 领域选择 sheet：内联七项列表，图标块与列表卡同构（领域色 12% 底 + 默认 emoji），
/// 选中项名称与对勾用模块行动色标记（R6：不再用领域色/系统蓝，全页一个橙）；选完即关
private struct GoalDomainPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: GoalDomain
    let onSelect: (GoalDomain) -> Void

    var body: some View {
        HoloSheetScaffold(title: String(localized: "选择领域"), onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.sm) {
                    ForEach(GoalDomain.allCases) { domain in
                        domainRow(domain)
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium])
    }

    private func domainRow(_ domain: GoalDomain) -> some View {
        let isSelected = domain == current
        return Button {
            onSelect(domain)
            dismiss()
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Text(domain.defaultEmoji)
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
                    .background(domain.badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Text(domain.displayName)
                    .goalJourneyText(.row)
                    .foregroundStyle(isSelected ? GoalJourneyStyle.action : Color.holoToolText)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GoalJourneyStyle.action)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 接线（S5）

/// 目标设置面板接线壳：从 goal 预填字段，保存走 GoalRepository。
/// 文字字段清空=不修改（updateFields 单层可选语义，与「编辑目标」一致）；
/// 图标清空=恢复领域默认 emoji（iconEmoji 双层可选传 nil）；
/// 领域可在此面板改（规格 v3「详情页设置里可改」）——draft.domain 从 goal 预填，
/// 未动=原值原样回写，改了=新值落库（创建表单的「AI 认领」只发生在新建时）
struct GoalSettingsEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repository = GoalRepository.shared
    let goal: Goal

    @State private var draft: GoalDraft
    @State private var allowAIContext: Bool
    @State private var isSaving = false
    @State private var saveError: String?

    init(goal: Goal) {
        self.goal = goal
        self._draft = State(initialValue: GoalEditForm.draft(from: goal))
        self._allowAIContext = State(initialValue: goal.allowAIContext)
    }

    var body: some View {
        GoalSettingsSheet(
            draft: $draft,
            allowAIContext: $allowAIContext,
            onClose: { dismiss() },
            onSave: { save() }
        )
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        isSaving = true
        DispatchQueue.main.async {
            do {
                try repository.updateFields(
                    goal,
                    summary: draft.summary,
                    domain: draft.domain,
                    iconEmoji: draft.iconEmoji,
                    desiredOutcome: draft.desiredOutcome,
                    motivation: draft.motivation
                )
                if allowAIContext != goal.allowAIContext {
                    try repository.updateAIContext(goal, allow: allowAIContext)
                }
                GoalNotificationService.broadcastGoalDataChange()
                HapticManager.success()
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
