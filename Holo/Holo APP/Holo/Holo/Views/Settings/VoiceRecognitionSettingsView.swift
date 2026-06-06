//
//  VoiceRecognitionSettingsView.swift
//  Holo
//
//  语音识别配置页面
//

import SwiftUI

struct VoiceRecognitionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VoiceRecognitionSettingsViewModel()

    var body: some View {
        Form {
            providerSection
            apiKeySection
            modelSection
            testSection
            dangerSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .navigationTitle("语音识别设置")
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

    private var providerSection: some View {
        Section {
            Picker("地域", selection: $viewModel.region) {
                ForEach(VoiceRecognitionRegion.allCases, id: \.self) { region in
                    Text(region.displayName).tag(region)
                }
            }

            HStack {
                Text("服务商")
                Spacer()
                Text("阿里云百炼")
                    .foregroundColor(.holoTextSecondary)
            }
        } header: {
            Text("服务")
        } footer: {
            Text("北京地域使用中国内地百炼 API Key；新加坡地域需要对应国际地域 API Key。")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var apiKeySection: some View {
        Section {
            SecureField("DashScope API Key", text: $viewModel.apiKey)
                .font(.holoBody)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("API Key")
        } footer: {
            Text("API Key 只保存在本机 Keychain。建议不要把 Key 写进代码或聊天记录。")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var modelSection: some View {
        Section {
            TextField("模型", text: $viewModel.model)
                .font(.holoBody)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("语言", text: $viewModel.language)
                .font(.holoBody)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Text("采样率")
                Spacer()
                Text("\(viewModel.sampleRate) Hz")
                    .foregroundColor(.holoTextSecondary)
            }
        } header: {
            Text("模型配置")
        } footer: {
            Text("默认模型为 qwen3-asr-flash-realtime，中文语言代码为 zh。录音会使用 16k 单声道 PCM。")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

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
            .disabled(viewModel.isTesting || viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
        } footer: {
            Text("测试只验证 WebSocket 鉴权与会话配置，不会上传录音。")
                .font(.caption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var dangerSection: some View {
        Section {
            Button("删除语音识别配置", role: .destructive) {
                Task { await viewModel.deleteConfig() }
            }
        }
    }
}
