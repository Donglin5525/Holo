//
//  GoalDraftReviewView.swift
//  Holo
//
//  目标草案确认看板：编辑、选择任务/习惯、授权、保存
//  使用 Holo 设计系统风格
//

import SwiftUI

struct GoalDraftReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GoalDraft
    @State private var allowAIContext = true
    @State private var showCancelConfirm = false
    @State private var isSaving = false

    let onCancel: () -> Void
    let onSaved: (GoalDraftSaveResult) -> Void

    init(
        draft: GoalDraft,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (GoalDraftSaveResult) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    goalInfoCard
                    if !draft.tasks.isEmpty { tasksCard }
                    if !draft.habits.isEmpty { habitsCard }
                    aiContextCard
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
            .background(Color.holoBackground)
            .navigationTitle("确认目标计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCancelConfirm = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("放弃这次目标计划？", isPresented: $showCancelConfirm, titleVisibility: .visible) {
                Button("放弃", role: .destructive) {
                    onCancel()
                    dismiss()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("未保存的目标计划会丢失。")
            }
            .safeAreaInset(edge: .bottom) {
                bottomActions
            }
        }
    }

    // MARK: - Goal Info Card

    private var goalInfoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // Section header
            sectionHeader(icon: "target", title: "目标信息")

            CardDivider()

            // 标题
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("标题")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标标题", text: $draft.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 说明
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("说明")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标说明（可选）", text: Binding(
                    get: { draft.summary ?? "" },
                    set: { draft.summary = $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 领域
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("领域")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Picker("领域", selection: $draft.domain) {
                    ForEach(GoalDomain.allCases) { domain in
                        HStack(spacing: 6) {
                            Image(systemName: domain.icon)
                            Text(domain.displayName)
                        }
                        .tag(domain)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Tasks Card

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(
                icon: "checklist",
                title: "任务",
                badge: "\(draft.tasks.filter(\.isSelected).count)/\(draft.tasks.count)"
            )

            CardDivider()

            ForEach($draft.tasks) { $task in
                HStack(spacing: HoloSpacing.sm) {
                    Toggle("", isOn: $task.isSelected)
                        .labelsHidden()
                        .tint(.holoPrimary)

                    TextField("任务标题", text: $task.title)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .strikethrough(!task.isSelected, color: .holoTextSecondary)
                }
                .padding(.vertical, HoloSpacing.xs)

                if task.id != draft.tasks.last?.id {
                    CardDivider()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Habits Card

    private var habitsCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(
                icon: "flame",
                title: "习惯",
                badge: "\(draft.habits.filter(\.isSelected).count)/\(draft.habits.count)"
            )

            CardDivider()

            ForEach($draft.habits) { $habit in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    HStack(spacing: HoloSpacing.sm) {
                        Toggle("", isOn: $habit.isSelected)
                            .labelsHidden()
                            .tint(.holoPrimary)

                        TextField("习惯名称", text: $habit.name)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPrimary)
                            .strikethrough(!habit.isSelected, color: .holoTextSecondary)
                    }

                    if habit.isSelected {
                        HStack(spacing: HoloSpacing.md) {
                            Picker("频率", selection: $habit.frequency) {
                                ForEach(HabitFrequency.allCases) { frequency in
                                    Text(frequency.displayName).tag(frequency.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.holoLabel)

                            Stepper("目标 \(habit.targetCount ?? 1) 次", value: Binding(
                                get: { habit.targetCount ?? 1 },
                                set: { habit.targetCount = $0 }
                            ), in: 1...30)
                            .font(.holoLabel)
                        }
                        .foregroundColor(.holoTextSecondary)
                    }
                }
                .padding(.vertical, HoloSpacing.xs)

                if habit.id != draft.habits.last?.id {
                    CardDivider()
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - AI Context Card

    private var aiContextCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            sectionHeader(icon: "sparkles", title: "AI 上下文")

            CardDivider()

            Toggle(isOn: $allowAIContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许 HoloAI 参考此目标")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                    Text("HoloAI 会基于此目标给出更精准的建议")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .tint(.holoPrimary)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                showCancelConfirm = true
            } label: {
                Text("取消")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )
            }

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Text(isSaving ? "保存中" : "确认保存")
                        .font(.holoBody)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.gray.opacity(0.3)
                        : Color.holoPrimary
                )
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoCardBackground)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            if let badge {
                Text(badge)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.12))
                    .cornerRadius(4)
            }
        }
    }

    private func save() {
        isSaving = true
        do {
            let result = try GoalRepository.shared.saveDraft(draft, allowAIContext: allowAIContext)
            onSaved(result)
            dismiss()
        } catch {
            isSaving = false
        }
    }
}
