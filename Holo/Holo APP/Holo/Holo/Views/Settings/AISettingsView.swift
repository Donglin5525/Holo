//
//  AISettingsView.swift
//  Holo
//
//  AI 设置页面
//  Provider 选择、API Key、模型配置、连接测试
//

import SwiftUI

struct AISettingsView: View {

    @StateObject private var viewModel = AIConfigViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            // Provider 选择
            providerSection

            // API Key
            apiKeySection

            // 模型配置
            modelConfigSection

            // 连接测试
            testSection

            // Prompt 模板
            promptSection

            // 危险操作
            dangerSection
        }
        .navigationTitle("AI 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    viewModel.saveConfig()
                    dismiss()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section {
            ForEach(AIProviderType.allCases, id: \.self) { provider in
                Button {
                    viewModel.updateProvider(provider)
                } label: {
                    HStack {
                        Text(provider.displayName)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        if viewModel.selectedProvider == provider {
                            Image(systemName: "checkmark")
                                .foregroundColor(.holoPrimary)
                        }
                    }
                }
            }
        } header: {
            Text("选择 AI 服务商")
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        Section {
            SecureField("API Key", text: $viewModel.apiKey)
                .font(.holoBody)
        } header: {
            Text("API Key")
        } footer: {
            Text("API Key 仅存储在设备 Keychain 中，不会上传到任何服务器")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Model Config Section

    private var modelConfigSection: some View {
        Section {
            if viewModel.selectedProvider == .custom {
                TextField("Base URL", text: $viewModel.customBaseURL)
                    .font(.holoBody)
                    .autocapitalization(.none)
                    .keyboardType(.URL)

                TextField("模型名称", text: $viewModel.customModel)
                    .font(.holoBody)
                    .autocapitalization(.none)
            }

            VStack(alignment: .leading) {
                Text("温度：\(String(format: "%.1f", viewModel.temperature))")
                    .font(.holoBody)
                Slider(value: $viewModel.temperature, in: 0...1, step: 0.1)
            }

            Stepper("最大 Token：\(viewModel.maxTokens)", value: $viewModel.maxTokens, in: 256...8192, step: 256)
                .font(.holoBody)
        } header: {
            Text("模型配置")
        }
    }

    // MARK: - Test Section

    private var testSection: some View {
        Section {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    if viewModel.isTesting {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text(viewModel.isTesting ? "测试中..." : "测试连接")
                        .font(.holoBody)
                }
            }
            .disabled(viewModel.isTesting || viewModel.apiKey.isEmpty)

            if let result = viewModel.testResult {
                switch result {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } header: {
            Text("连接测试")
        }
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        Section {
            ForEach(PromptManager.PromptType.allCases, id: \.self) { type in
                NavigationLink {
                    PromptEditorView(promptType: type)
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        Image(systemName: type.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.displayName)
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)

                            Text(type.displayDescription)
                                .font(.system(size: 12))
                                .foregroundColor(.holoTextSecondary)
                        }

                        Spacer()

                        if PromptManager.shared.isCustomized(type) {
                            Text("已自定义")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.holoPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.holoPrimary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        } header: {
            Text("Prompt 模板")
        } footer: {
            Text("自定义 AI 对话中使用的提示词模板")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        Section {
            Button("删除 AI 配置", role: .destructive) {
                viewModel.deleteConfig()
            }
        }
    }
}
