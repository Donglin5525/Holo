//
//  PromptTestSheet.swift
//  Holo
//
//  Prompt 测试弹窗
//  输入测试文本，发送到 LLM 查看响应
//

import SwiftUI

struct PromptTestSheet: View {

    let promptType: PromptManager.PromptType
    let promptContent: String

    @Environment(\.dismiss) private var dismiss
    @State private var testInput = ""
    @State private var testResult: String?
    @State private var testError: String?
    @State private var isTesting = false

    var body: some View {
        NavigationView {
            VStack(spacing: HoloSpacing.md) {
                inputSection
                resultSection
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle("测试 Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 输入区

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("测试输入")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                TextField("输入测试文本，如：午饭花了35", text: $testInput)
                    .font(.holoBody)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, HoloSpacing.sm)
                    .background(Color.holoCardBackground)
                    .cornerRadius(HoloRadius.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )

                Button {
                    Task { await runTest() }
                } label: {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14))
                    }
                }
                .foregroundColor(.holoPrimary)
                .disabled(isTesting || testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - 结果区

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("响应结果")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            if isTesting {
                HStack {
                    Spacer()
                    ProgressView("请求中...")
                    Spacer()
                }
                .padding(HoloSpacing.lg)
            } else if let error = testError {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                .padding(HoloSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(HoloRadius.md)
            } else if let result = testResult {
                ScrollView(showsIndicators: false) {
                    Text(result)
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
            } else {
                Text("输入测试文本后点击发送，查看 LLM 响应")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .cornerRadius(HoloRadius.md)
            }
        }
    }

    private func runTest() async {
        guard !testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testError = "请输入测试文本"
            return
        }

        isTesting = true
        testResult = nil
        testError = nil

        do {
            let config = try await Task.detached {
                try KeychainService.loadAIConfigOffMain()
            }.value

            guard let config, config.isConfigured else {
                testError = "请先在 AI 设置中配置 API Key"
                isTesting = false
                return
            }

            let request = APIRequest(
                baseURL: config.baseURL,
                path: "/chat/completions",
                method: .post,
                headers: [
                    "Authorization": "Bearer \(config.apiKey)",
                    "Content-Type": "application/json"
                ],
                body: ChatCompletionRequest(
                    model: config.model,
                    messages: [
                        .system(promptContent),
                        .user(testInput)
                    ],
                    temperature: config.temperature,
                    maxTokens: config.maxTokens,
                    stream: false
                )
            )

            let response: ChatCompletionResponse = try await APIClient.shared.send(request)

            if let content = response.choices?.first?.message?.content {
                testResult = content
            } else {
                testError = "未收到有效响应"
            }
        } catch {
            testError = error.localizedDescription
        }

        isTesting = false
    }
}
