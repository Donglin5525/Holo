//
//  PromptEditorView.swift
//  Holo
//
//  Prompt 编辑器页面
//  查看、编辑、测试单个 Prompt 模板
//

import SwiftUI

struct PromptEditorView: View {

    @StateObject private var viewModel: PromptEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(promptType: PromptManager.PromptType) {
        _viewModel = StateObject(wrappedValue: PromptEditorViewModel(promptType: promptType))
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
        .navigationTitle(viewModel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        viewModel.showResetConfirmation = true
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        viewModel.showTestSheet = true
                    } label: {
                        Label("测试 Prompt", systemImage: "paperplane")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .alert("恢复默认", isPresented: $viewModel.showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                viewModel.reset()
            }
        } message: {
            Text("将清除自定义内容，恢复为系统默认 Prompt。确定？")
        }
        .sheet(isPresented: $viewModel.showTestSheet) {
            PromptTestSheet(viewModel: viewModel)
        }
    }

    // MARK: - 信息卡片

    private var infoCard: some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: viewModel.isCustomized ? "pencil.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(viewModel.isCustomized ? .holoPrimary : .holoTextSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.isCustomized ? "已自定义" : "使用默认")
                    .font(.holoCaption)
                    .foregroundColor(viewModel.isCustomized ? .holoPrimary : .holoTextSecondary)

                if viewModel.hasUnsavedChanges {
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

            TextEditor(text: $viewModel.editedContent)
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
                    if viewModel.canSave {
                        viewModel.save()
                    }
                } label: {
                    Text("保存")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.vertical, HoloSpacing.sm)
                        .background(viewModel.canSave ? Color.holoPrimary : Color.gray.opacity(0.3))
                        .cornerRadius(HoloRadius.md)
                }
                .disabled(!viewModel.canSave)
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

            ForEach(Array(viewModel.variablePreview.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
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
}
