//
//  SyncDiagnosticsView.swift
//  Holo
//
//  iCloud 同步诊断页：当前状态摘要 + 最近错误流水，
//  用户报障时可据此判断是配额满、未登录还是网络问题。
//

import SwiftUI

struct SyncDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var status = ICloudSyncStatusService.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                summaryCard
                historyCard
                footnote
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .navigationTitle("同步诊断")
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

    // MARK: - 状态摘要

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("当前状态")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            summaryRow(label: String(localized: "账号状态"), value: status.accountStatusText)
            summaryRow(
                label: String(localized: "iCloud 环境"),
                value: CloudKitRuntimeAvailability.currentEnvironment?.displayName
                    ?? String(localized: "未启用（当前构建不含 iCloud 同步）")
            )
            summaryRow(
                label: String(localized: "CloudKit 同步能力"),
                value: CloudKitRuntimeAvailability.isAvailable
                    ? String(localized: "已启用")
                    : String(localized: "未启用（当前构建不含 iCloud 同步）")
            )
            summaryRow(
                label: String(localized: "最近上传成功"),
                value: status.lastExportTime.map(status.formatTime) ?? "—"
            )
            summaryRow(
                label: String(localized: "最近接收成功"),
                value: status.lastImportTime.map(status.formatTime) ?? "—"
            )
            summaryRow(
                label: String(localized: "最近同步失败"),
                value: status.lastErrorTime.map(status.formatTime) ?? "—"
            )
            summaryRow(
                label: String(localized: "当前错误"),
                value: currentErrorText,
                isError: true
            )

            // 上传正常但从未收到过云端数据：多设备场景的关键排查线索。
            // 正式版与开发版连的是同一容器下两个隔离的数据库，两端各自「同步正常」
            // 却互相同步不上时，先对两端的这一行。
            if status.neverReceivedFromCloud {
                Divider()
                Text("本机从未从 iCloud 收到过数据。如果你在其他设备也用 Holo：请确认那台设备能正常上传，且两端连的是同一个 iCloud 环境（本机：\(CloudKitRuntimeAvailability.currentEnvironment?.displayName ?? "未知")）")
                    .font(.system(size: 12))
                    .foregroundColor(.holoInfo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    /// 当前错误带方向前缀（上传失败/下载失败），定位到具体链路
    private var currentErrorText: String {
        guard let message = status.lastErrorMessage else { return String(localized: "无") }
        let directionPrefix: String
        switch status.lastErrorDirection {
        case "export": directionPrefix = String(localized: "上传失败：")
        case "import": directionPrefix = String(localized: "下载失败：")
        default: directionPrefix = ""
        }
        return directionPrefix + message
    }

    private func summaryRow(label: String, value: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)

            Text(value)
                .font(.system(size: 13))
                .foregroundColor(isError && status.lastErrorMessage != nil ? .holoError : .holoTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 错误流水

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text("错误记录")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            if status.errorHistory.isEmpty {
                Text("暂无同步错误记录")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, HoloSpacing.sm)
            } else {
                VStack(spacing: HoloSpacing.sm) {
                    ForEach(status.errorHistory.reversed()) { record in
                        errorRow(record)
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func errorRow(_ record: SyncErrorRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: HoloSpacing.sm) {
                Text(directionLabel(record.direction))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(directionColor(record.direction).opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(status.formatTime(record.date))
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)

                if let code = record.ckErrorCode {
                    Text("CKError \(code)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()
            }

            Text(record.message)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func directionLabel(_ raw: String) -> String {
        switch raw {
        case "export": return String(localized: "上传")
        case "import": return String(localized: "下载")
        case "setup": return String(localized: "准备")
        default: return raw
        }
    }

    private func directionColor(_ raw: String) -> Color {
        switch raw {
        case "export": return .holoError
        case "import": return .holoInfo
        default: return .holoTextSecondary
        }
    }

    private var footnote: some View {
        Text("错误记录仅保存在本机，用于排查同步问题，最多保留最近 20 条。")
            .font(.system(size: 11))
            .foregroundColor(.holoTextSecondary.opacity(0.75))
    }
}
