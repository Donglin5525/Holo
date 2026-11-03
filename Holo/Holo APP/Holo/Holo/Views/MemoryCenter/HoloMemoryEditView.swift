//
//  HoloMemoryEditView.swift
//  Holo
//
//  「改一下」校准弹层（方案 §3.2 M03；视觉契约 = 原型画面 10/11）
//
//  原说法只读对照 + 新说法 + 适用范围如实标注；保存成功才关闭，
//  失败/冲突保留草稿（§2.3 不变量 4）。
//

import SwiftUI

struct HoloMemoryEditView: View {
    let originalRecord: HoloMemoryRecord
    /// 返回 true 表示已落库成功（关闭弹层）；false 保留草稿并显示冲突说明。
    let onSave: @MainActor (_ statement: String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var statement: String = ""
    @State private var isSaving = false
    @State private var showConflict = false
    @State private var conflictDraft: String?

    init(
        originalRecord: HoloMemoryRecord,
        onSave: @escaping @MainActor (_ statement: String) async -> Bool
    ) {
        self.originalRecord = originalRecord
        self.onSave = onSave
        _statement = State(initialValue: originalRecord.displaySummary)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.holoToolBorder)
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(width: 32, height: 32)
                        .background(Color.holoToolSurface, in: Circle())
                        .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                }
                .accessibilityLabel("关闭")
                Spacer()
                Text("改一下")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.holoToolText)
                Spacer()
                Color.clear.frame(width: 32, height: 32)
            }
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showConflict, let draft = conflictDraft {
                        conflictBanner(draft: draft)
                    }
                    formLabel("原来的说法")
                    Text(originalRecord.displaySummary)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineSpacing(3)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 12))

                    formLabel("改为")
                    TextField("用一句你说得出口的话", text: $statement, axis: .vertical)
                        .font(.system(size: 15.5))
                        .lineSpacing(4)
                        .padding(13)
                        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolBorder, lineWidth: 1))

                    formLabel("适用范围")
                    HStack(spacing: 8) {
                        Text("当前阶段（原范围保留）")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.holoToolText)
                        Spacer()
                        Text("到期时间暂不支持修改")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    .padding(12)
                    .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))

                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.top, 2)
                        Text("保存后以你的说法为准：回答、摘要与个人情境同步更新，原来源保留作参考。如果改成了另一件事，Holo 会提示另建一条。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .lineSpacing(3)
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 20)
            }

            Button {
                save()
            } label: {
                Text(isSaving ? "保存中…" : "保存修改")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.holoToolOnAction)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        canSave ? Color.holoToolAction : Color.holoToolInset,
                        in: RoundedRectangle(cornerRadius: HoloRadius.md)
                    )
            }
            .disabled(!canSave || isSaving)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 26)
        }
        .background(Color.holoToolBackground)
        .presentationDragIndicator(.hidden)
    }

    private var canSave: Bool {
        !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && statement.trimmingCharacters(in: .whitespacesAndNewlines)
                != originalRecord.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        isSaving = true
        let draft = statement
        Task { @MainActor in
            let success = await onSave(draft)
            isSaving = false
            if success {
                dismiss()
            } else {
                conflictDraft = draft
                showConflict = true
            }
        }
    }

    private func conflictBanner(draft: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.holoToolWarning)
                    Text("这条记忆已有新修改")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.holoToolWarning)
                }
                Text("另一台设备保存了新版本。你的草稿已保留，先看看新版本再决定，不会覆盖别人的修改。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineSpacing(3)
                HStack(spacing: 8) {
                    Button("查看新版本") { Task { @MainActor in
                        statement = originalRecord.displaySummary
                        showConflict = false
                    } }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .padding(.horizontal, 13).frame(height: 32)
                        .background(Color.holoToolSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                    Button("继续编辑草稿") { showConflict = false }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.holoToolWarning)
                        .padding(.horizontal, 13).frame(height: 32)
                        .background(Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.holoToolWarning.opacity(0.5), lineWidth: 1))
                }
                .padding(.top, 4)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoToolWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.holoToolWarning.opacity(0.3), lineWidth: 1))
            Text("你的草稿：\(draft)")
                .font(.system(size: 12))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.holoToolTextSecondary)
            .kerning(1)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}
