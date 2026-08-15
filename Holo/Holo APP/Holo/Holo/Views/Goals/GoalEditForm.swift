//
//  GoalEditForm.swift
//  Holo
//
//  目标字段编辑表单（可复用）
//  同时服务于「手动创建目标」和「编辑已有目标核心字段」两个场景。
//  本表单只操作 GoalDraft（值类型），保存动作由调用方决定：
//    - 创建模式：调 GoalRepository.saveDraft
//    - 编辑模式：调 GoalRepository.updateFields
//

import SwiftUI

struct GoalEditForm: View {
    @Binding var draft: GoalDraft

    /// 截止日期用 Date 驱动 DatePicker，与 draft.deadlineText("yyyy-MM-dd") 双向同步
    @State private var deadlineDate: Date

    @State private var showIconPicker = false

    init(draft: Binding<GoalDraft>) {
        self._draft = draft
        let parsed = GoalEditForm.parseDeadlineText(draft.wrappedValue.deadlineText)
        self._deadlineDate = State(initialValue: parsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
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

            // 图标
            HStack(spacing: HoloSpacing.md) {
                Button {
                    showIconPicker = true
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        Text(draft.iconEmoji ?? draft.domain.defaultEmoji)
                            .font(.system(size: 22))
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .fill(Color.holoBackground)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("图标")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Text(draft.iconEmoji == nil ? "默认（按领域）" : "已自定义")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .buttonStyle(.plain)

                if draft.iconEmoji != nil {
                    Button {
                        draft.iconEmoji = nil
                    } label: {
                        Text("恢复默认")
                            .font(.holoCaption)
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            .sheet(isPresented: $showIconPicker) {
                EmojiIconPickerSheet(currentIcon: draft.iconEmoji ?? draft.domain.defaultEmoji) { emoji in
                    draft.iconEmoji = emoji
                }
            }

            // 说明
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("说明")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("目标说明（可选）", text: Binding(
                    get: { draft.summary ?? "" },
                    set: { draft.summary = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 期望结果
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("期望结果")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("达成后是什么样", text: Binding(
                    get: { draft.desiredOutcome ?? "" },
                    set: { draft.desiredOutcome = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 动机
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("动机")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                TextField("为什么要这个目标", text: Binding(
                    get: { draft.motivation ?? "" },
                    set: { draft.motivation = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2...4)
                .padding(HoloSpacing.sm)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            }

            // 截止日期
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("截止日期")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                DatePicker(
                    "截止日期",
                    selection: $deadlineDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .onChange(of: deadlineDate) { _, newDate in
                    draft.deadlineText = GoalEditForm.formatDeadline(newDate)
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

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()
        }
    }

    // MARK: - Deadline 转换

    /// "yyyy-MM-dd" → Date，解析失败回退到今天
    static func parseDeadlineText(_ text: String?) -> Date {
        guard let text, !text.isEmpty else { return Date() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? Date()
    }

    /// Date → "yyyy-MM-dd"
    static func formatDeadline(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 从已有 Goal 构造 draft（编辑模式用）
    static func draft(from goal: Goal) -> GoalDraft {
        let deadlineText: String? = {
            guard let deadline = goal.deadline else { return nil }
            return formatDeadline(deadline)
        }()
        return GoalDraft(
            id: goal.id.uuidString,
            title: goal.title,
            summary: goal.summary,
            domain: goal.goalDomain,
            iconEmoji: goal.iconEmoji,
            desiredOutcome: goal.desiredOutcome,
            motivation: goal.motivation,
            deadlineText: deadlineText,
            tasks: [],
            habits: [],
            missingInfoWarnings: []
        )
    }

    /// 构造空 draft（手动创建模式用）
    static func emptyDraft() -> GoalDraft {
        GoalDraft(
            id: UUID().uuidString,
            title: "",
            summary: nil,
            domain: .other,
            iconEmoji: nil,
            desiredOutcome: nil,
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: []
        )
    }
}
