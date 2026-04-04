//
//  PromptTestSheet.swift
//  Holo
//
//  Prompt 测试弹窗
//  输入测试文本，发送到 LLM 查看响应
//

import SwiftUI

struct PromptTestSheet: View {

    @ObservedObject var viewModel: PromptEditorViewModel
    @Environment(\.dismiss) private var dismiss

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
                TextField("输入测试文本，如：午饭花了35", text: $viewModel.testInput)
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
                    Task { await viewModel.runTest() }
                } label: {
                    if viewModel.isTesting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14))
                    }
                }
                .foregroundColor(.holoPrimary)
                .disabled(viewModel.isTesting || viewModel.testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - 结果区

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("响应结果")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            if viewModel.isTesting {
                HStack {
                    Spacer()
                    ProgressView("请求中...")
                    Spacer()
                }
                .padding(HoloSpacing.lg)
            } else if let error = viewModel.testError {
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
            } else if let result = viewModel.testResult {
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
}
