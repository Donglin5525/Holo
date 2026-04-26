//
//  HoloProfileEditorView.swift
//  Holo
//
//  个人档案编辑器
//  Markdown 文本编辑器 + 大小指示器 + 保存/恢复模板
//

import SwiftUI

struct HoloProfileEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profileService = HoloProfileService.shared
    @State private var editedContent: String = ""
    @State private var showResetConfirmation = false
    @State private var errorMessage: String?

    private var hasUnsavedChanges: Bool {
        editedContent != profileService.profileContent
    }

    private var currentSizeKB: Double {
        Double(editedContent.utf8.count) / 1024.0
    }

    private var sizeLimitKB: Double {
        Double(HoloProfileService.maxFileSize) / 1024.0
    }

    var body: some View {
        VStack(spacing: 0) {
            // 编辑区
            ZStack(alignment: .topLeading) {
                if editedContent.isEmpty {
                    Text("在这里描述你自己...\n\n包括你的角色、生活习惯、沟通偏好等，\nAI 在对话中会参考这些信息。")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPlaceholder)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                TextEditor(text: $editedContent)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.holoTextPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .padding(.horizontal, HoloSpacing.lg)

            // 底部工具栏
            HStack {
                // 大小指示器
                Text(String(format: "%.1f KB / %.0f KB", currentSizeKB, sizeLimitKB))
                    .font(.holoCaption)
                    .foregroundColor(currentSizeKB > sizeLimitKB ? .red : .holoTextSecondary)

                Spacer()

                // 保存按钮
                Button {
                    saveProfile()
                } label: {
                    Text("保存")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            hasUnsavedChanges
                            ? Color.holoPrimary
                            : Color.holoPrimary.opacity(0.3)
                        )
                        .clipShape(Capsule())
                }
                .disabled(!hasUnsavedChanges)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .navigationTitle("个人档案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("恢复默认模板", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .alert("恢复默认模板", isPresented: $showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                resetToTemplate()
            }
        } message: {
            Text("将清空当前内容并恢复为默认模板，此操作不可撤销。")
        }
        .alert("保存失败", isPresented: .constant(errorMessage != nil), actions: {
            Button("确定") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
        .onAppear {
            editedContent = profileService.loadProfile()
        }
    }

    // MARK: - Actions

    private func saveProfile() {
        do {
            try profileService.saveProfile(editedContent)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetToTemplate() {
        editedContent = HoloProfileService.defaultTemplate
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HoloProfileEditorView()
    }
}
