//
//  GlobalExportView.swift
//  Holo
//
//  设置 → 数据管理 → 导出全部数据（2026-10-25 方案：一期只导出，含敏感记忆）
//
//  状态机：idle 说明卡 → exporting 进度（可取消）→ done 分享 / failed 重试
//  页面关闭即取消导出（onDisappear cancel），不留后台孤儿任务
//

import SwiftUI

struct GlobalExportView: View {

    enum Phase {
        case idle
        case exporting(GlobalExportProgress)
        case done(GlobalExportService.ExportResult)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .idle
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    switch phase {
                    case .idle:
                        introCard
                        startButton
                    case .exporting(let progress):
                        progressCard(progress)
                    case .done(let result):
                        doneCard(result)
                        shareButton(result)
                    case .failed(let message):
                        failedCard(message)
                        startButton
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoToolBackground.ignoresSafeArea())
            .navigationTitle("导出全部数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
            }
        }
        .onDisappear {
            exportTask?.cancel()
        }
    }

    // MARK: - 说明卡（idle）

    private var introCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("把你的全部数据打包带走")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                ForEach(exportScopeItems, id: \.self) { item in
                    HStack(alignment: .top, spacing: HoloSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.holoPrimary)
                            .padding(.top, 2)
                        Text(item)
                            .holoText(.supporting)
                            .foregroundColor(.holoToolText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                ForEach(exportExclusionItems, id: \.self) { item in
                    HStack(alignment: .top, spacing: HoloSpacing.sm) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.holoToolTextSecondary)
                            .padding(.top, 2)
                        Text(item)
                            .holoText(.metadata)
                            .foregroundColor(.holoToolTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("备份文件为明文 ZIP，其中包含敏感记忆（仅本机、不参与 iCloud 同步的部分），请妥善保管。当前版本支持导出，暂不支持从备份恢复。")
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(HoloSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoToolWarning.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var exportScopeItems: [String] {
        [
            String(localized: "全部模块数据：财务、任务、想法、习惯、目标、纪念日、计划、聊天与 AI 记忆"),
            String(localized: "附件图片：小票、任务与想法图片、头像"),
            String(localized: "敏感记忆：仅存在本机的那部分记忆"),
        ]
    }

    private var exportExclusionItems: [String] {
        [
            String(localized: "健康数据（在系统健康 App 中，不在 App 数据库内）"),
            String(localized: "AI 服务的 API 密钥（出于安全考虑）"),
        ]
    }

    // MARK: - 开始按钮

    private var startButton: some View {
        Button {
            startExport()
        } label: {
            Text("开始导出")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 进度（exporting）

    private func progressCard(_ progress: GlobalExportProgress) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)
                Text("正在导出，请保持 App 在前台")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            ProgressView(value: max(min(progress.fraction, 1), 0))
                .tint(.holoPrimary)

            HStack {
                Text(progress.phase == .packaging ? "正在打包备份文件" : "正在导出：\(progress.sourceDisplayName)")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                Text("\(Int((max(min(progress.fraction, 1), 0) * 100)))%")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Button {
                exportTask?.cancel()
            } label: {
                Text("取消导出")
                    .font(.holoBody)
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder.opacity(0.6), lineWidth: 1)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 完成（done）

    private func doneCard(_ result: GlobalExportService.ExportResult) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.holoPrimary)
                Text("导出完成")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
            }

            HStack {
                Text(result.fileURL.lastPathComponent)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(zipFileSizeText(result.fileURL))
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }
            .padding(HoloSpacing.sm)
            .background(Color.holoToolBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

            Text("文件包含敏感记忆，请妥善保管。建议保存到「文件」App 或其他安全位置。")
                .holoText(.metadata)
                .foregroundColor(.holoToolWarning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(HoloSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoToolWarning.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var shareLabel: some View {
        Text("分享备份文件")
            .font(.holoBody)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.holoPrimary)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func shareButton(_ result: GlobalExportService.ExportResult) -> some View {
        ShareLink(item: result.fileURL) {
            shareLabel
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 失败（failed）

    private func failedCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoToolError)
                Text("导出失败")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolError)
            }
            Text(message)
                .holoText(.metadata)
                .foregroundColor(.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoError.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 逻辑

    private func startExport() {
        exportTask = Task {
            withAnimation {
                phase = .exporting(GlobalExportProgress(
                    phase: .exporting,
                    sourceIndex: 0,
                    sourceCount: 1,
                    sourceDisplayName: "主数据",
                    fraction: 0
                ))
            }
            do {
                let sources = try await GlobalExportService.liveSources()
                let service = GlobalExportService(sources: sources)
                let result = try await service.exportAll { progress in
                    Task { @MainActor in
                        applyProgress(progress)
                    }
                }
                await MainActor.run {
                    withAnimation { phase = .done(result) }
                }
            } catch is CancellationError {
                await MainActor.run {
                    withAnimation { phase = .idle }
                }
            } catch {
                await MainActor.run {
                    withAnimation { phase = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// 进度回调来自后台队列，fraction 单调保护防乱序回跳
    @MainActor
    private func applyProgress(_ progress: GlobalExportProgress) {
        guard case .exporting(let current) = phase else { return }
        guard progress.fraction >= current.fraction else { return }
        withAnimation {
            phase = .exporting(progress)
        }
    }

    private func zipFileSizeText(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
