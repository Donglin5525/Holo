import SwiftUI

struct AIDataProcessingConsentView: View {
    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacyPolicy = false

    var body: some View {
        Form {
            Section {
                Toggle("允许 HoloAI 处理必要数据", isOn: consentBinding)
                    .tint(.holoPrimary)
            } header: {
                Text("AI 数据处理授权")
            } footer: {
                Text("开启后，使用相关 AI 功能所需的问题、想法正文及主题代表片段、财务与习惯及待办摘要、健康摘要或语音片段，会经 Holo 后端发送给第三方 AI 或语音服务处理。想法智能整理开启时，保存后会自动处理必要正文；可在想法设置中单独关闭。")
            }

            Section("关闭后的影响") {
                Text("HoloAI 对话、AI 洞察、自动整理和语音转文字将暂停；你的记账、习惯、待办及其他本地数据不会被删除。")
                    .foregroundColor(.holoTextSecondary)
            }

            Section {
                Button("查看隐私政策") {
                    showPrivacyPolicy = true
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .navigationTitle("HoloAI 数据授权")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            LegalDocumentSheet(documentType: .privacyPolicy)
        }
    }

    private var consentBinding: Binding<Bool> {
        Binding(
            get: { consent.isGranted },
            set: { $0 ? consent.grant() : consent.revoke() }
        )
    }
}
