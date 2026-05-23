//
//  HealthKitDiagnosticsView.swift
//  Holo
//
//  HealthKit 诊断报告页面
//

import SwiftUI
import UIKit

struct HealthKitDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reportText: String = ""
    @State private var isGenerating = false
    @State private var copyStatusText: String?

    private let service = HealthKitDiagnosticsService()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                actionBar
                reportCard
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .navigationTitle("健康诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: HoloSpacing.sm) {
            Button {
                Task {
                    await generateReport()
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: isGenerating ? "arrow.triangle.2.circlepath" : "heart.text.square")
                        .font(.system(size: 16, weight: .semibold))
                        .rotationEffect(.degrees(isGenerating ? 360 : 0))
                        .animation(
                            isGenerating ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: isGenerating
                        )

                    Text(isGenerating ? "生成中" : "生成诊断报告")
                        .font(.holoBody)
                        .fontWeight(.semibold)

                    Spacer()
                }
                .foregroundColor(.white)
                .padding(HoloSpacing.md)
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isGenerating)

            Button {
                copyReport()
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))

                    Text(copyStatusText ?? "复制报告")
                        .font(.holoBody)
                        .fontWeight(.semibold)

                    Spacer()
                }
                .foregroundColor(reportText.isEmpty ? .holoTextSecondary : .holoPrimary)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(reportText.isEmpty)
        }
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("报告")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Spacer()
            }

            Text(reportText.isEmpty ? "暂无报告" : reportText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(reportText.isEmpty ? .holoTextSecondary : .holoTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HoloSpacing.md)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    @MainActor
    private func generateReport() async {
        guard !isGenerating else { return }
        isGenerating = true
        copyStatusText = nil
        let report = await service.generateReport()
        reportText = report.copyText()
        isGenerating = false
    }

    private func copyReport() {
        guard !reportText.isEmpty else { return }
        UIPasteboard.general.string = reportText
        copyStatusText = "已复制"

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                copyStatusText = nil
            }
        }
    }
}

#Preview {
    NavigationStack {
        HealthKitDiagnosticsView()
    }
}
