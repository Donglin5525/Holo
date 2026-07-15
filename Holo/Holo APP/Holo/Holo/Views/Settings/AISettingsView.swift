//
//  AISettingsView.swift
//  Holo
//
//  AI 设置页面
//  Provider 选择、API Key、模型配置、连接测试
//

#if DEBUG
import SwiftUI

struct AISettingsView: View {

    @StateObject private var viewModel = AIConfigViewModel()
    @ObservedObject private var memorySettings = HoloMemorySettings.shared
    @ObservedObject private var dataProcessingConsent = HoloAIDataProcessingConsent.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPromptRefreshed = false

    var body: some View {
        Form {
            // Provider 选择
            providerSection

            // 数据处理授权
            dataProcessingConsentSection

            // API Key
            apiKeySection

            // 模型配置
            modelConfigSection

            // 连接测试
            testSection

            // Prompt 模板
            promptSection

            // 学习数据
            mappingSection

            // Agent 深度分析（灰度）
            agentGrayscaleSection

            // 危险操作
            dangerSection

            // Agent 调试（仅内部，flag 保护）
            if HoloAIFeatureFlags.agentDebugModeEnabled {
                agentDebugSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .navigationTitle("AI 设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadConfig()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task {
                        await viewModel.saveConfig()
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    // MARK: - Agent Debug Section
    private var agentDebugSection: some View {
        Section {
            NavigationLink {
                HoloAgentDebugView()
            } label: {
                LabeledContent("Agent 调试入口", value: "内部")
            }
        } header: {
            Text("HoloAI Agent")
        } footer: {
            Text("本地优先 Agent 调试入口，仅在 agentDebugModeEnabled 开启时显示。")
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

    // MARK: - Data Processing Consent Section

    private var dataProcessingConsentSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { dataProcessingConsent.isGranted },
                set: { isOn in
                    if isOn {
                        dataProcessingConsent.grant()
                    } else {
                        dataProcessingConsent.revoke()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("允许 AI 数据处理")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text("允许 Holo 将必要输入、上下文和语音片段通过后端转发给第三方 AI/语音服务处理")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        } header: {
            Text("数据处理授权")
        } footer: {
            Text("关闭后，HoloAI 对话、AI 洞察、自动整理和语音转文字将停止调用外部 AI/语音服务；本地记录、查看和删除数据不受影响。")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("自定义 AI 对话中使用的提示词模板")
                    .font(.caption)
                    .foregroundColor(.holoTextSecondary)

                Button {
                    HoloBackendPromptService.shared.clearCache()
                    PromptManager.shared.clearCache()
                    showPromptRefreshed = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新后端 Prompt 缓存")
                    }
                    .font(.caption)
                    .foregroundColor(.holoPrimary)
                }
                .alert("已刷新", isPresented: $showPromptRefreshed) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("后端 Prompt 缓存已清除，下次生成洞察时将使用最新版本")
                }
            }
        }
    }

    // MARK: - Mapping Section

    private var mappingSection: some View {
        Section {
            NavigationLink {
                CategoryLearnedMappingView()
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("分类学习映射")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text("查看和管理 AI 学习的分类映射")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    let count = CategoryLearnedMapping.listAll().count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.holoPrimary)
                            .clipShape(Capsule())
                    }
                }
            }
        } header: {
            Text("学习数据")
        } footer: {
            Text("AI 根据你的确认自动记录分类映射，下次遇到相同分类时自动匹配")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Agent 深度分析（灰度）

    private var agentGrayscaleSection: some View {
        Section {
            Toggle(isOn: $memorySettings.agentRuntimeEnabled) {
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "cpu")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent 深度分析引擎")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("分析类问题走多轮推理；前台最稳，切后台后会短时间继续尝试")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Toggle(isOn: $memorySettings.agentMemoryGalleryEnabled) {
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记忆长廊展示 Agent 结果")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("深度分析完成后，在长廊展示校验过的结论卡片")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Toggle(isOn: $memorySettings.agentObserverTier2Enabled) {
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "bolt")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台观察自动深挖")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("Observer 发现目标信号后自动启动深度 Agent 跟进")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Toggle(isOn: $memorySettings.agentDebugModeEnabled) {
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "flag")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent 调试入口")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("在设置页显示 Agent 调试入口，可跑 mock job 验证流程")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        } header: {
            Text("Agent 深度分析（灰度）")
        } footer: {
            Text("全部门控默认关闭，不影响线上功能。Agent 运行中建议停留前台；切后台或杀掉 App 后，系统可能收回后台时间，未完成任务会在回到 App 后继续尝试。")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        Section {
            Button("删除 AI 配置", role: .destructive) {
                Task { await viewModel.deleteConfig() }
            }
        }
    }

}
#endif
