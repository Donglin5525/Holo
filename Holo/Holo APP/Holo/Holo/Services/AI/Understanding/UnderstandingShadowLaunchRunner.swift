//
//  UnderstandingShadowLaunchRunner.swift
//  Holo
//
//  影子引擎试跑：启动参数触发（东林 11-14 禁令——App 内不加调试口子，
// 验收工具走启动参数；本文件 DEBUG-only，正式构建零痕迹）。
//
//  用法（Xcode Scheme 的 Arguments 里加，或命令行启动模拟器）：
//    -understandingShadowRun
//  行为：启动后自动跑一轮（真实数据、understanding_proposal 通道），
//  摘要全屏显示（可复制），评审 JSON 照旧写 Documents。
//

import Foundation
import SwiftUI

#if DEBUG
/// 一次性结果覆盖层（启动参数触发时显示；关闭即消失，不留任何常驻入口）。
@MainActor
struct UnderstandingShadowRunOverlay: View {
    let summary: String
    let onDismiss: () -> Void

    /// 独立 computed view：some View 返回类型锚定，破 iOS26 SDK 的
    /// Text.font/View.font 链式歧义（isDate 歧义同族，显式构造不治本）。
    private var summaryBody: some View {
        // 修饰组合逐字对齐 HealthKitDiagnosticsView 先例（font+foregroundColor+
        // textSelection 在 iOS26 SDK 存活；foregroundStyle/background(in:) 组合会触发歧义）。
        Text(summary)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemBackground)))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                Label("影子理解 · 试跑结果", systemImage: "brain.head.profile")
                    .fontWeight(.semibold)
                ScrollView {
                    summaryBody
                }
                .frame(maxHeight: 360)
                Button("完成", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
    }
}

@MainActor
enum UnderstandingShadowLaunchRunner {
    static let launchArgument = "-understandingShadowRun"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// 跑一轮并返回摘要文本（结果覆盖层与文件共用）。
    static func runAndSummarize() async -> String {
        let report = await UnderstandingRealEntry.runShadowOnce()
        let outcomeLines = report.outcomes.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: "  ")
        var lines = [
            "观察：财务 \(report.financeObservations) + 想法 \(report.thoughtObservations)，主题 \(report.themesTotal) 个",
            "本轮处理 \(report.topicsProcessed) 主题，收到提案 \(report.proposalsReceived) 条",
            "终态：\(outcomeLines.isEmpty ? "无" : outcomeLines)",
        ]
        if !report.rejections.isEmpty {
            lines.append("拒绝理由：\n" + report.rejections.joined(separator: "\n"))
        }
        if !report.modelFailures.isEmpty {
            lines.append("提案失败主题：\(report.modelFailures.joined(separator: "、"))（不重试）")
        }
        // 评审包导出（M2.8）
        let storage = UnderstandingShadowRunner.storageDirectory()
        let ledger = ShadowLedger.load(directory: storage)
        let index = ObservationIndex.load(directory: storage)
        let themes = UnderstandingShadowRunner.loadThemeSnapshot(directory: storage)
        let pkg = ShadowReviewExporter.assemble(ledger: ledger, themes: themes, index: index, now: report.ranAt)
        if let data = try? ShadowReviewExporter.exportJSON(pkg) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let file = docs.appendingPathComponent("UnderstandingShadowReport-\(Int(report.ranAt.timeIntervalSince1970)).json")
            try? data.write(to: file)
            lines.append("评审包：\(file.lastPathComponent)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
