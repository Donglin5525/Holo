//
//  PromptEditorView.swift
//  Holo
//
//  Prompt 编辑器页面
//  查看、编辑、测试单个 Prompt 模板
//

import SwiftUI

struct PromptEditorView: View {

    @Environment(\.dismiss) private var dismiss
    private let promptType: PromptManager.PromptType

    @State private var editedContent = ""
    @State private var initialContent = ""
    @State private var variablePreview: [String: String] = [:]
    @State private var isCustomized = false
    @State private var showResetConfirmation = false
    @State private var showTestSheet = false
    @State private var showSavedFeedback = false
    @State private var feedbackMessage = "Prompt 已保存"

    init(promptType: PromptManager.PromptType) {
        self.promptType = promptType
    }

    private var hasUnsavedChanges: Bool { editedContent != initialContent }

    private var canSave: Bool {
        !editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                infoCard
                editorSection
                variablePreviewSection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, HoloSpacing.xl)
        }
        .background(Color.holoBackground)
        .navigationTitle(promptType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        showTestSheet = true
                    } label: {
                        Label("测试 Prompt", systemImage: "paperplane")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedFeedback {
                savedFeedbackView
                    .padding(.bottom, HoloSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("恢复默认", isPresented: $showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                reset()
            }
        } message: {
            Text("将清除自定义内容，恢复为系统默认 Prompt。确定？")
        }
        .sheet(isPresented: $showTestSheet) {
            PromptTestSheet(
                promptType: promptType,
                promptContent: editedContent
            )
        }
        .onAppear {
            loadPrompt()
        }
    }

    // MARK: - 信息卡片

    private var infoCard: some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: isCustomized ? "pencil.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(isCustomized ? .holoPrimary : .holoTextSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(isCustomized ? "已自定义" : "使用默认")
                    .font(.holoCaption)
                    .foregroundColor(isCustomized ? .holoPrimary : .holoTextSecondary)

                if hasUnsavedChanges {
                    Text("有未保存的修改")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    // MARK: - 编辑区

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("模板内容")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            TextEditor(text: $editedContent)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 280)
                .padding(HoloSpacing.sm)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )

            HStack {
                Spacer()
                Button {
                    if canSave {
                        save()
                    }
                } label: {
                    Label(showSavedFeedback ? "已保存" : "保存", systemImage: showSavedFeedback ? "checkmark" : "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, HoloSpacing.sm)
                    .background(canSave ? Color.holoPrimary : Color.gray.opacity(0.3))
                    .cornerRadius(HoloRadius.md)
                }
                .disabled(!canSave)
            }
        }
    }

    // MARK: - 变量预览

    private var variablePreviewSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.holoTextSecondary)
                Text("变量预览")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            ForEach(Array(variablePreview.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                HStack {
                    Text(key)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    Text("→")
                        .foregroundColor(.holoTextSecondary)
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    private var savedFeedbackView: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.holoSuccess)
            Text(feedbackMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextPrimary)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
    }

    private func loadPrompt() {
        let content = PromptManager.shared.loadRawTemplate(promptType)
        editedContent = content
        initialContent = content
        variablePreview = PromptManager.currentVariableValues()
        isCustomized = PromptManager.shared.isCustomized(promptType)
    }

    private func save() {
        PromptManager.shared.saveCustomPrompt(promptType, content: editedContent)
        initialContent = editedContent
        isCustomized = true
        showSaveFeedback(message: "Prompt 已保存")
    }

    private func reset() {
        PromptManager.shared.resetCustomPrompt(promptType)
        let content = PromptManager.shared.loadRawTemplate(promptType)
        editedContent = content
        initialContent = content
        isCustomized = false
        showSaveFeedback(message: "已恢复默认", messageDuration: 1.2)
    }

    private func showSaveFeedback(message: String, messageDuration: TimeInterval = 1.5) {
        feedbackMessage = message
        withAnimation(.easeOut(duration: 0.18)) {
            showSavedFeedback = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(messageDuration * 1_000_000_000))
            withAnimation(.easeIn(duration: 0.18)) {
                showSavedFeedback = false
            }
        }
    }
}
